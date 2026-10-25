import AppKit
import Foundation
import Vision
import CoreImage
import CoreText
import ImageIO

// A single optional initialization attempt. Uncached reading closes this
// gate, including when prepare's queued closure has not begun running yet.
final class OCRVisionPreparation: @unchecked Sendable {
    private let lock = NSLock()
    private let queue: DispatchQueue
    private let work: @Sendable (CommandRunner) -> Void
    private var decided = false
    private var runner: CommandRunner?

    init(queue: DispatchQueue = .global(qos: .utility),
         work: @escaping @Sendable (CommandRunner) -> Void = { LocalOCR.prepareVision(runner: $0) }) {
        self.queue = queue; self.work = work
    }

    func schedule() {
        lock.lock()
        guard !decided else { lock.unlock(); return }
        decided = true
        let runner = CommandRunner()
        self.runner = runner
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            defer {
                self.lock.lock()
                if self.runner === runner { self.runner = nil }
                self.lock.unlock()
            }
            guard !runner.isCancelled else { return }
            self.work(runner)
        }
    }

    func cancel() {
        lock.lock()
        decided = true
        let runner = self.runner
        self.runner = nil
        lock.unlock()
        runner?.cancel()
    }
}

// The Vision request can outlive a cancelled job while the framework unwinds.
// Closing the mailbox under its write lock makes deleting the job directory safe
// without making a new page wait for that request to finish.
private final class OCRVisionMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL
    private let runner = CommandRunner()
    private let parent: CommandRunner
    private var cancellation: UUID?
    private var closed = false

    init(directory: URL, parent: CommandRunner) {
        self.directory = directory; self.parent = parent
        cancellation = parent.addCancellationHandler { [runner] in runner.cancel() }
    }

    func start(image: CGImage, imageFile: URL,
               recognize: @escaping @Sendable (CGImage, URL, CommandRunner) -> [[String: Any]]) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            guard !runner.isCancelled else { return }
            let hints = recognize(image, imageFile, runner)
            lock.lock(); defer { lock.unlock() }
            guard !closed, !runner.isCancelled, !parent.isCancelled else { return }
            if let data = try? JSONSerialization.data(withJSONObject: hints) {
                try? data.write(to: directory.appendingPathComponent("hints.json"), options: .atomic)
            }
        }
    }

    func close() {
        lock.lock(); closed = true; lock.unlock()
        if let cancellation { parent.removeCancellationHandler(cancellation); self.cancellation = nil }
        runner.cancel()
    }
}

struct OCRBlock: Codable {
    let id: String
    let text: String
    let bounds: DialogueBounds
    var replacementPNG: Data? = nil
    var replacementAllowed: Bool? = nil
    var textStyle: String? = nil
    var layoutBounds: DialogueBounds? = nil
    var layoutRegions: [DialogueBounds]? = nil
    var vertical: Bool? = nil
    var fontSize: Double? = nil
    var uncertainFragments: [String]? = nil
    var translationKind: String? {
        let words = text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return textStyle != nil && words.count <= 4 && words.contains { (0x3040...0x30FF).contains($0.value) } ? "sound_effect" : nil
    }
    var readingHint: String? {
        guard translationKind == "sound_effect" else { return nil }
        let key = String(String.UnicodeScalarView(text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
        let hints = ["じ": "凝视、盯着看", "じー": "凝视、盯着看", "じっ": "凝视、盯着看", "じーっ": "凝视、盯着看",
                     "ドキ": "心跳", "ドキドキ": "心跳加速", "ざわ": "人群骚动", "ザワ": "人群骚动"]
        return hints[key]
    }
}
struct OCRPage: Codable {
    let blocks: [OCRBlock]
    let skippedCount: Int
    let elapsed: Double
}

// The serial worker keeps its local models warm between pages. Cancellation and
// progress use per-job files, so no stale result can be consumed by a newer job.
final class LocalOCR: @unchecked Sendable {
    private let serial = NSLock()
    private let visionPreparation: OCRVisionPreparation
    private let visionHints: @Sendable (CGImage, URL, CommandRunner) -> [[String: Any]]
    private let root: URL
    private let script: URL
    private let cache: URL
    private var process: Process?
    private var input: FileHandle?
    private var runtime: URL?
    private var log: FileHandle?
    static let engineVersion = "manga-ocr-20"

    init(support: URL, resources: URL, engineRoot: URL? = nil,
         visionPreparation: OCRVisionPreparation? = nil,
         visionHints: (@Sendable (CGImage, CommandRunner) -> [[String: Any]])? = nil,
         visionFileHints: (@Sendable (CGImage, URL, CommandRunner) -> [[String: Any]])? = nil) throws {
        let helper = Self.visionHelperURL(resources: resources)
        self.visionPreparation = visionPreparation ?? OCRVisionPreparation {
            LocalOCR.prepareVision(runner: $0, helperURL: helper)
        }
        if let visionFileHints {
            self.visionHints = visionFileHints
        } else if let visionHints {
            self.visionHints = { image, _, runner in visionHints(image, runner) }
        } else {
            self.visionHints = { image, file, runner in
                LocalOCR.textHints(in: image, runner: runner, helperURL: helper, imageFile: file)
            }
        }
        root = engineRoot ?? support.appendingPathComponent("OCR")
        cache = support.appendingPathComponent("Recognition")
        script = resources.appendingPathComponent("ocr_worker.py")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        trimCache()
    }
    deinit { shutdown() }

    func shutdown() {
        visionPreparation.cancel()
        serial.lock(); defer { serial.unlock() }
        stopProcess(); cleanup()
    }

    private func start() throws {
        if process?.isRunning == true { return }
        let python = root.appendingPathComponent("venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("models/manga/pytorch_model.bin").path),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("models/comictextdetector.pt").path) else {
            throw AppError.configuration("本地识字组件未安装，请在「应用设置…」中安装。")
        }
        cleanup()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shiori-ocr-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        runtime = directory
        let logURL = directory.appendingPathComponent("worker.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        log = try FileHandle(forWritingTo: logURL)
        let child = Process(), pipe = Pipe()
        child.executableURL = python
        child.arguments = ["-u", script.path, root.path, directory.path]
        child.environment = CommandRunner.environment()
        child.standardInput = pipe; child.standardOutput = FileHandle.nullDevice; child.standardError = log
        // A missing/broken worker must become a recoverable job error, never a
        // SIGPIPE that terminates the menu-bar app on the next write.
        guard fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw AppError.message("无法连接本地识字组件，请重试。")
        }
        try child.run(); process = child; input = pipe.fileHandleForWriting
    }

    private func stopProcess() {
        guard let child = process, child.isRunning else { return }
        child.terminate()
        let deadline = Date().addingTimeInterval(1)
        while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        child.waitUntilExit()
    }

    private func cleanup() {
        try? input?.close(); input = nil
        try? log?.close(); log = nil
        if let runtime { try? FileManager.default.removeItem(at: runtime) }
        runtime = nil; process = nil
    }

    func prepare() throws {
        serial.lock()
        do { try start(); serial.unlock() }
        catch { serial.unlock(); throw error }
        visionPreparation.schedule()
    }

    // Atomic cache files can be inspected by the UI without joining the active
    // recognition job or starting either OCR engine.
    func cachedRecognition(for page: CapturedPage) -> OCRPage? {
        let url = cache.appendingPathComponent(page.digest + "-" + Self.engineVersion + ".json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(OCRPage.self, from: data)
    }

    // A selected region is already localized. Running page detection on this
    // small crop can drop an entire text column; decode the complete crop once.
    func recognizeBubble(page: CapturedPage, runner: CommandRunner) throws -> String {
        serial.lock(); defer { serial.unlock() }
        try runner.checkCancellation()
        visionPreparation.cancel()
        try start()
        let job = runtime!.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: job) }
        try page.encoded(.png).write(to: job.appendingPathComponent("page.png"))
        var request = try JSONSerialization.data(withJSONObject: ["directory": job.path, "kind": "bubble"])
        request.append(10)
        do { try input!.write(contentsOf: request) }
        catch {
            stopProcess(); cleanup()
            try runner.checkCancellation()
            throw AppError.message("本地识字连接已断开，请重试。")
        }
        let cancelJob = runner.addCancellationHandler {
            try? Data().write(to: job.appendingPathComponent("cancel"), options: .atomic)
        }
        defer { runner.removeCancellationHandler(cancelJob) }
        struct State: Decodable { let phase: String; var text: String?; var message: String? }
        let deadline = Date().addingTimeInterval(45)
        var cancelStart: Date?
        while Date() < deadline {
            if runner.isCancelled, cancelStart == nil { cancelStart = Date() }
            if let start = cancelStart, Date().timeIntervalSince(start) > 3 {
                stopProcess(); cleanup(); throw CancellationError()
            }
            guard process?.isRunning == true else {
                cleanup(); try runner.checkCancellation()
                throw AppError.message("本地识字未能启动，请重新打开助手。")
            }
            if let data = try? Data(contentsOf: job.appendingPathComponent("state.json")),
               let state = try? JSONDecoder().decode(State.self, from: data) {
                switch state.phase {
                case "cancelled": throw CancellationError()
                case "error":
                    try runner.checkCancellation()
                    throw AppError.message(state.message ?? "没能读出文字，可以直接修改原文。")
                case "done":
                    try runner.checkCancellation()
                    guard let text = state.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                        throw AppError.message("没能读出文字，可以直接修改原文。")
                    }
                    return text
                default: break
                }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        stopProcess(); cleanup()
        throw AppError.message("这个气泡识字超时，请重试。")
    }

    // Called on the recognition queue. Text-ready emits cumulative snapshots as
    // reliable balloons finish and Vision supplements/rechecks the page. IDs are
    // stable; text can change after verification. Only completed closed-balloon
    // patches can render before the final page.
    func recognize(page: CapturedPage, runner: CommandRunner, force: Bool = false, progress: (String) -> Void,
                   onTextReady: ((OCRPage) -> Void)? = nil) throws -> OCRPage {
        serial.lock(); defer { serial.unlock() }
        try runner.checkCancellation()
        let key = page.digest + "-" + Self.engineVersion + ".json"
        let cached = cache.appendingPathComponent(key)
        if !force, let data = try? Data(contentsOf: cached), let result = try? JSONDecoder().decode(OCRPage.self, from: data) {
            CacheFiles.touch(cached)
            try runner.checkCancellation()
            onTextReady?(result)
            try runner.checkCancellation()
            return result
        }
        visionPreparation.cancel()
        try start()
        let job = runtime!.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: job) }
        try page.encoded(.png).write(to: job.appendingPathComponent("page.png"))
        progress("检查文字…")
        var request = try JSONSerialization.data(withJSONObject: ["directory": job.path, "hintsPending": true]); request.append(10)
        do { try input!.write(contentsOf: request) }
        catch {
            stopProcess(); cleanup()
            try runner.checkCancellation()
            throw AppError.message("本地识字连接已断开，请重试。")
        }
        // The worker can stop while Vision is still unwinding its request. Keep
        // the normal acknowledgement/cleanup loop below before deleting the job.
        let cancelJob = runner.addCancellationHandler {
            try? Data().write(to: job.appendingPathComponent("cancel"), options: .atomic)
        }
        defer { runner.removeCancellationHandler(cancelJob) }
        // Poll while Vision runs: reliable detector balloons do not wait for the
        // framework's cold initialization. The final pass still uses its evidence.
        let vision = OCRVisionMailbox(directory: job, parent: runner)
        defer { vision.close() }
        vision.start(image: page.image, imageFile: job.appendingPathComponent("page.png"), recognize: visionHints)
        let deadline = Date().addingTimeInterval(90)
        var cancelStart: Date?
        var lastProgress = ""
        var deliveredText: Data?
        struct State: Decodable {
            let phase: String
            var completed: Int?; var total: Int?; var page: OCRPage?; var message: String?
        }
        while Date() < deadline {
            if runner.isCancelled, cancelStart == nil {
                cancelStart = Date(); try Data().write(to: job.appendingPathComponent("cancel"))
            }
            if let start = cancelStart, Date().timeIntervalSince(start) > 3 {
                stopProcess(); cleanup(); throw CancellationError()
            }
            guard process?.isRunning == true else {
                cleanup(); try runner.checkCancellation(); throw AppError.message("本地识字未能启动，请重新打开助手。")
            }
            let state = (try? Data(contentsOf: job.appendingPathComponent("state.json")))
                .flatMap { try? JSONDecoder().decode(State.self, from: $0) }
            if !runner.isCancelled,
               let data = try? Data(contentsOf: job.appendingPathComponent("text.json")),
               data != deliveredText,
               let text = try? JSONDecoder().decode(OCRPage.self, from: data) {
                deliveredText = data
                onTextReady?(text)
            }
            if let state {
                switch state.phase {
                case "cancelled": throw CancellationError()
                case "error":
                    try runner.checkCancellation()
                    throw AppError.message(state.message ?? "本地识字失败。")
                case "done":
                    try runner.checkCancellation()
                    guard let result = state.page else { throw AppError.message("识字结果不完整。") }
                    if deliveredText == nil { onTextReady?(result) }
                    try runner.checkCancellation()
                    try JSONEncoder().encode(result).write(to: cached, options: .atomic)
                    trimCache()
                    if runner.isCancelled {
                        try? FileManager.default.removeItem(at: cached)
                        throw CancellationError()
                    }
                    return result
                default: break
                }
            }
            let message = state?.phase == "detecting" ? "查找气泡…" : state?.phase == "recognizing"
                ? "识字 \(state?.completed ?? 0)/\(state?.total ?? 0)"
                : state?.phase == "repairing" ? "整理画面…"
                : state?.phase == "verifying" ? "补充识字…"
                : "加载识字模型…"
            if message != lastProgress { progress(message); lastProgress = message }
            Thread.sleep(forTimeInterval: 0.1)
        }
        stopProcess(); cleanup()
        throw AppError.message("本地识字超时，请重试。")
    }

    private func trimCache() {
        CacheFiles.trim(cache, maxBytes: 128 * 1024 * 1024)
    }

    static func visionHelperURL(resources: URL) -> URL {
        resources.deletingLastPathComponent().appendingPathComponent("Helpers/ShioriVision")
    }

    private static var bundledVisionHelper: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ShioriVision")
    }

    // Kept available to standalone tests. Packaged builds prepare the same stable
    // helper executable used by actual pages; no screenshots are needed here.
    static func visionPreparationImage() -> CGImage? { VisionRecognition.visionPreparationImage() }

    static func prepareVision(runner: CommandRunner, helperURL: URL? = nil) {
        let helper = helperURL ?? bundledVisionHelper
        if FileManager.default.fileExists(atPath: helper.path) {
            guard FileManager.default.isExecutableFile(atPath: helper.path), !runner.isCancelled else { return }
            _ = try? runner.run(executable: helper, arguments: ["--prepare"],
                                directory: helper.deletingLastPathComponent(), timeout: 45)
            return
        }
        VisionRecognition.prepare(isCancelled: { runner.isCancelled }, perform: { request, work in
            performVision(request, runner: runner, perform: work)
        })
    }

    // Each request gets its own registration, including refinement requests.
    // The callback cannot cancel a later page after this request is finished.
    static func performVision(_ request: VNRequest, runner: CommandRunner?, perform: () throws -> Void) -> Bool {
        let registration = runner?.addCancellationHandler { request.cancel() }
        defer { if let registration { runner?.removeCancellationHandler(registration) } }
        guard runner?.isCancelled != true else { return false }
        do { try perform() } catch { return false }
        return runner?.isCancelled != true
    }

    static func textHints(in image: CGImage, runner: CommandRunner? = nil,
                          helperURL: URL? = nil, imageFile: URL? = nil,
                          helperTimeout: TimeInterval = 25) -> [[String: Any]] {
        let helper = helperURL ?? bundledVisionHelper
        guard runner?.isCancelled != true else { return [] }
        // A missing helper is expected in standalone source tests. A present but
        // failed helper never falls back into another expensive in-process run.
        guard FileManager.default.fileExists(atPath: helper.path) else {
            return VisionRecognition.textHints(in: image, isCancelled: { runner?.isCancelled == true },
                perform: { request, work in performVision(request, runner: runner, perform: work) })
        }
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { return [] }
        // Recognition already owns a PNG in its unique job directory. Borrow it
        // for this request; only the job's owner may remove this file.
        if let imageFile {
            return helperTextHints(imageFile: imageFile, helper: helper, runner: runner, timeout: helperTimeout)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shiori-vision-" + UUID().uuidString)
        do {
            try runner?.checkCancellation()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("page.png")
            guard let destination = CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil) else { return [] }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return [] }
            return helperTextHints(imageFile: file, helper: helper, runner: runner, timeout: helperTimeout)
        } catch {
            return []
        }
    }

    private static func helperTextHints(imageFile: URL, helper: URL, runner: CommandRunner?,
                                        timeout: TimeInterval) -> [[String: Any]] {
        // A helper timeout must not cancel the page's mailbox: it still needs
        // to deliver [] so detector/Manga OCR results can finish normally.
        let childRunner = CommandRunner()
        let cancellation = runner?.addCancellationHandler { childRunner.cancel() }
        defer { if let cancellation { runner?.removeCancellationHandler(cancellation) } }
        do {
            try childRunner.checkCancellation()
            let result = try childRunner.run(executable: helper, arguments: ["--image", imageFile.path],
                                             directory: helper.deletingLastPathComponent(), timeout: timeout)
            try childRunner.checkCancellation()
            guard result.status == 0,
                  let hints = try JSONSerialization.jsonObject(with: result.stdout) as? [[String: Any]] else { return [] }
            return hints
        } catch {
            return []
        }
    }

}
