import AppKit
import Foundation

// Opt-in real-page check. Images stay in the supplied local directory; only
// recognized dialogue is sent to the chosen translation service.
@main
struct ReaderIntegration {
    @MainActor static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 3 else { throw AppError.message("Usage: reader-integration resources output-directory page.png ...") }
        let resources = URL(fileURLWithPath: args[0]), output = URL(fileURLWithPath: args[1])
        let support = try AppStorage.directory()
        let work = output.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let ocr = try LocalOCR(support: work, resources: resources, engineRoot: support.appendingPathComponent("OCR"))
        let google = try GoogleTranslationClient(cacheDirectory: work.appendingPathComponent("Google"), concurrency: 6)
        let codex = try CodexClient(resources: resources, workspace: work.appendingPathComponent("Codex"))
        defer { ocr.shutdown(); google.shutdown(); codex.shutdown(); try? FileManager.default.removeItem(at: work) }
        let launch = Date(); try ocr.prepare(); let processLaunch = Date().timeIntervalSince(launch)
        var rows: [[String: Any]] = []
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let paths = Array(args.dropFirst(2))
        for (index, path) in (paths + [paths[0]]).enumerated() {
            let url = URL(fileURLWithPath: path), name = index < paths.count ? url.deletingPathExtension().lastPathComponent : "return"
            let image = NSImage(contentsOf: url)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
            let page = try CapturedPage(image: image)
            let runner = CommandRunner(), began = Date()
            var textReady = 0.0
            let selected = TranslationOptions(model: GoogleTranslationClient.model, effort: "none", provider: .google)
            let result = try TranslationPipeline.run(runner: runner, began: began, recognize: { ready in
                try ocr.recognize(page: page, runner: runner, progress: { _ in }, onTextReady: { textReady = Date().timeIntervalSince(began); ready($0) })
            }, translate: { text, preview in
                try google.translate(ocr: text, options: selected, runner: runner, preview: preview).0
            }, preview: { _, _ in })
            let total = Date().timeIntervalSince(began)
            let rendered = try OverlayPreview.render(result.0, image: image, destination: output.appendingPathComponent(name + "-google.png"), scale: 1)
            try encoder.encode(result.0).write(to: output.appendingPathComponent(name + "-google.json"))
            let row: [String: Any] = ["page": name, "service": "Google", "ocr": result.1.ocr, "textReady": textReady,
                "translation": result.1.codex, "total": total, "firstResult": result.1.firstResult ?? -1,
                "translated": result.0.translatedCount, "untranslated": result.0.untranslatedCount,
                "ocrSkipped": result.0.ocrSkippedCount ?? 0, "rendered": rendered, "notes": result.0.notes]
            rows.append(row); print(String(data: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), encoding: .utf8)!)
        }
        try codex.prepare()
        let image = NSImage(contentsOfFile: paths[0])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let recognized = try ocr.recognize(page: CapturedPage(image: image), runner: CommandRunner(), progress: { _ in })
        let began = Date(); var first: Double?
        let result = try codex.translate(ocr: recognized, options: TranslationOptions(model: "gpt-6-luna", effort: "low"), runner: CommandRunner(), preview: { _ in if first == nil { first = Date().timeIntervalSince(began) } })
        let rendered = try OverlayPreview.render(result.0, image: image, destination: output.appendingPathComponent("page-c-codex.png"), scale: 1)
        try encoder.encode(result.0).write(to: output.appendingPathComponent("page-c-codex.json"))
        rows.append(["page": "page-c", "service": "Codex", "translation": result.1, "firstResult": first ?? -1,
                     "translated": result.0.translatedCount, "untranslated": result.0.untranslatedCount, "rendered": rendered])
        let report: [String: Any] = ["processLaunchSeconds": processLaunch, "pages": rows, "limits": "Real browser screenshots passed through production OCR, translation and compositor. The first page includes model initialization; prepare only launches the worker. This is not native overlay foreground validation."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("report.json"))
        print("Real-page check complete")
    }
}
