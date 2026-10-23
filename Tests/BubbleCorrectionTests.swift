import AppKit
import Foundation

@main
struct BubbleCorrectionTests {
    static func main() throws {
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw AppError.message("FAIL: " + message) }
            print("PASS: " + message)
        }
        let bounds = DialogueBounds(x: 100, y: 200, width: 300, height: 400)
        let geometry = OCRBlock(id: "c1", text: "おはよう", bounds: bounds,
                                replacementPNG: Data([1, 2, 3]), replacementAllowed: true,
                                layoutBounds: bounds, vertical: true, fontSize: 22)
        let original = Dialogue.recognized(geometry, text: "早上好")
        let changed = try BubbleCorrection.edited(original, source: "  こんばんは  ", translation: " 晚上好 ")
        try check(changed.original == "こんばんは" && changed.translation == "晚上好", "manual source and translation edits are paired")
        try check(changed.replacementPNG == original.replacementPNG && changed.bounds?.x == bounds.x
                  && changed.vertical == true && changed.fontSize == 22, "correction preserves the verified page geometry and erasure patch")
        let restored = BubbleCorrection.restored(changed)
        try check(restored.preserveOriginal == true && !restored.needsReview, "intentional original view is not an OCR uncertainty")
        let revised = try BubbleCorrection.edited(restored, source: restored.original, translation: "晚上好呀")
        try check(revised.preserveOriginal != true && revised.userRestoredOriginal != true, "retranslation restores a manually hidden bubble")
        let second = Dialogue(location: "c2", original: "ありがとう", translation: "谢谢", bounds: bounds)
        let page = PageTranslation(summary: "", dialogues: [second], notes: "", skippedCount: 3, ocrSkippedCount: 2)
        let inserted = BubbleCorrection.replacing(changed, in: page, order: ["c1", "c2"])
        try check(inserted.dialogues.map(\.location) == ["c1", "c2"] && inserted.skippedCount == 2,
                  "correcting a previously missing translation retains reading order and removes only its pending count")
        let replaced = BubbleCorrection.replacing(restored, in: inserted, order: ["c1", "c2"])
        try check(replaced.dialogues.count == 2 && replaced.dialogues[1].translation == "谢谢" && replaced.skippedCount == 2,
                  "editing an existing bubble neither changes neighbours nor subtracts OCR skips")
        let encoded = try JSONEncoder().encode(replaced)
        let decoded = try JSONDecoder().decode(PageTranslation.self, from: encoded)
        try check(decoded.dialogues[0].userRestoredOriginal == true && decoded.pendingCount == 2,
                  "manual restore survives cache round-trip without becoming pending review")
        for value in [("", "你好"), ("おはよう", "   ")] {
            do {
                _ = try BubbleCorrection.edited(original, source: value.0, translation: value.1)
                throw AppError.message("accepted blank edit")
            } catch let error as AppError { try check(error.localizedDescription != "accepted blank edit", "empty edit cannot erase an existing translation") }
        }
        let context = CGContext(data: nil, width: 1000, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let captured = try CapturedPage(image: context.makeImage()!)
        let crop = try BubbleCorrection.crop(original, from: captured)
        try check(crop.image.width == 300 && crop.image.height == 320, "re-OCR input contains only selected original pixels")
    }
}
