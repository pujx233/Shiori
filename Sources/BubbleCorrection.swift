import Foundation
import CoreGraphics

// OCR snapshots cross the recognition and translation queues. The text-only
// context is read once per batch; no capture or UI work runs under this lock.
final class RecognitionSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var value: OCRPage?
    private var complete = false
    func update(_ page: OCRPage, final: Bool = false) { lock.lock(); value = page; complete = final; lock.unlock() }
    func read() -> OCRPage? { lock.lock(); defer { lock.unlock() }; return value }
    func snapshot() -> (page: OCRPage?, final: Bool) { lock.lock(); defer { lock.unlock() }; return (value, complete) }
}

enum BubbleCorrection {
    static func block(from dialogue: Dialogue, source: String? = nil) throws -> OCRBlock {
        guard let bounds = dialogue.bounds else { throw AppError.message("这个气泡的位置不完整。") }
        let text = (source ?? dialogue.original).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AppError.message("请填写原文。") }
        return OCRBlock(id: dialogue.location, text: text, bounds: bounds,
                        replacementPNG: dialogue.replacementPNG, replacementAllowed: dialogue.replacementAllowed,
                        textStyle: dialogue.textStyle, layoutBounds: dialogue.layoutBounds,
                        layoutRegions: dialogue.layoutRegions, vertical: dialogue.vertical, fontSize: dialogue.fontSize)
    }

    static func crop(_ dialogue: Dialogue, from page: CapturedPage) throws -> CapturedPage {
        let size = CGSize(width: page.image.width, height: page.image.height)
        guard let rect = dialogue.bounds?.rect(in: size)?.integral,
              rect.width >= 4, rect.height >= 4,
              let image = page.image.cropping(to: rect) else { throw AppError.message("无法读取这个气泡。") }
        return try CapturedPage(image: image)
    }

    static func edited(_ dialogue: Dialogue, source: String, translation: String) throws -> Dialogue {
        let value = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw AppError.message("请填写译文，或选择恢复原图。") }
        var edited = Dialogue.recognized(try block(from: dialogue, source: source), text: value)
        edited.userEdited = true
        return edited
    }

    static func restored(_ dialogue: Dialogue) -> Dialogue {
        var value = dialogue
        value.preserveOriginal = true
        value.userRestoredOriginal = true
        value.userEdited = true
        return value
    }

    static func replacing(_ dialogue: Dialogue, in page: PageTranslation, order: [String]) -> PageTranslation {
        let existed = page.dialogues.contains { $0.location == dialogue.location }
        var items = page.dialogues.filter { $0.location != dialogue.location } + [dialogue]
        let indexes = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
        items.sort { (indexes[$0.location] ?? Int.max) < (indexes[$1.location] ?? Int.max) }
        return PageTranslation(summary: page.summary, dialogues: items, notes: page.notes,
                               skippedCount: max(page.ocrSkippedCount ?? 0, page.skippedCount - (existed ? 0 : 1)),
                               ocrSkippedCount: page.ocrSkippedCount)
    }
}
