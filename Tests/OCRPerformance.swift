import AppKit
import CryptoKit
import Foundation

// Real-page performance harness; it never captures a screen. Compile this same
// file against each revision being compared, and supply the same PNG inputs.
// Default: no network, no prewarming, a fresh isolated cache and two A/B/C rounds
// in one worker. Only the first input is worker-cold; this does not claim an OS-
// cold Vision cache. --google explicitly enables text-only translation requests.
@main
struct OCRPerformance {
    struct Options {
        var resources: URL?
        var engineRoot: URL?
        var visionHelper: URL?
        var output: URL?
        var scratchParent = FileManager.default.temporaryDirectory
        var label = "unspecified"
        var rounds = 2
        var google = false
        var keepScratch = false
        var paths: [URL] = []

        init(_ arguments: [String]) throws {
            var index = 0
            func next(_ name: String) throws -> String {
                index += 1
                guard index < arguments.count else { throw AppError.message("Missing value for " + name) }
                return arguments[index]
            }
            while index < arguments.count {
                let item = arguments[index]
                switch item {
                case "--resources": resources = URL(fileURLWithPath: try next(item))
                case "--engine-root": engineRoot = URL(fileURLWithPath: try next(item))
                case "--vision-helper": visionHelper = URL(fileURLWithPath: try next(item))
                case "--output": output = URL(fileURLWithPath: try next(item))
                case "--scratch-parent": scratchParent = URL(fileURLWithPath: try next(item))
                case "--label": label = try next(item)
                case "--rounds":
                    guard let value = Int(try next(item)), (1...10).contains(value) else {
                        throw AppError.message("--rounds must be between 1 and 10")
                    }
                    rounds = value
                case "--google": google = true
                case "--keep-scratch": keepScratch = true
                case "--help", "-h": throw AppError.message(Self.usage)
                default:
                    guard !item.hasPrefix("--") else { throw AppError.message("Unknown option: " + item) }
                    paths.append(URL(fileURLWithPath: item))
                }
                index += 1
            }
            guard resources != nil, engineRoot != nil, output != nil, !paths.isEmpty else { throw AppError.message(Self.usage) }
        }

        static let usage = """
        Usage: ocr-performance --resources PATH --engine-root PATH --output REPORT.json \
          [--vision-helper PATH] [--label REVISION] [--rounds 2] [--google] [--scratch-parent PATH] [--keep-scratch] page-a.png page-b.png page-c.png
        """
    }

    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
            print(Options.usage); return
        }
        let options = try Options(Array(CommandLine.arguments.dropFirst()))
        let files = FileManager.default
        #if SHIORI_VISION_HELPER
        guard let helper = options.visionHelper, files.isExecutableFile(atPath: helper.path) else {
            throw AppError.message("This helper benchmark requires --vision-helper with the packaged ShioriVision executable.")
        }
        #else
        guard options.visionHelper == nil else {
            throw AppError.message("Compile current sources with -D SHIORI_VISION_HELPER to benchmark the packaged helper.")
        }
        #endif
        let visionMode = options.visionHelper == nil ? "in-process" : "packaged-helper"
        let helperHash = try options.visionHelper.map { url in
            SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        }
        let helperCDHash = options.visionHelper.flatMap(PerformanceHelperIdentity.codeDirectoryHash)
        let scratch = options.scratchParent.appendingPathComponent("shiori-performance-" + UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer {
            if options.keepScratch { print("Scratch retained: " + scratch.path) }
            else { try? files.removeItem(at: scratch) }
        }
        let output = options.output!
        try files.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let observations = PerformanceObservations()
        #if SHIORI_VISION_HELPER
        let ocr = try LocalOCR(support: scratch, resources: options.resources!, engineRoot: options.engineRoot!,
            visionPreparation: OCRVisionPreparation(work: { _ in }), visionFileHints: { image, file, runner in
                let ticket = observations.beginVision()
                let hints = LocalOCR.textHints(in: image, runner: runner, helperURL: options.visionHelper, imageFile: file)
                observations.endVision(ticket, hintCount: hints.count, cancelled: runner.isCancelled)
                return hints
            })
        #else
        let ocr = try LocalOCR(support: scratch, resources: options.resources!, engineRoot: options.engineRoot!,
            visionPreparation: OCRVisionPreparation(work: { _ in }), visionHints: { image, runner in
                let ticket = observations.beginVision()
                let hints = LocalOCR.textHints(in: image, runner: runner)
                observations.endVision(ticket, hintCount: hints.count, cancelled: runner.isCancelled)
                return hints
            })
        #endif
        let google = options.google ? try GoogleTranslationClient(cacheDirectory: scratch.appendingPathComponent("Google"), concurrency: 6) : nil
        defer { ocr.shutdown(); google?.shutdown() }
        var rows: [[String: Any]] = []
        let startedAt = ISO8601DateFormatter().string(from: Date())
        func report() throws {
            let value: [String: Any] = [
                "schema": 1, "label": options.label, "ocrEngine": LocalOCR.engineVersion,
                "startedAt": startedAt, "rounds": options.rounds, "inputCount": options.paths.count,
                "clock": "DispatchTime.uptimeNanoseconds", "prewarm": false, "forceOCR": true,
                "visionMode": visionMode, "visionHelperSHA256": helperHash as Any? ?? NSNull(),
                "visionHelperCDHash": helperCDHash as Any? ?? NSNull(),
                "visionInput": options.visionHelper == nil ? "in-memory" : "existing-worker-PNG",
                "google": options.google, "forceGoogle": options.google,
                "cacheIsolation": "new private scratch directory; removed unless --keep-scratch",
                "privacy": "Report contains only input hashes, dimensions, counts and timings. Images, OCR and translations stay in scratch.",
                "limits": "First page includes worker startup. Later pages reuse that worker. OS framework/model caches are not reset. Vision duration includes helper launch and local image handoff when helper mode is selected, and follows production fallback behavior. First render means the production offscreen compositor on MainActor, not a native overlay painted on screen. Preview render/write overhead is separately reported. Untranslated OCR omissions and failed layouts are different counts.",
                "pages": rows
            ]
            try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
        }
        for round in 0..<options.rounds {
            for (inputIndex, path) in options.paths.enumerated() {
                let inputData = try Data(contentsOf: path)
                guard let image = NSImage(data: inputData)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    throw AppError.message("Cannot decode input image " + String(inputIndex + 1))
                }
                let page = try CapturedPage(image: image)
                let sample = round * options.paths.count + inputIndex
                let sampleName = String(format: "round-%02d-page-%02d", round + 1, inputIndex + 1)
                let sampleDirectory = scratch.appendingPathComponent(sampleName, isDirectory: true)
                try files.createDirectory(at: sampleDirectory, withIntermediateDirectories: true)
                let began = PerformanceClock.now()
                observations.beginPage(sample, began: began)
                let renderProbe = PreviewRenderProbe(image: image, directory: sampleDirectory, began: began)
                let runner = CommandRunner()
                let recognized = RecognitionSnapshotForPerformance()
                var row: [String: Any] = [
                    "round": round + 1, "input": inputIndex + 1, "workerState": sample == 0 ? "cold" : "warm",
                    "inputSHA256": SHA256.hash(data: inputData).map { String(format: "%02x", $0) }.joined(),
                    "width": image.width, "height": image.height
                ]
                do {
                    let translation = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PageTranslation?, Error>) in
                        DispatchQueue.global(qos: .userInitiated).async {
                            do {
                                if let google {
                                    let selected = TranslationOptions(model: GoogleTranslationClient.model, effort: "none", provider: .google)
                                    let result = try TranslationPipeline.run(runner: runner, recognize: { ready in
                                        let result = try ocr.recognize(page: page, runner: runner, force: true, progress: { _ in }, onTextReady: {
                                            observations.draft(sample, page: $0)
                                            ready($0)
                                        })
                                        recognized.set(result); observations.finishOCR(sample, page: result)
                                        return result
                                    }, translate: { text, preview in
                                        observations.translationBatch(sample, count: text.blocks.count)
                                        return try google.translate(ocr: text, options: selected, runner: runner, force: true, preview: preview).0
                                    }, preview: { partial, _ in
                                        let callbackAt = PerformanceClock.now()
                                        DispatchQueue.main.sync {
                                            MainActor.assumeIsolated { renderProbe.accept(partial, callbackAt: callbackAt) }
                                        }
                                    })
                                    continuation.resume(returning: result.0)
                                } else {
                                    let result = try ocr.recognize(page: page, runner: runner, force: true, progress: { _ in }, onTextReady: {
                                        observations.draft(sample, page: $0)
                                    })
                                    recognized.set(result); observations.finishOCR(sample, page: result)
                                    continuation.resume(returning: nil)
                                }
                            } catch { continuation.resume(throwing: error) }
                        }
                    }
                    row["status"] = "ok"
                    row["pipelineSeconds"] = PerformanceClock.seconds(since: began)
                    row.merge(observations.snapshot(sample), uniquingKeysWith: { _, new in new })
                    if let final = recognized.read() {
                        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                        try encoder.encode(final).write(to: sampleDirectory.appendingPathComponent("ocr.json"), options: .atomic)
                        let content = try encoder.encode(OCRPage(blocks: final.blocks, skippedCount: final.skippedCount, elapsed: 0))
                        row["ocrContentSHA256"] = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
                    }
                    if let translation {
                        let renderBegan = PerformanceClock.now()
                        let rendered = try OverlayPreview.render(translation, image: image,
                            destination: sampleDirectory.appendingPathComponent("final.png"), scale: 1)
                        row["finalRenderSeconds"] = PerformanceClock.seconds(since: renderBegan)
                        row["translated"] = translation.translatedCount
                        row["untranslated"] = translation.untranslatedCount
                        row["preservedOriginal"] = translation.preservedCount
                        row["rendered"] = rendered
                        row["renderOmissions"] = max(0, translation.translatedCount - rendered)
                        row.merge(renderProbe.metrics, uniquingKeysWith: { _, new in new })
                        try JSONEncoder().encode(translation).write(to: sampleDirectory.appendingPathComponent("translation.json"), options: .atomic)
                    }
                    rows.append(row)
                    try report()
                    print(String(data: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), encoding: .utf8)!)
                } catch {
                    runner.cancel()
                    row["status"] = "failed"
                    row["errorType"] = String(reflecting: type(of: error))
                    row["pipelineSeconds"] = PerformanceClock.seconds(since: began)
                    row.merge(observations.snapshot(sample), uniquingKeysWith: { _, new in new })
                    rows.append(row); try report()
                    throw error
                }
            }
        }
        print("Metrics written: " + output.path)
    }
}

private enum PerformanceClock {
    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    static func seconds(since began: UInt64, at end: UInt64 = now()) -> Double {
        Double(end >= began ? end - began : 0) / 1_000_000_000
    }
}

private enum PerformanceHelperIdentity {
    // The CMS signature can carry a new signing time even when executable code
    // is unchanged. CDHash, rather than whole-file SHA256, identifies that code.
    static func codeDirectoryHash(_ helper: URL) -> String? {
        let child = Process(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        child.arguments = ["-dv", "--verbose=4", helper.path]
        child.standardOutput = FileHandle.nullDevice; child.standardError = output
        do { try child.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        guard child.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).split(separator: "\n")
            .first { $0.hasPrefix("CDHash=") }.map { String($0.dropFirst("CDHash=".count)) }
    }
}

private final class RecognitionSnapshotForPerformance: @unchecked Sendable {
    private let lock = NSLock()
    private var page: OCRPage?
    func set(_ value: OCRPage) { lock.lock(); page = value; lock.unlock() }
    func read() -> OCRPage? { lock.lock(); defer { lock.unlock() }; return page }
}

private final class PerformanceObservations: @unchecked Sendable {
    struct VisionTicket { let page: Int; let index: Int; let start: UInt64 }
    private struct Sample {
        let began: UInt64
        var drafts: [[String: Any]] = []
        var vision: [[String: Any]] = []
        var firstCallback: Double?
        var firstOCR: Double?
        var firstSafeCallback: Double?
        var firstSafe: Double?
        var finalOCR: Double?
        var finalBlocks = 0
        var finalSkipped = 0
        var finalSafe = 0
        var replacementReady = 0
        var workerElapsed = 0.0
        var translationBatches: [Int] = []
    }
    private let lock = NSLock()
    private var current = -1
    private var samples: [Int: Sample] = [:]

    func beginPage(_ id: Int, began: UInt64) {
        lock.lock(); defer { lock.unlock() }
        current = id; samples[id] = Sample(began: began)
    }
    func beginVision() -> VisionTicket {
        let now = PerformanceClock.now()
        lock.lock(); defer { lock.unlock() }
        let index = samples[current]?.vision.count ?? 0
        if var value = samples[current] {
            value.vision.append(["startSeconds": PerformanceClock.seconds(since: value.began, at: now), "completed": false])
            samples[current] = value
        }
        return VisionTicket(page: current, index: index, start: now)
    }
    func endVision(_ ticket: VisionTicket, hintCount: Int, cancelled: Bool) {
        let now = PerformanceClock.now()
        lock.lock(); defer { lock.unlock() }
        guard var value = samples[ticket.page] else { return }
        guard value.vision.indices.contains(ticket.index) else { return }
        value.vision[ticket.index] = ["startSeconds": PerformanceClock.seconds(since: value.began, at: ticket.start),
                                     "durationSeconds": PerformanceClock.seconds(since: ticket.start, at: now),
                                     "endSeconds": PerformanceClock.seconds(since: value.began, at: now),
                                     "hints": hintCount, "cancelled": cancelled, "completed": true]
        samples[ticket.page] = value
    }
    func draft(_ id: Int, page: OCRPage) {
        let now = PerformanceClock.now()
        let safe = page.blocks.filter(TranslationPipeline.earlyPatchIsReady).count
        lock.lock(); defer { lock.unlock() }
        guard var value = samples[id] else { return }
        let time = PerformanceClock.seconds(since: value.began, at: now)
        if value.firstCallback == nil { value.firstCallback = time }
        if value.firstOCR == nil, !page.blocks.isEmpty { value.firstOCR = time }
        if value.firstSafeCallback == nil, safe > 0 { value.firstSafeCallback = time }
        if value.firstSafe == nil, safe > 0 { value.firstSafe = time }
        value.drafts.append(["seconds": time, "blocks": page.blocks.count, "safeClosedPatches": safe, "ocrSkipped": page.skippedCount])
        samples[id] = value
    }
    func finishOCR(_ id: Int, page: OCRPage) {
        let now = PerformanceClock.now()
        let safe = page.blocks.filter(TranslationPipeline.earlyPatchIsReady).count
        lock.lock(); defer { lock.unlock() }
        guard var value = samples[id] else { return }
        let time = PerformanceClock.seconds(since: value.began, at: now)
        value.finalOCR = time
        if value.firstOCR == nil, !page.blocks.isEmpty { value.firstOCR = time }
        if value.firstSafe == nil, safe > 0 { value.firstSafe = time }
        value.finalBlocks = page.blocks.count; value.finalSkipped = page.skippedCount; value.finalSafe = safe
        value.replacementReady = page.blocks.filter { $0.replacementAllowed == true }.count
        value.workerElapsed = page.elapsed
        samples[id] = value
    }
    func translationBatch(_ id: Int, count: Int) {
        lock.lock(); defer { lock.unlock() }
        samples[id]?.translationBatches.append(count)
    }
    func snapshot(_ id: Int) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        guard let value = samples[id] else { return [:] }
        return ["firstOCRCallbackSeconds": value.firstCallback as Any? ?? NSNull(),
                "firstTextSeconds": value.firstOCR as Any? ?? NSNull(),
                "firstSafePatchCallbackSeconds": value.firstSafeCallback as Any? ?? NSNull(),
                "firstSafePatchSeconds": value.firstSafe as Any? ?? NSNull(),
                "finalOCRSeconds": value.finalOCR as Any? ?? NSNull(),
                "workerReportedElapsedSeconds": value.workerElapsed,
                "ocrBlocks": value.finalBlocks, "ocrSkipped": value.finalSkipped,
                "safeClosedPatches": value.finalSafe, "replacementReady": value.replacementReady,
                "drafts": value.drafts, "vision": value.vision,
                "translationBatchSizes": value.translationBatches]
    }
}

@MainActor
private final class PreviewRenderProbe {
    private let image: CGImage
    private let directory: URL
    private let began: UInt64
    private var firstCallback: Double?
    private var firstRendered: Double?
    private var firstRenderedCount = 0
    private var attempts = 0
    private var overhead = 0.0
    private var renderFailures = 0
    init(image: CGImage, directory: URL, began: UInt64) {
        self.image = image; self.directory = directory; self.began = began
    }
    func accept(_ value: PageTranslation, callbackAt: UInt64) {
        guard firstRendered == nil, value.dialogues.contains(where: { $0.preserveOriginal != true && $0.replacementAllowed != false }) else { return }
        let start = PerformanceClock.now(); attempts += 1
        defer { overhead += PerformanceClock.seconds(since: start) }
        do {
            let count = try OverlayPreview.render(value, image: image, destination: directory.appendingPathComponent("first-preview.png"), scale: 1)
            if count > 0 {
                firstCallback = PerformanceClock.seconds(since: began, at: callbackAt)
                firstRendered = PerformanceClock.seconds(since: began)
                firstRenderedCount = count
            }
        } catch { renderFailures += 1 }
    }
    var metrics: [String: Any] {
        ["firstRenderablePreviewSeconds": firstCallback as Any? ?? NSNull(),
         "firstOffscreenRenderSeconds": firstRendered as Any? ?? NSNull(),
         "firstRenderedCount": firstRenderedCount, "previewRenderAttempts": attempts,
         "previewRenderFailures": renderFailures, "previewRenderOverheadSeconds": overhead]
    }
}
