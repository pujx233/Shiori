import AppKit

@main
struct OverlayInteractionTests {
    @MainActor
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw AppError.message("FAIL: " + message) }
            checks += 1; print("PASS: " + message)
        }
        func image(width: Int, height: Int) -> CGImage {
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()!
        }
        func flagsEvent(_ flags: NSEvent.ModifierFlags, keyCode: UInt16 = 58) -> NSEvent {
            NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0,
                             windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                             isARepeat: false, keyCode: keyCode)!
        }
        func pixels(_ canvas: TranslationCanvas) -> [UInt8] {
            let width = Int(canvas.bounds.width) * 2, height = Int(canvas.bounds.height) * 2
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 2, y: -2)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            canvas.draw(canvas.bounds)
            NSGraphicsContext.restoreGraphicsState()
            return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
        }
        func alpha(_ pixels: [UInt8]) -> [UInt8] {
            stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
        }
        let canvas = TranslationCanvas(frame: NSRect(x: 0, y: 0, width: 200, height: 180))
        let patch = NSBitmapImageRep(cgImage: image(width: 120, height: 90)).representation(using: .png, properties: [:])!
        let dialogue = Dialogue(location: "one", original: "今日は練習です。", translation: "今天练习。",
                                bounds: DialogueBounds(x: 200, y: 250, width: 600, height: 500),
                                replacementPNG: patch, replacementAllowed: true)
        canvas.setTranslation(PageTranslation(summary: "", dialogues: [dialogue], notes: ""), image: image(width: 200, height: 180))
        let translated = pixels(canvas)
        try check(canvas.items.count == 1 && alpha(translated).filter { $0 == 255 }.count > 30_000,
                  "fixture paints the actual erasure patch and translated text")
        canvas.flagsChanged(with: flagsEvent(.option))
        try check(canvas.showOriginal, "Option key-down reveals the original immediately")
        try check(alpha(pixels(canvas)).allSatisfy { $0 == 0 }, "holding Option removes both the erasure patch and translated glyphs")
        try check(canvas.items.count == 1, "original reveal retains the cached translation")
        canvas.flagsChanged(with: flagsEvent([.option, .shift]))
        try check(canvas.showOriginal && alpha(pixels(canvas)).allSatisfy { $0 == 0 }, "adding Shift while holding Option keeps the original visible")
        canvas.flagsChanged(with: flagsEvent(.shift))
        try check(!canvas.showOriginal, "releasing Option restores translation even while Shift remains held")
        try check(pixels(canvas) == translated, "release restores exactly the previous patch and translated pixels")
        canvas.updateModifierFlags([.command, .control, .capsLock])
        try check(!canvas.showOriginal && pixels(canvas) == translated, "unrelated modifier flags never hide translation")

        // This is the same method used by MangaOverlay's timer when its panel is click-through.
        canvas.updateModifierFlags(.option)
        try check(canvas.showOriginal && alpha(pixels(canvas)).allSatisfy { $0 == 0 }, "the normal click-through polling path also reveals the original")
        canvas.updateModifierFlags([])
        try check(!canvas.showOriginal && pixels(canvas) == translated, "polling a released key restores the overlay without a key-up event")
        canvas.flagsChanged(with: flagsEvent(.option, keyCode: 61))
        try check(canvas.showOriginal, "right Option behaves identically to left Option")
        canvas.flagsChanged(with: flagsEvent([], keyCode: 61))
        try check(!canvas.showOriginal && pixels(canvas) == translated, "releasing right Option restores translated pixels")

        canvas.selecting = true; canvas.selectedID = dialogue.location
        let selected = pixels(canvas)
        canvas.flagsChanged(with: flagsEvent(.option))
        let selectedOriginal = alpha(pixels(canvas))
        try check(canvas.showOriginal && canvas.acceptsFirstResponder && canvas.bubbles.count == 1,
                  "reveal does not exit correction mode or discard selectable bubbles")
        try check(selectedOriginal.contains { $0 > 0 } && selectedOriginal.allSatisfy { $0 < 255 },
                  "correction outlines remain visible while opaque translation pixels disappear")
        canvas.flagsChanged(with: flagsEvent([]))
        try check(pixels(canvas) == selected, "release restores the translation and the same selected outline")
        print("\(checks) overlay interaction checks passed")
    }
}
