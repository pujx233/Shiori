import AppKit
import Foundation
import Vision
import CoreImage

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
    private let root: URL
    private let script: URL
    private let cache: URL
    private var process: Process?
    private var input: FileHandle?
    private var runtime: URL?
    private var log: FileHandle?
    private let engineVersion = "manga-ocr-14"

    init(support: URL, resources: URL, engineRoot: URL? = nil) throws {
        root = engineRoot ?? support.appendingPathComponent("OCR")
        cache = support.appendingPathComponent("Recognition")
        script = resources.appendingPathComponent("ocr_worker.py")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        trimCache()
    }
    deinit { shutdown() }

    func shutdown() {
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
        serial.lock(); defer { serial.unlock() }
        try start()
    }

    func recognize(page: CapturedPage, runner: CommandRunner, force: Bool = false, progress: (String) -> Void) throws -> OCRPage {
        serial.lock(); defer { serial.unlock() }
        try runner.checkCancellation()
        let key = page.digest + "-" + engineVersion + ".json"
        let cached = cache.appendingPathComponent(key)
        if !force, let data = try? Data(contentsOf: cached), let result = try? JSONDecoder().decode(OCRPage.self, from: data) {
            CacheFiles.touch(cached)
            return result
        }
        try start()
        let job = runtime!.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: job) }
        try page.encoded(.png).write(to: job.appendingPathComponent("page.png"))
        progress("检查文字…")
        var request = try JSONSerialization.data(withJSONObject: ["directory": job.path, "hintsPending": true]); request.append(10)
        try input!.write(contentsOf: request)
        // Vision supplies independent Japanese evidence for unframed text and
        // small text missed by the comic detector. Images remain on this Mac.
        let hints = Self.textHints(in: page.image)
        try JSONSerialization.data(withJSONObject: hints).write(to: job.appendingPathComponent("hints.json"), options: .atomic)
        let deadline = Date().addingTimeInterval(90)
        var cancelStart: Date?
        var lastProgress = ""
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
            if let state {
                switch state.phase {
                case "cancelled": throw CancellationError()
                case "error": throw AppError.message(state.message ?? "本地识字失败。")
                case "done":
                    try runner.checkCancellation()
                    guard let result = state.page else { throw AppError.message("识字结果不完整。") }
                    try JSONEncoder().encode(result).write(to: cached, options: .atomic)
                    trimCache()
                    return result
                default: break
                }
            }
            let message = state?.phase == "detecting" ? "查找气泡…" : state?.phase == "recognizing"
                ? "识字 \(state?.completed ?? 0)/\(state?.total ?? 0)"
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

    static func textHints(in image: CGImage) -> [[String: Any]] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ja-JP", "en-US"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.004
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return [] }
        var refinements = 0
        return (request.results ?? []).compactMap { observation in
            guard var candidate = observation.topCandidates(1).first, candidate.confidence >= 0.3,
                  candidate.string.unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value) }) else { return nil }
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
                if (try? VNImageRequestHandler(ciImage: straight).perform([line])) != nil,
                   let improved = line.results?.first?.topCandidates(1).first,
                   improved.confidence > candidate.confidence, improved.string.count >= candidate.string.count / 2 {
                    candidate = improved
                }
            }
            return ["text": candidate.string, "confidence": candidate.confidence,
                    "box": [rect.minX * Double(image.width), (1-rect.maxY) * Double(image.height),
                            rect.maxX * Double(image.width), (1-rect.minY) * Double(image.height)]]
        }
    }

}
