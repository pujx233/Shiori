import AppKit
import Foundation

// Real-page OCR/erasure replay. Inputs and generated pixels stay in the caller's
// local output directory; no image or recognized text is sent to a service.
@main
struct ErasureReplay {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 3 else { throw AppError.message("Usage: erasure-replay resources output page.png ...") }
        let output = URL(fileURLWithPath: args[1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let runtime = output.appendingPathComponent("runtime")
        let engine = try AppStorage.directory().appendingPathComponent("OCR")
        let ocr = try LocalOCR(support: runtime, resources: URL(fileURLWithPath: args[0]), engineRoot: engine)
        defer { ocr.shutdown(); try? FileManager.default.removeItem(at: runtime) }
        let paths = Array(args.dropFirst(2))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var rows: [[String: Any]] = []
        for (index, path) in (paths + [paths[0]]).enumerated() {
            let file = URL(fileURLWithPath: path)
            let name = index < paths.count ? file.deletingPathExtension().lastPathComponent : "return"
            guard let image = NSImage(contentsOf: file)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw AppError.message("Cannot read input: " + file.lastPathComponent)
            }
            let began = Date(); var firstText: Double?
            let recognized = try ocr.recognize(page: CapturedPage(image: image), runner: CommandRunner(),
                progress: { _ in }, onTextReady: { _ in if firstText == nil { firstText = Date().timeIntervalSince(began) } })
            let total = Date().timeIntervalSince(began)
            try encoder.encode(recognized).write(to: output.appendingPathComponent(name + ".json"))
            let row: [String: Any] = ["page": name, "seconds": total, "firstText": firstText ?? total,
                "workerSeconds": recognized.elapsed, "blocks": recognized.blocks.count,
                "patches": recognized.blocks.filter { $0.replacementPNG != nil && $0.replacementAllowed != false }.count,
                "width": image.width, "height": image.height]
            rows.append(row)
            print(String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
            fflush(stdout)
        }
        try JSONSerialization.data(withJSONObject: ["pages": rows,
            "scope": "Sequential real browser screenshots through production OCR and erasure; final return uses cache."],
            options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("report.json"))
    }
}
