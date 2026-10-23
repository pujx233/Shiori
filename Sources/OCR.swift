import AppKit
import Foundation
import Vision
import CoreImage
import CoreText

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
    private let root: URL
    private let script: URL
    private let cache: URL
    private var process: Process?
    private var input: FileHandle?
    private var runtime: URL?
    private var log: FileHandle?
    static let engineVersion = "manga-ocr-17"

    init(support: URL, resources: URL, engineRoot: URL? = nil,
         visionPreparation: OCRVisionPreparation = OCRVisionPreparation()) throws {
        self.visionPreparation = visionPreparation
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
            throw AppError.configuration("本地识字组件未安装，请运行 SETUP_OCR.command。")
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

    // Called on the recognition queue. Text-ready may include completed closed
    // balloon patches; all other blocks remain replacementAllowed=false until
    // the returned final page. The pipeline validates patches before previewing.
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
        // Vision supplies independent Japanese evidence for unframed text and
        // small text missed by the comic detector. Images remain on this Mac.
        let hints = Self.textHints(in: page.image, runner: runner)
        try JSONSerialization.data(withJSONObject: hints).write(to: job.appendingPathComponent("hints.json"), options: .atomic)
        let deadline = Date().addingTimeInterval(90)
        var cancelStart: Date?
        var lastProgress = ""
        var deliveredText = false
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
            if !deliveredText, !runner.isCancelled,
               let data = try? Data(contentsOf: job.appendingPathComponent("text.json")),
               let text = try? JSONDecoder().decode(OCRPage.self, from: data) {
                deliveredText = true
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
                    if !deliveredText { onTextReady?(result) }
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

    // Internal fixture only: no screen capture, files, or AppKit drawing. It
    // attempts initialization early; page recognition never joins this work.
    static func visionPreparationImage() -> CGImage? {
        guard let context = CGContext(data: nil, width: 320, height: 96, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 96))
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("HiraginoSans-W3" as CFString, 30, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "今日は晴れです。", attributes: attributes))
        context.textPosition = CGPoint(x: 10, y: 34)
        CTLineDraw(line, context)
        return context.makeImage()
    }

    static func prepareVision(runner: CommandRunner) {
        guard !runner.isCancelled, let image = visionPreparationImage(), !runner.isCancelled else { return }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ja-JP", "en-US"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.004
        _ = performVision(request, runner: runner) {
            try VNImageRequestHandler(cgImage: image).perform([request])
        }
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

    static func textHints(in image: CGImage, runner: CommandRunner? = nil) -> [[String: Any]] {
        guard runner?.isCancelled != true else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ja-JP", "en-US"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.004
        guard performVision(request, runner: runner, perform: {
            try VNImageRequestHandler(cgImage: image).perform([request])
        }) else { return [] }
        var refinements = 0
        var hints: [[String: Any]] = []
        for observation in request.results ?? [] {
            guard runner?.isCancelled != true else { return [] }
            guard var candidate = observation.topCandidates(1).first, candidate.confidence >= 0.3,
                  candidate.string.unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value) }) else { continue }
            let rect = observation.boundingBox
            // Small slanted signs benefit from a level, enlarged line crop. Keep
            // ordinary dialogue on the single full-page pass.
            if candidate.confidence < 0.7, rect.width * CGFloat(image.width) > rect.height * CGFloat(image.height) * 1.6,
               rect.height < 0.10, candidate.string.count >= 3, refinements < 6 {
                refinements += 1
                func point(_ p: CGPoint) -> CIVector { CIVector(x: p.x * CGFloat(image.width), y: p.y * CGFloat(image.height)) }
                let straight = CIImage(cgImage: image).applyingFilter("CIPerspectiveCorrection", parameters: [
                    "inputTopLeft": point(observation.topLeft), "inputTopRight": point(observation.topRight),
                    "inputBottomLeft": point(observation.bottomLeft), "inputBottomRight": point(observation.bottomRight)
                ]).transformed(by: CGAffineTransform(scaleX: 2, y: 2))
                let line = VNRecognizeTextRequest()
                line.recognitionLevel = .accurate; line.recognitionLanguages = ["ja-JP"]; line.usesLanguageCorrection = true
                if performVision(line, runner: runner, perform: {
                    try VNImageRequestHandler(ciImage: straight).perform([line])
                }),
                   let improved = line.results?.first?.topCandidates(1).first,
                   improved.confidence > candidate.confidence, improved.string.count >= candidate.string.count / 2 {
                    candidate = improved
                }
            }
            guard runner?.isCancelled != true else { return [] }
            hints.append(["text": candidate.string, "confidence": candidate.confidence,
                    "box": [rect.minX * Double(image.width), (1-rect.maxY) * Double(image.height),
                            rect.maxX * Double(image.width), (1-rect.minY) * Double(image.height)]])
        }
        return runner?.isCancelled == true ? [] : hints
    }

}
