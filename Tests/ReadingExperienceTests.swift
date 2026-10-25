import AppKit
import Foundation

@main
struct ReadingExperienceTests {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw AppError.message("FAIL: " + message) }
            checks += 1; print("PASS: " + message)
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shiori-experience-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let readerSurface = OverlaySurface(id: 1, frame: CGRect(x: 0, y: 0, width: 800, height: 600), layer: 0, alpha: 1)
        let cover = OverlaySurface(id: 2, frame: CGRect(x: 400, y: 0, width: 400, height: 600), layer: 0, alpha: 1)
        let translatedSurface = OverlaySurface(id: 3, frame: readerSurface.frame, layer: 0, alpha: 1)
        try check(ReaderWindowVisibility.pointerHitsReader(CGPoint(x: 200, y: 200), target: 1,
            surfaces: [cover, translatedSurface, readerSurface], ignoring: [3]), "an inactive reader's uncovered area can show an explicit translation peek")
        try check(!ReaderWindowVisibility.pointerHitsReader(CGPoint(x: 600, y: 200), target: 1,
            surfaces: [cover, translatedSurface, readerSurface], ignoring: [3]), "another app under the pointer cannot trigger a reader tooltip")
        let store = try WorkProfileStore(directory: folder)
        var a = try store.resolve(context: "reader|book-a/chapter-1", title: "作品 A")
        let b = try store.resolve(context: "reader|book-b/chapter-1", title: "作品 B")
        a.terms = try WorkProfile.parseTerms("葵 = 小葵\n一ノ瀬 = 一之濑\n葵 = 葵酱")
        try check(a.terms.count == 2 && a.terms.last?.translation == "葵酱", "duplicate glossary words use the last explicit correction")
        a.style = "保留日文称呼"; try store.save(a)
        try store.save(a, context: "reader|book-a/chapter-2")
        let restarted = try WorkProfileStore(directory: folder)
        let sameBook = try restarted.resolve(context: "reader|book-a/chapter-2", title: "另一章")
        try check(sameBook == a, "choosing a saved work carries names and style across chapters and app restarts")
        try check(restarted.profile(id: b.id)?.terms.isEmpty == true, "another work never inherits the current glossary")
        let gridWords = try WorkProfile.validatedTerms([WorkTerm(source: " x = y ", translation: "关系"), WorkTerm(source: "", translation: " ")])
        try check(gridWords == [WorkTerm(source: "x = y", translation: "关系")], "table editing keeps literal equals signs and ignores a completely empty new row")
        var incompleteGrid = false
        do { _ = try WorkProfile.validatedTerms([WorkTerm(source: "葵", translation: "")]) } catch { incompleteGrid = true }
        try check(incompleteGrid, "a half-filled table row cannot overwrite a saved glossary")
        var invalidTerms = false
        do { _ = try WorkProfile.parseTerms("缺少等号") } catch { invalidTerms = true }
        try check(invalidTerms, "invalid vocabulary is rejected before replacing saved data")

        let plan = GlossaryPlan(source: "葵と葵と一ノ瀬 I", terms: a.terms + [WorkTerm(source: "I", translation: "我")])
        let restored = try plan.restore(plan.text.lowercased())
        try check(restored == "葵酱と葵酱と一之濑 我", "repeated names and English terms survive one-pass masking without modifying placeholders")
        let spaced = plan.text.map(String.init).joined(separator: " ")
        let restoredSpaced = try plan.restore(spaced)
        try check(restoredSpaced.contains("一之濑"), "provider spacing and case changes cannot expose glossary placeholders")
        var incomplete = false
        do { _ = try plan.restore("模型漏掉了用词") } catch { incomplete = true }
        try check(incomplete, "a missing glossary token fails safely instead of leaking an internal marker")

        var first = TranslationOptions(model: "test", effort: "low", context: a.id)
        first.guidance = a.guidance; first.terms = a.terms
        var other = first; other.context = b.id
        try check(first.cacheNamespace != other.cacheNamespace, "identical OCR in different works has separate translation caches")
        other = first; other.terms.append(WorkTerm(source: "先生", translation: "老师"))
        try check(first != other, "changing confirmed words invalidates translations made with old vocabulary")
        let legacy = Data(#"{"model":"test","effort":"low","promptVersion":17}"#.utf8)
        let old = try JSONDecoder().decode(TranslationOptions.self, from: legacy)
        try check(old.guidance.isEmpty && old.terms.isEmpty, "existing saved options decode without a profile migration")

        let bounds = DialogueBounds(x: 100, y: 100, width: 300, height: 500)
        let original = Dialogue(location: "old-id", original: "葵", translation: "葵", bounds: bounds)
        var manual = try BubbleCorrection.edited(original, source: "葵", translation: "葵酱")
        let originalPage = PageTranslation(summary: "", dialogues: [original], notes: "")
        let correctedPage = PageTranslation(summary: "", dialogues: [manual], notes: "")
        var history = CorrectionHistory()
        history.record(CorrectionSnapshot(translation: originalPage, profile: b), page: "page-a")
        let undo = history.undo(current: CorrectionSnapshot(translation: correctedPage, profile: a), page: "page-a")
        try check(undo?.translation.dialogues.first?.translation == "葵" && undo?.profile == b, "undo restores both the dialogue and learned work vocabulary")
        let redo = history.redo(current: undo!, page: "page-a")
        try check(redo?.translation.dialogues.first?.translation == "葵酱" && redo?.profile == a, "redo restores the saved correction and vocabulary together")
        history.select("page-b")
        try check(!history.canUndo && history.undo(current: undo!, page: "page-b") == nil, "page turns cannot apply an undo to another page")

        let context = CGContext(data: nil, width: 200, height: 160, bitsPerComponent: 8, bytesPerRow: 800,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 200, height: 160))
        let page = try CapturedPage(image: context.makeImage()!)
        let cache = try TranslationCache(directory: folder.appendingPathComponent("Translations"))
        manual.replacementPNG = Data([1, 2, 3])
        _ = try cache.save(page: page, options: first, translation: PageTranslation(summary: "", dialogues: [manual], notes: ""), elapsed: 1)
        let saved = cache.manualCorrections(page: page, options: first)
        try check(saved.count == 1 && saved[0].replacementPNG == nil, "durable manual corrections store text and location without duplicating image patches")
        let imageCacheFile = cache.directory.appendingPathComponent(TranslationCache.key(page.digest, first) + ".json")
        try FileManager.default.removeItem(at: imageCacheFile)
        var anotherModel = first; anotherModel.model = "another-model"
        try check(cache.manualCorrections(page: page, options: anotherModel).first?.translation == "葵酱", "manual work survives image cache eviction and a model change")
        _ = try cache.save(page: page, options: first, translation: PageTranslation(summary: "", dialogues: [], notes: "interrupted"), elapsed: 1, persistManual: false)
        try check(cache.manualCorrections(page: page, options: first).first?.translation == "葵酱", "an interrupted retranslation cannot erase a durable correction omitted from its partial result")

        let migration = folder.appendingPathComponent("migration/Translations")
        try FileManager.default.createDirectory(at: migration, withIntermediateDirectories: true)
        let newer = try BubbleCorrection.edited(manual, source: "葵", translation: "小葵")
        var second = Dialogue(location: "another-bubble", original: "先生", translation: "老师", bounds: bounds)
        second.userEdited = true
        let newest = CacheEntry(id: "new", options: first, pageDigest: page.digest,
            translation: PageTranslation(summary: "", dialogues: [newer], notes: ""), createdAt: Date(timeIntervalSince1970: 200), elapsed: 1)
        let older = CacheEntry(id: "old", options: first, pageDigest: page.digest,
            translation: PageTranslation(summary: "", dialogues: [manual, second], notes: ""), createdAt: Date(timeIntervalSince1970: 100), elapsed: 1)
        try JSONEncoder().encode(newest).write(to: migration.appendingPathComponent("a.json"))
        try JSONEncoder().encode(older).write(to: migration.appendingPathComponent("b.json"))
        let migrated = try TranslationCache(directory: migration).manualCorrections(page: page, options: first)
        try check(migrated.count == 2 && migrated.first(where: { $0.location == manual.location })?.translation == "小葵", "legacy migration preserves separate bubbles and uses the latest explicit correction regardless of file order")

        let block = OCRBlock(id: "new-detector-id", text: "葵", bounds: bounds, replacementAllowed: false)
        var translated = false
        let rebound = try TranslationPipeline.run(runner: CommandRunner(), corrections: saved, recognize: { _ in
            OCRPage(blocks: [block], skippedCount: 0, elapsed: 0)
        }, translate: { _, _ in translated = true; return originalPage }, preview: { _, _ in })
        try check(!translated && rebound.0.dialogues.first?.location == block.id && rebound.0.dialogues.first?.translation == "葵酱", "detector ID changes rebind a manual correction to the same physical bubble without translating again")
        let elsewhere = OCRBlock(id: manual.location, text: "別の文字", bounds: DialogueBounds(x: 700, y: 100, width: 100, height: 100))
        var oldEngine = saved[0]; oldEngine.correctionEngine = "manga-ocr-18"
        try check(TranslationPipeline.correction(for: elsewhere, in: [oldEngine]) == nil, "an older detector's reused ID cannot move a correction to a different bubble")

        let recognition = folder.appendingPathComponent("Recognition")
        try FileManager.default.createDirectory(at: recognition, withIntermediateDirectories: true)
        try Data("disposable".utf8).write(to: recognition.appendingPathComponent("page.json"))
        let models = folder.appendingPathComponent("OCR/models")
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        let model = models.appendingPathComponent("model.bin"); try Data("model".utf8).write(to: model)
        _ = try AppCacheManager.clear(root: folder)
        try check(!FileManager.default.fileExists(atPath: recognition.appendingPathComponent("page.json").path), "storage cleanup removes generated recognition cache")
        try check(FileManager.default.fileExists(atPath: model.path) && cache.manualCorrections(page: page, options: first).count == 1
            && FileManager.default.fileExists(atPath: folder.appendingPathComponent("WorkProfiles.json").path), "cleanup preserves installed models, profiles and manual corrections")

        _ = try cache.save(page: page, options: first, translation: originalPage, elapsed: 1)
        try check(cache.manualCorrections(page: page, options: first).isEmpty, "explicit undo to the unedited snapshot removes only that page's manual archive")

        try check(ReleaseVersion("v1.10.0")! > ReleaseVersion("1.9.9")! && ReleaseVersion("1.5")! == ReleaseVersion("1.5.0")!, "release versions compare numerically")
        try check(ReleaseVersion("1.5.0-beta") == nil && ReleaseVersion("../../1.5") == nil, "nonrelease versions cannot form an update package path")
        try check(AppRelease.allowed(URL(string: "https://github.com/pujx233/Shiori/releases/download/v1.5.0/app.zip")!)
            && !AppRelease.allowed(URL(string: "https://github.com.evil.example/pujx233/Shiori/releases/download/app.zip")!)
            && !AppRelease.allowed(URL(string: "https://github.com/other/repo/releases/download/app.zip")!), "updates accept only assets belonging to the Shiori repository")
        try AppUpdater.verifyChecksum(archive: Data("abc".utf8), manifest: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  app.zip", name: "app.zip")
        var rejected = false
        do { try AppUpdater.verifyChecksum(archive: Data("different".utf8), manifest: "bad  app.zip", name: "app.zip") } catch { rejected = true }
        try check(rejected, "a changed update archive cannot pass checksum verification")
        print("\(checks) reading experience checks passed")
    }
}
