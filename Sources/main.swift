import AppKit
import CoreText
import Foundation

func makeFixture(_ destination: URL, vertical: Bool = false, shaded: Bool = false) throws {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1600, pixelsHigh: 1000,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let graphics = NSGraphicsContext(bitmapImageRep: rep) else { throw AppError.message("fixture image failed") }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
    NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1600, height: 1000).fill()
    NSColor.black.setStroke()
    for rect in [NSRect(x: 70, y: 130, width: 680, height: 720), NSRect(x: 850, y: 130, width: 680, height: 720)] {
        let path = NSBezierPath(roundedRect: rect, xRadius: 60, yRadius: 60)
        if shaded {
            NSColor(deviceRed: 228/255, green: 228/255, blue: 228/255, alpha: 1).setFill(); path.fill()
        }
        path.lineWidth = 4; path.stroke()
    }
    let style: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 43), .foregroundColor: NSColor.black]
    if vertical {
        for (column, text) in ["おはよう！", "今日はいい天気だね。", "一緒に散歩しよう。"].enumerated() {
            for (index, character) in text.enumerated() {
                (String(character) as NSString).draw(at: NSPoint(x: 1320-column*85, y: 735-index*49), withAttributes: style)
            }
        }
    } else {
        ("おはよう！\n今日はいい天気だね。\n一緒に散歩しませんか？" as NSString).draw(in: NSRect(x: 900, y: 360, width: 570, height: 350), withAttributes: style)
    }
    ("いいですね。\n午後三時に駅で会いましょう。\n傘を忘れないでね。" as NSString).draw(in: NSRect(x: 120, y: 360, width: 570, height: 350), withAttributes: style)
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: destination)
}

func selfTest() throws {
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw AppError.message("FAIL: " + message) }
        print("PASS: " + message)
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shiori-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = root.appendingPathComponent("test.png"); try makeFixture(fixture)
    let image = NSImage(contentsOf: fixture)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    let page = try CapturedPage(image: image, displaySize: CGSize(width: 800, height: 500))
    let viewport = CGRect(x: 0, y: 60, width: 800, height: 440)
    let content = try BrowserContent.crop(image, displaySize: page.displaySize, viewport: viewport)
    let toolbar = NSBitmapImageRep(cgImage: image)
    for y in 0..<110 {
        for x in 0..<image.width { toolbar.setColor(NSColor(deviceRed: 0.2, green: 0.2, blue: 0.2, alpha: 1), atX: x, y: y) }
    }
    let refocused = try BrowserContent.crop(toolbar.cgImage!, displaySize: page.displaySize, viewport: viewport)
    try check(content.digest == refocused.digest && content.hasSameContent(as: refocused),
              "browser toolbar color and title changes never change the captured content")
    var contentTracker = PageTracker(); contentTracker.adopt(content); contentTracker.markSubmitted(content.digest)
    _ = contentTracker.observe(refocused); _ = contentTracker.observe(refocused)
    try check(!contentTracker.needsSubmission && !contentTracker.isSettling,
              "toolbar focus changes do not hide translations or repeat OCR")
    try check(content.image.height == 880 && content.contentRect == viewport && content.displaySize == page.displaySize,
              "viewport crop preserves window coordinates for the translation overlay")
    let fractional = CGRect(x: 0, y: 60.25, width: 800, height: 439.75)
    let cleanEdge = try BrowserContent.crop(image, displaySize: page.displaySize, viewport: fractional)
    let edgePixels = NSBitmapImageRep(cgImage: image)
    for x in 0..<image.width { edgePixels.setColor(NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 1), atX: x, y: 120) }
    let changedEdge = try BrowserContent.crop(edgePixels.cgImage!, displaySize: page.displaySize, viewport: fractional)
    try check(cleanEdge.digest == changedEdge.digest, "fractional viewport borders never retain changing toolbar pixels")
    try check(BrowserContent.isToolbarEditor(role: "AXTextField", frame: CGRect(x: 50, y: 20, width: 500, height: 25), viewport: viewport),
              "address editing pauses detection while suggestions can cover the page")
    try check(!BrowserContent.isToolbarEditor(role: "AXTextField", frame: CGRect(x: 50, y: 100, width: 100, height: 25), viewport: viewport)
              && !BrowserContent.isToolbarEditor(role: "AXButton", frame: CGRect(x: 50, y: 20, width: 30, height: 25), viewport: viewport),
              "webpage fields and browser navigation buttons do not pause page detection")
    let cache = try TranslationCache(directory: root.appendingPathComponent("cache"))
    let safeMask = BubbleCover.make(image: image, rect: CGRect(x: 880, y: 220, width: 620, height: 520))
    try check(safeMask != nil, "light speech bubbles can be replaced")
    if let mask = safeMask, let data = mask.dataProvider?.data {
        let bytes = CFDataGetBytePtr(data)!
        let opaque = stride(from: 3, to: CFDataGetLength(data), by: 4).filter { bytes[$0] > 0 }.count
        try check(opaque < mask.width * mask.height / 2, "replacement erases ink instead of covering the whole rectangle")
    }
    let first = TranslationOptions(model: "model-a", effort: "low")
    let second = TranslationOptions(model: "model-b", effort: "low")
    let deep = TranslationOptions(model: "model-a", effort: "high")
    try check(first == TranslationOptions(model: "model-a", effort: "low", context: "new browser title"),
              "browser title changes do not invalidate a page or hide its translation")
    try check(!TranslationReply.usable(source: "感謝の寄せ書きを渡したくて", translated: "……")
              && !TranslationReply.usable(source: "じ．．．", translated: "じ……")
              && TranslationReply.usable(source: "内田夕李", translated: "内田夕李"),
              "missing dialogue and unchanged kana are retried while unchanged kanji names remain valid")
    try MainActor.assumeIsolated {
        let fitted = FittedText.flow("喂喂，你决定好要参加什么社团了吗？",
            regions: [CGRect(x: 0, y: 0, width: 18, height: 28.5), CGRect(x: 0, y: 40, width: 28.5, height: 42)],
            style: nil, vertical: true, maxFontSize: 12.5)
        try check(fitted?.count == 2, "real small connected balloons retain the whole translation across both lobes")
        try check(FittedText.make("那个……", rect: CGRect(x: 0, y: 0, width: 15, height: 27.5),
                                 vertical: true, maxFontSize: 10.35) != nil,
                  "a real narrow bubble can use horizontal fallback without dropping its translation")
    }
    let bubble = DialogueBounds(x: 750, y: 100, width: 200, height: 400)
    try check(bubble.rect(in: CGSize(width: 1600, height: 1000)) == CGRect(x: 1200, y: 100, width: 320, height: 400),
              "bubble coordinates align with the captured image")
    try check(bubble.rect(in: CGSize(width: 800, height: 500)) == CGRect(x: 600, y: 50, width: 160, height: 200),
              "bubble coordinates follow window scaling")
    let translation = PageTranslation(summary: "测试", dialogues: [Dialogue(location: "右", original: "おはよう", translation: "早上好", bounds: bubble)], notes: "")
    _ = try cache.save(page: page, options: first, translation: translation, elapsed: 1)
    try check(cache.lookup(page: page, options: first) != nil, "same page and model reuse cache")
    try check(cache.lookup(page: page, options: second) == nil, "switching models does not reuse another model's translation")
    try check(cache.lookup(page: page, options: deep) == nil, "changing reasoning depth has a separate cache")
    try check(cache.lookup(page: page, options: TranslationOptions(model: "model-a", effort: "low", promptVersion: 1)) == nil,
              "old translations without positions are not used for overlays")
    let modified = NSBitmapImageRep(cgImage: image)
    modified.setColor(NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 1), atX: 20, y: 20)
    let changed = try CapturedPage(image: modified.cgImage!, displaySize: page.displaySize)
    try check(cache.lookup(page: changed, options: first) == nil, "a small image change cannot reuse an old page's positions")
    try check(changed.isVisuallySimilar(to: page) && changed.hasSameTextRegions(as: page, regions: [bubble]),
              "a pixel change outside the text can preserve an existing translation without relaxing the cache key")
    try check(changed.hasSameContent(as: page), "isolated pixel noise does not resubmit a page")
    let addedBubble = NSBitmapImageRep(cgImage: image)
    for y in 30..<110 {
        for x in 30..<150 where x < 33 || x > 146 || y < 33 || y > 106 || (x % 15 < 5 && y % 20 < 8) {
            addedBubble.setColor(NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 1), atX: x, y: y)
        }
    }
    let newBubble = try CapturedPage(image: addedBubble.cgImage!, displaySize: page.displaySize)
    try check(newBubble.isVisuallySimilar(to: page) && newBubble.hasSameTextRegions(as: page, regions: [bubble])
              && !newBubble.hasSameContent(as: page), "new small bubble outside old OCR is detected despite overall visual similarity")
    var tracker = PageTracker()
    try check(tracker.observe(page) == nil && tracker.isSettling, "first frame waits for confirmation")
    try check(tracker.observe(page)?.digest == page.digest && tracker.needsSubmission, "two stable frames submit the initial page")
    tracker.markSubmitted(page.digest)
    try check(tracker.observe(changed)?.digest == page.digest && !tracker.needsSubmission,
              "cosmetic pixel noise keeps the original page and does not repeat OCR")
    try check(tracker.observe(newBubble) == nil && tracker.isSettling, "a newly added bubble first hides the previous overlay")
    try check(tracker.observe(page)?.digest == page.digest && !tracker.needsSubmission,
              "one transient frame does not cancel or resubmit an unchanged page")
    _ = tracker.observe(newBubble)
    try check(tracker.observe(newBubble)?.digest == newBubble.digest && tracker.needsSubmission,
              "a stable new bubble triggers the next page even while old translation is running")
    tracker.markSubmitted(newBubble.digest)
    _ = tracker.observe(newBubble)
    try check(!tracker.needsSubmission, "failed or empty pages are not retried continuously")
    _ = tracker.observe(page)
    try check(tracker.observe(page)?.digest == page.digest && tracker.needsSubmission,
              "turning the page after failure continues translation and revisits may use cache")
    try check(AppError.translationFailure("Usage limit reached").needsUserAction
              && AppError.translationFailure("Unauthorized 401").needsUserAction
              && !AppError.translationFailure("Connection reset").needsUserAction,
              "login and quota errors pause while page or network failures keep automatic tracking")
    func spinnerFrame(_ original: CGImage, offset: Int) throws -> CapturedPage {
        let pixels = NSBitmapImageRep(cgImage: original)
        for y in 30..<65 {
            for x in (220+offset)..<(235+offset) {
                pixels.setColor(NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 1), atX: x, y: y)
            }
        }
        return try CapturedPage(image: pixels.cgImage!, displaySize: page.displaySize)
    }
    var animated = PageTracker(); animated.adopt(page); animated.markSubmitted(page.digest)
    _ = animated.observe(try spinnerFrame(image, offset: 0))
    let spinning = animated.observe(try spinnerFrame(image, offset: 25))
    try check(spinning?.digest == page.digest && !animated.needsSubmission && !animated.isSettling,
              "an animated button does not repeatedly cancel translation")
    _ = animated.observe(try spinnerFrame(newBubble.image, offset: 0))
    let withNewBubble = animated.observe(try spinnerFrame(newBubble.image, offset: 25))
    try check(withNewBubble != nil && animated.needsSubmission,
              "a stable new bubble is detected even while another region keeps animating")
    let modifiedText = NSBitmapImageRep(cgImage: image)
    modifiedText.setColor(NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 1), atX: 1205, y: 105)
    let textChange = try CapturedPage(image: modifiedText.cgImage!, displaySize: page.displaySize)
    try check(textChange.isVisuallySimilar(to: page) && !textChange.hasSameTextRegions(as: page, regions: [bubble]),
              "a small text change is detected even when the overall page looks similar")
    let reloaded = try TranslationCache(directory: root.appendingPathComponent("cache"))
    try check(reloaded.lookup(page: page, options: first)?.translation.dialogues.first?.translation == "早上好", "cache survives relaunch")
    try check(reloaded.lookup(page: page, options: first)?.translation.dialogues.first?.bounds?.x == 750,
              "cached translations preserve bubble positions")
    let run = try CommandRunner().run(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["ok"], directory: root)
    try check(run.status == 0 && String(decoding: run.stdout, as: UTF8.self).contains("ok"), "subprocess output is collected")
    let cancelled = CommandRunner(); cancelled.cancel()
    do {
        _ = try cancelled.run(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["should not run"], directory: root)
        throw AppError.message("FAIL: cancelled job launched")
    } catch is CancellationError { print("PASS: cancellation prevents a queued subprocess from starting") }
    let block = OCRBlock(id: "b1", text: "おはよう", bounds: bubble)
    let recognized = OCRPage(blocks: [block], skippedCount: 0, elapsed: 0)
    let resolved = try TranslationReply(status: "ok", message: "", translations: [.init(id: "b1", text: "早上好")]).resolve(ocr: recognized)
    try check(resolved.dialogues.first?.bounds?.x == bubble.x, "translations retain local OCR coordinates")
    let unclear = try TranslationReply(status: "partial", message: "局部待确认", translations: [
        .init(id: "b1", text: "🌧明天[原文不清]一起去")]).resolve(ocr: recognized)
    try check(unclear.dialogues[0].translation == "🌧明天□一起去"
              && unclear.dialogues[0].uncertainRanges == [TextGap(location: 4, length: 1)]
              && unclear.translatedCount == 1 && unclear.pendingCount == 1,
              "uncertain fragments become UTF-16 presentation ranges without losing readable dialogue")
    let unreadable = try TranslationReply(status: "partial", message: "", translations: [
        .init(id: "b1", text: "[原文不清]")]).resolve(ocr: recognized)
    try check(unreadable.preservedCount == 1 && unreadable.translatedCount == 0
              && unreadable.dialogues[0].bounds?.x == bubble.x && unreadable.pendingCount == 1,
              "an unreadable balloon keeps its original bounds and is not counted as translated")
    let unreadablePage = try TranslationReply(status: "unreadable", message: "待确认", translations: []).resolve(ocr: recognized)
    try check(unreadablePage.preservedCount == 1 && unreadablePage.skippedCount == 0,
              "a reported unreadable page retains every original balloon without a repair loop")
    try check(!TranslationReply.usable(source: "おはよう", translated: "おはよう□")
              && TranslationReply.usable(source: "おはよう", translated: "早上□")
              && !Dialogue.recognized(OCRBlock(id: "pause", text: "…", bounds: bubble), text: "…").needsReview,
              "a gap cannot disguise unchanged Japanese and ordinary punctuation is not an OCR warning")
    let localPatch = OCRBlock(id: "patch", text: "おはよう", bounds: bubble, replacementPNG: Data([1, 2, 3]), textStyle: "outlinedLight")
    let patched = try TranslationReply(status: "ok", message: "", translations: [.init(id: "patch", text: "早上好")])
        .resolve(ocr: OCRPage(blocks: [localPatch], skippedCount: 0, elapsed: 0))
    try check(patched.dialogues.first?.replacementPNG == localPatch.replacementPNG, "local glyph erasure patches survive translation mapping")
    try check(patched.dialogues.first?.textStyle == "outlinedLight", "open lettering keeps its local contrast style through translation")
    let tenBlocks = (1...10).map { OCRBlock(id: "b\($0)", text: "おはよう", bounds: DialogueBounds(x: 0, y: 0, width: 1, height: 1)) }
    let tenReply = TranslationReply(status: "ok", message: "", translations: tenBlocks.map { .init(id: $0.id, text: "早上好") })
    let tenResult = try tenReply.resolve(ocr: OCRPage(blocks: tenBlocks, skippedCount: 0, elapsed: 0))
    try check(tenResult.dialogues.count == 10 && tenResult.skippedCount == 0,
              "all ten translations are retained even when their regions cannot display text")
    for reply in [TranslationReply(status: "ok", message: "", translations: []),
                  TranslationReply(status: "ok", message: "", translations: [.init(id: "wrong", text: "早上好")]),
                  TranslationReply(status: "ok", message: "", translations: [.init(id: "b1", text: "好"), .init(id: "b1", text: "好")]),
                  TranslationReply(status: "refused", message: "不能翻译此内容", translations: [])] {
        do { _ = try reply.resolve(ocr: recognized); throw AppError.message("FAIL: invalid result accepted") }
        catch let error as AppError {
            try check(!error.localizedDescription.hasPrefix("FAIL"), "empty, mismatched, duplicate and refused results are rejected")
        }
    }
    let textCache = try TextTranslationCache(directory: root.appendingPathComponent("text-cache"))
    let originalOCR = OCRPage(blocks: [
        OCRBlock(id: "b1", text: "おはよう", bounds: bubble, replacementPNG: Data([1])),
        OCRBlock(id: "b2", text: "雨ですね", bounds: bubble, replacementPNG: Data([2]))
    ], skippedCount: 0, elapsed: 0)
    let completeReply = TranslationReply(status: "ok", message: "", translations: [
        .init(id: "b1", text: "早上好"), .init(id: "b2", text: "下雨了呢")])
    let completeTranslation = try completeReply.resolve(ocr: originalOCR)
    let firstChunk = #"{"status":"ok","message":"","translations":[{"id":"b1","text":"早上好"}"#
    let incompleteChunk = firstChunk + #",{"id":"b2","text":"还在输"#
    try check(TranslationStream.preview(firstChunk, ocr: originalOCR)?.dialogues.count == 1
              && TranslationStream.preview(incompleteChunk, ocr: originalOCR)?.dialogues.count == 1,
              "streaming displays complete bubbles while an unfinished next bubble remains hidden")
    let escapedChunk = #"{"status":"ok","message":"","translations":[{"id":"b1","text":"括号 } 和引号 \" 保持完整 🌧"}"#
    try check(TranslationStream.preview(escapedChunk, ocr: originalOCR)?.dialogues.first?.translation == "括号 } 和引号 \" 保持完整 🌧",
              "quoted braces, escaped quotes and Unicode do not split streamed dialogue")
    let duplicateChunk = firstChunk + #",{"id":"b1","text":"重复"}"#
    let foreignChunk = #"{"status":"ok","message":"","translations":[{"id":"foreign","text":"未知"}"#
    try check(TranslationStream.preview(duplicateChunk, ocr: originalOCR) == nil
              && TranslationStream.preview(foreignChunk, ocr: originalOCR) == nil,
              "streamed duplicate or foreign IDs never enter the overlay")
    try check(TranslationStream.preview(firstChunk.replacingOccurrences(of: "\"ok\"", with: "\"refused\""), ocr: originalOCR) == nil,
              "a refused reply cannot be previewed or turned into a success")
    do {
        let unfinished = try JSONDecoder().decode(TranslationReply.self, from: Data((firstChunk + "]}").utf8))
        _ = try unfinished.resolve(ocr: originalOCR)
        throw AppError.message("FAIL: incomplete final output accepted")
    } catch let error as AppError {
        try check(!error.localizedDescription.hasPrefix("FAIL"), "final streamed output still requires every expected ID")
    }
    try textCache.save(ocr: originalOCR, options: first, translation: completeTranslation)
    let movedBounds = DialogueBounds(x: 10, y: 20, width: 100, height: 100)
    let movedOCR = OCRPage(blocks: [
        OCRBlock(id: "new1", text: "おはよう", bounds: movedBounds, replacementPNG: Data([3])),
        OCRBlock(id: "new2", text: "雨ですね", bounds: movedBounds, replacementPNG: Data([4]))
    ], skippedCount: 0, elapsed: 0)
    let reused = textCache.lookup(ocr: movedOCR, options: first)
    try check(reused?.dialogues.map(\.translation) == ["早上好", "下雨了呢"], "identical ordered OCR reuses translations after window changes")
    try check(reused?.dialogues.first?.location == "new1" && reused?.dialogues.first?.bounds?.x == 10
              && reused?.dialogues.first?.replacementPNG == Data([3]), "reused text always binds to current IDs, coordinates and glyph patches")
    try textCache.save(ocr: recognized, options: first, translation: unclear)
    try check(textCache.lookup(ocr: recognized, options: first)?.dialogues.first?.uncertainRanges == unclear.dialogues[0].uncertainRanges,
              "uncertain-fragment metadata survives text cache reuse")
    try textCache.save(ocr: recognized, options: second, translation: unreadable)
    try check(textCache.lookup(ocr: recognized, options: second)?.preservedCount == 1,
              "an unreadable cached result cannot erase the original on return")
    try check(textCache.lookup(ocr: movedOCR, options: second) == nil
              && textCache.lookup(ocr: movedOCR, options: deep) == nil, "text cache isolates model and effort")
    let reversedOCR = OCRPage(blocks: Array(movedOCR.blocks.reversed()), skippedCount: 0, elapsed: 0)
    let editedOCR = OCRPage(blocks: [OCRBlock(id: "b1", text: "おはよう！", bounds: bubble), movedOCR.blocks[1]], skippedCount: 0, elapsed: 0)
    try check(textCache.lookup(ocr: reversedOCR, options: first) == nil
              && textCache.lookup(ocr: editedOCR, options: first) == nil, "changed text or reading order does not reuse translation context")
    let partialTranslation = try TranslationReply(status: "partial", message: "文字不清晰", translations: [.init(id: "new1", text: "早上好")]).resolve(ocr: movedOCR)
    try textCache.save(ocr: movedOCR, options: second, translation: partialTranslation)
    try check(textCache.lookup(ocr: movedOCR, options: second) == nil, "partial translations are not cached as a complete OCR input")
    let countedOCR = OCRPage(blocks: movedOCR.blocks, skippedCount: 3, elapsed: 0)
    let counted = try TranslationReply(status: "partial", message: "文字不清晰", translations: [.init(id: "new1", text: "早上好")]).resolve(ocr: countedOCR)
    try check(counted.ocrSkippedCount == 3 && counted.untranslatedCount == 1 && counted.skippedCount == 4,
              "unrecognized candidates and untranslated dialogue are counted separately")
    let openOCR = OCRPage(blocks: [OCRBlock(id: "open", text: "雨", bounds: bubble, replacementAllowed: false)], skippedCount: 0, elapsed: 0)
    let openTranslation = try TranslationReply(status: "ok", message: "", translations: [.init(id: "open", text: "下雨")]).resolve(ocr: openOCR)
    try textCache.save(ocr: openOCR, options: first, translation: openTranslation)
    try check(textCache.lookup(ocr: openOCR, options: first)?.dialogues.first?.replacementAllowed == false,
              "open text is translated and cached without borrowing an erasure mask")
    let limited = root.appendingPathComponent("limited")
    try FileManager.default.createDirectory(at: limited, withIntermediateDirectories: true)
    for i in 0..<4 {
        let file = limited.appendingPathComponent("\(i).json")
        try Data(repeating: 1, count: 80).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(i))], ofItemAtPath: file.path)
    }
    CacheFiles.touch(limited.appendingPathComponent("0.json"))
    CacheFiles.trim(limited, maxBytes: 170)
    let retained = try FileManager.default.contentsOfDirectory(atPath: limited.path)
    try check(Set(retained) == Set(["0.json", "3.json"]), "byte budget evicts old cache files while retaining recently used entries")
    CacheFiles.trim(limited, maxBytes: 1000, maxCount: 1)
    let finalCount = try FileManager.default.contentsOfDirectory(atPath: limited.path).count
    try check(finalCount == 1, "count limit also applies below the byte budget")
    try MainActor.assumeIsolated {
        try check(FittedText.make("早上好", rect: CGRect(x: 0, y: 0, width: 100, height: 50)) != nil, "complete translation fits")
        let trimmedGap = FittedText.make(" \n🌧明□去", rect: CGRect(x: 0, y: 0, width: 150, height: 60),
            maxFontSize: 18, gaps: [TextGap(location: 5, length: 1)])!
        let gapRuns = (CTFrameGetLines(trimmedGap.frame) as! [CTLine]).flatMap { CTLineGetGlyphRuns($0) as! [CTRun] }
        try check(gapRuns.contains { run in
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let font = attributes[kCTFontAttributeName] as! CTFont
            return CTRunGetStringRange(run).location == 3 && CTFontGetSize(font) < 14
        }, "leading whitespace and emoji keep the small gap style on the correct character")
        try check(FittedText.make(String(repeating: "很长的译文", count: 40), rect: CGRect(x: 0, y: 0, width: 12, height: 12)) == nil,
                  "overflow keeps the original instead of truncating text")
        _ = NSApplication.shared
        let overlay = MangaOverlay()
        defer { overlay.stop() }
        let unreadableEntry = CacheEntry(id: "unreadable-result", options: first, pageDigest: page.digest,
            translation: unreadable, createdAt: Date(), elapsed: 1)
        overlay.show(unreadableEntry, page: page, windowID: 0, processID: ProcessInfo.processInfo.processIdentifier, topInset: 0)
        try check(overlay.renderedCount == 0 && overlay.omittedSummary.isEmpty,
                  "unreadable originals are intentionally preserved, not reported as display failures")
        try check(FittedText.flow(unclear.dialogues[0].translation,
            regions: [CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 110, y: 0, width: 100, height: 100)],
            style: nil, vertical: true, maxFontSize: 18, gaps: unclear.dialogues[0].uncertainRanges ?? [])?.count == 2,
                  "connected balloons preserve uncertainty styling across a Unicode split")
        let hiddenTranslation = PageTranslation(summary: "", dialogues: [Dialogue(location: "b1", original: "おはよう",
            translation: "早上好", bounds: DialogueBounds(x: 550, y: 220, width: 387.5, height: 520))], notes: "")
        let hiddenEntry = CacheEntry(id: "background-result", options: first, pageDigest: page.digest,
                                    translation: hiddenTranslation, createdAt: Date(), elapsed: 1)
        overlay.show(hiddenEntry, page: page, windowID: 0,
                     processID: ProcessInfo.processInfo.processIdentifier, topInset: 0)
        try check(overlay.renderedCount == 1, "a result arriving while the reader is hidden still lays out its translation")
        try check(overlay.diagnosticState["visible"] as? Bool == false, "prepared translations stay hidden while the reader is hidden")
        let unfitEntry = CacheEntry(id: "unfit-result", options: first, pageDigest: page.digest,
                                   translation: tenResult, createdAt: Date(), elapsed: 1)
        overlay.show(unfitEntry, page: page, windowID: 0, processID: ProcessInfo.processInfo.processIdentifier, topInset: 0)
        try check(overlay.renderedCount == 0 && overlay.omittedSummary.contains("气泡空间不足 10 处"),
                  "display failures are counted separately with a reason, without dropping translations")
        let openEntry = CacheEntry(id: "open-result", options: first, pageDigest: page.digest,
                                  translation: openTranslation, createdAt: Date(), elapsed: 1)
        overlay.show(openEntry, page: page, windowID: 0, processID: ProcessInfo.processInfo.processIdentifier, topInset: 0)
        try check(overlay.renderedCount == 0 && overlay.omittedSummary.contains("开放文字区域 1 处"),
                  "open text is available to copy while its artwork stays unchanged")
    }
    let active = CommandRunner(), cancelStart = Date()
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { active.cancel() }
    do {
        _ = try active.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], directory: root)
        throw AppError.message("FAIL: active process not cancelled")
    } catch is CancellationError { try check(Date().timeIntervalSince(cancelStart) < 3, "stop cancels a running subprocess") }
    print("All checks passed.")
}

let arguments = CommandLine.arguments
if arguments.contains("--render-panel") || arguments.contains("--self-test") || arguments.contains("--make-fixture") || arguments.contains("--translate-file") || arguments.contains("--ocr-file") || arguments.contains("--make-vertical-fixture") || arguments.contains("--make-shaded-fixture") || arguments.contains("--render-result") {
    do {
        if let i = arguments.firstIndex(of: "--render-panel"), i + 1 < arguments.count {
            try MainActor.assumeIsolated { try AppController().renderPanel(to: URL(fileURLWithPath: arguments[i + 1]), dark: arguments.contains("--dark")) }
        }
        if arguments.contains("--self-test") { try selfTest() }
        if let i = arguments.firstIndex(of: "--render-result"), i + 3 < arguments.count {
            let image = NSImage(contentsOfFile: arguments[i+1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
            let result = try JSONDecoder().decode(PageTranslation.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[i+2])))
            let scaleIndex = arguments.firstIndex(of: "--scale")
            let scale = scaleIndex.flatMap { $0+1 < arguments.count ? Double(arguments[$0+1]) : nil } ?? 2
            guard scale.isFinite, scale > 0, scale <= 4 else { throw AppError.message("Invalid render scale") }
            let count = try MainActor.assumeIsolated { try OverlayPreview.render(result, image: image, destination: URL(fileURLWithPath: arguments[i+3]), scale: scale) }
            print("Rendered \(count)/\(result.dialogues.count) bubbles")
        }

        if let i = arguments.firstIndex(of: "--make-fixture"), i + 1 < arguments.count {
            try makeFixture(URL(fileURLWithPath: arguments[i + 1])); print("Fixture created.")
        }
        if let i = arguments.firstIndex(of: "--make-vertical-fixture"), i + 1 < arguments.count {
            try makeFixture(URL(fileURLWithPath: arguments[i + 1]), vertical: true)
        }
        if let i = arguments.firstIndex(of: "--make-shaded-fixture"), i + 1 < arguments.count {
            try makeFixture(URL(fileURLWithPath: arguments[i + 1]), vertical: true, shaded: true)
        }
        if let i = arguments.firstIndex(of: "--translate-file") ?? arguments.firstIndex(of: "--ocr-file"), i + 1 < arguments.count {
            let file = URL(fileURLWithPath: arguments[i + 1])
            guard let image = NSImage(contentsOf: file)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw AppError.message("Cannot open input image")
            }
            let modelIndex = arguments.firstIndex(of: "--model")
            let model = modelIndex.flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } ?? "gpt-6.1-sol"
            let job = FileManager.default.temporaryDirectory.appendingPathComponent("shiori-smoke-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: job) }
            let client = try CodexClient(resources: Bundle.main.resourceURL!, workspace: job)
            defer { client.shutdown() }
            let support = try AppStorage.directory()
            let ocr = try LocalOCR(support: job, resources: Bundle.main.resourceURL!, engineRoot: support.appendingPathComponent("OCR"))
            defer { ocr.shutdown() }
            let began = Date(), page = try CapturedPage(image: image)
            let recognized = try ocr.recognize(page: page, runner: CommandRunner(), progress: { fputs($0 + "\n", stderr) })
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            if arguments.contains("--ocr-file") {
                print(String(decoding: try encoder.encode(recognized), as: UTF8.self))
            } else {
                guard !recognized.blocks.isEmpty else { throw AppError.message("No text recognized in fixture") }
                let result = try client.translate(ocr: recognized, options: TranslationOptions(model: model, effort: "low"), runner: CommandRunner(),
                    progress: { fputs($0 + "\n", stderr) }, preview: { partial in
                        fputs(String(format: "PREVIEW=%d/%d AT=%.2fs\n", partial.dialogues.count, recognized.blocks.count, Date().timeIntervalSince(began)), stderr)
                    })
                print(String(decoding: try encoder.encode(result.0), as: UTF8.self))
                fputs(String(format: "MODEL=%@ TRANSLATE=%.2fs TOTAL=%.2fs\n", model, result.1, Date().timeIntervalSince(began)), stderr)
            }
        }
    } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let controller = AppController()
        app.delegate = controller
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
