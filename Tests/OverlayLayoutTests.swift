import AppKit
import CoreText

// Replay the dimensions of two real 1920 × 817 reading-window annotations with
// unrelated sample text. These checks use the actual Core Text frames and pixels.
@main
struct OverlayLayoutTests {
    @MainActor
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) throws {
            guard value() else { throw AppError.message("FAIL: " + label) }
            checks += 1; print("PASS: " + label)
        }
        func runs(_ text: FittedText) -> [CTRun] {
            (CTFrameGetLines(text.frame) as! [CTLine]).flatMap { CTLineGetGlyphRuns($0) as! [CTRun] }
        }
        func fontSizes(_ text: FittedText) -> [CGFloat] {
            runs(text).map { CTFontGetSize((CTRunGetAttributes($0) as NSDictionary)[kCTFontAttributeName] as! CTFont) }
        }
        func assertInk(_ text: FittedText, rect: CGRect, label: String) throws {
            let lines = CTFrameGetLines(text.frame) as! [CTLine]
            var origins = [CGPoint](repeating: .zero, count: lines.count)
            CTFrameGetLineOrigins(text.frame, CFRange(location: 0, length: 0), &origins)
            var previous = CGRect.null
            for (line, origin) in zip(lines, origins) {
                let stroke = (CTLineGetGlyphRuns(line) as! [CTRun]).map { run -> CGFloat in
                    let attributes = CTRunGetAttributes(run) as NSDictionary
                    let percentage = abs((attributes[kCTStrokeWidthAttributeName] as? NSNumber)?.doubleValue ?? 0)
                    return CTFontGetSize(attributes[kCTFontAttributeName] as! CTFont) * percentage / 200
                }.max() ?? 0
                let path = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
                let ink = path.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -stroke, dy: -stroke)
                let actual = CGRect(x: text.origin.x + ink.minX,
                                    y: text.origin.y + text.height - ink.maxY, width: ink.width, height: ink.height)
                try check(rect.insetBy(dx: -0.0001, dy: -0.0001).contains(actual), label + " includes all glyph paths and outline")
                if !previous.isNull { try check(actual.minY - previous.maxY >= 0.2499, label + " keeps line ink separated") }
                previous = actual
            }
            // Draw at 2×, as on the actual Retina reading window, rather than only checking a fit flag.
            let scale = 2, width = 256, height = 160
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            text.draw()
            NSGraphicsContext.restoreGraphicsState()
            let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
            var painted = 0, outside = 0
            let allowed = rect.insetBy(dx: -0.5, dy: -0.5)
            for y in 0..<height { for x in 0..<width where pixels[(y*width+x)*4+3] > 0 {
                painted += 1
                let point = CGPoint(x: (CGFloat(x)+0.5)/CGFloat(scale), y: (CGFloat(y)+0.5)/CGFloat(scale))
                if !allowed.contains(point) { outside += 1 }
            } }
            try check(painted > 80, label + " actually paints text")
            try check(outside == 0, label + " draws no pixels beyond the safe region")
        }
        let cases: [(String, CGRect, CGFloat)] = [
            ("（三年级学生、图书室）", CGRect(x: 20, y: 20, width: 84.4, height: 17.206148282097672), 16.2748643761302*0.817),
            ("今天下午 68 分钟以后", CGRect(x: 20, y: 20, width: 71.10769230769233, height: 17.944846292947545), 17.179023508137433*0.817)
        ]
        for (index, sample) in cases.enumerated() {
            let (value, rect, maximum) = sample
            guard let text = FittedText.make(value, rect: rect, style: "outlinedDark", maxFontSize: maximum) else {
                throw AppError.message("FAIL: short annotation \(index) is still omitted")
            }
            try check(text.clipRect != nil, "annotation \(index) exercises compact fallback")
            try check(CTFrameGetVisibleStringRange(text.frame).length == value.utf16.count, "annotation \(index) retains the final character and punctuation")
            try check(fontSizes(text).allSatisfy { $0 >= 8 }, "annotation \(index) preserves outlined text font floor")
            try assertInk(text, rect: rect, label: "annotation \(index)")
        }
        let minimum = FittedText.make("明天再见", rect: CGRect(x: 20, y: 20, width: 28.1, height: 11), maxFontSize: 12.3)
        try check(minimum != nil && fontSizes(minimum!).allSatisfy { $0 == 7 }, "fractional font hint still tries the exact 7 pt floor")
        try check(FittedText.make(String(repeating: "太长的译文", count: 20), rect: CGRect(x: 0, y: 0, width: 12, height: 12)) == nil,
                  "unreadable cramped text is still omitted")
        try check(FittedText.make("普通文字", rect: CGRect(x: 0, y: 0, width: 7.9, height: 50)) == nil,
                  "subminimum geometry is still rejected")
        let gapValue = "  （三年…学生、图书室）  "
        let gap = TextGap(location: (gapValue as NSString).range(of: "…").location, length: 1)
        if let text = FittedText.make(gapValue, rect: cases[0].1, style: "outlinedDark", maxFontSize: cases[0].2, gaps: [gap]) {
            let gapRuns = runs(text).filter { run in
                let range = CTRunGetStringRange(run)
                return range.location <= 3 && range.location + range.length > 3
            }
            let gapSize = gapRuns.first.map { CTFontGetSize((CTRunGetAttributes($0) as NSDictionary)[kCTFontAttributeName] as! CTFont) }
            try check(gapRuns.count == 1 && gapSize == max(6, fontSizes(text).max()!*0.72),
                      "trimming retains uncertainty gap styling at its UTF-16 position")
            try check(CTFrameGetVisibleStringRange(text.frame).length == gapValue.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count,
                      "uncertainty styling does not truncate the translation")
            try assertInk(text, rect: cases[0].1, label: "uncertain annotation")
        } else { throw AppError.message("FAIL: uncertain annotation does not fit") }
        let standard = FittedText.make("明天一起去图书馆。", rect: CGRect(x: 20, y: 20, width: 120, height: 100), maxFontSize: 18)!
        try check(standard.clipRect == nil && fontSizes(standard).allSatisfy { $0 == 18 }, "successful normal layouts preserve original size and spacing")
        let spaced = "嗯。 ．． ．．"
        let normalized = FittedText.displayText(spaced, gaps: [])
        try check(normalized.text == "嗯。．．．．", "CJK dot cleanup preserves every punctuation character")
        let tiny = CGRect(x: 20, y: 20, width: 15, height: 21)
        let short = FittedText.flow(spaced, regions: [tiny], style: nil, vertical: true, maxFontSize: 11)!
        try check(short.count == 1 && CTFrameGetVisibleStringRange(short[0].frame).length == normalized.text.utf16.count,
                  "cached tiny annotation is fully displayed without widening its region")
        try check(fontSizes(short[0]).allSatisfy { $0 >= 7 }, "dot cleanup keeps the existing readable font floor")
        try assertInk(short[0], rect: tiny, label: "tiny dot annotation")
        let untouched = "Version 1.2.3 A. B  words， ．．。 \n．．\r\n…\ttext"
        try check(FittedText.displayText(untouched, gaps: []).text == untouched,
                  "English, decimals, ordinary word spacing and newlines remain unchanged")
        try check(FittedText.displayText("。\t\u{3000}．．\u{00A0}…", gaps: []).text == "。．．…",
                  "only horizontal Unicode whitespace inside the specified dots is removed")
        let emojiValue = "🙂嗯。 \t．． ．．□好"
        let emojiExpected = "🙂嗯。．．．．□好"
        let square = TextGap(location: (emojiValue as NSString).range(of: "□").location, length: 1)
        let spanningRange = (emojiValue as NSString).range(of: "．． ．．")
        let spanning = TextGap(location: spanningRange.location, length: spanningRange.length)
        let removedRange = (emojiValue as NSString).range(of: " \t")
        let removed = TextGap(location: removedRange.location, length: removedRange.length)
        let emojiDisplay = FittedText.displayText(emojiValue, gaps: [square, spanning, removed])
        let expectedSquare = TextGap(location: (emojiExpected as NSString).range(of: "□").location, length: 1)
        let expectedDots = (emojiExpected as NSString).range(of: "．．．．")
        try check(emojiDisplay.text == emojiExpected && emojiDisplay.gaps == [expectedSquare,
            TextGap(location: expectedDots.location, length: expectedDots.length)],
            "UTF-16 gaps after emoji shift, spanning gaps shrink, and deleted-only gaps disappear")
        let emojiText = FittedText.flow(emojiValue, regions: [CGRect(x: 20, y: 20, width: 220, height: 80)],
            style: nil, vertical: false, maxFontSize: 18, gaps: [square])![0]
        let squareRun = runs(emojiText).first { run in
            let range = CTRunGetStringRange(run)
            return range.location <= expectedSquare.location && range.location+range.length > expectedSquare.location
        }!
        let squareSize = CTFontGetSize((CTRunGetAttributes(squareRun) as NSDictionary)[kCTFontAttributeName] as! CTFont)
        try check(squareSize == 18*0.72 && CTFrameGetVisibleStringRange(emojiText.frame).length == emojiExpected.utf16.count,
                  "actual frame styles the remapped uncertainty symbol after an emoji")
        let secondPass = FittedText.displayText(emojiDisplay.text, gaps: emojiDisplay.gaps)
        try check(secondPass.text == emojiDisplay.text && secondPass.gaps == emojiDisplay.gaps,
                  "display normalization is idempotent")
        // Search an impossible connected balloon without rescanning every font at every cut.
        // A generous CI limit catches the former multi-second regression; timings remain visible.
        for character in ["译", "a"] { for count in [80, 160, 320] {
            let began = Date()
            let result = FittedText.flow(String(repeating: character, count: count),
                regions: [CGRect(x: 0, y: 0, width: 12, height: 12), CGRect(x: 14, y: 0, width: 12, height: 12)],
                style: nil, vertical: false, maxFontSize: 18)
            let elapsed = Date().timeIntervalSince(began)
            try check(result == nil && elapsed < 0.5, "impossible two-region \(character == "a" ? "Latin" : "CJK") text (\(count)) stays bounded")
            print("two-region \(count): \(String(format: "%.4f", elapsed)) s")
        } }
        print("\(checks) overlay layout checks passed")
    }
}
