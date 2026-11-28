import AppKit
import Foundation

@main
struct PipelineTests {
    static func main() throws {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) throws {
            guard value() else { throw AppError.message("FAIL: " + label) }
            count += 1; print("PASS: " + label)
        }
        let bounds = DialogueBounds(x: 10, y: 10, width: 100, height: 100)
        let draft = OCRPage(blocks: [OCRBlock(id: "a", text: "おはよう", bounds: bounds, replacementAllowed: false)], skippedCount: 1, elapsed: 0)
        let patch = Data([1, 2, 3])
        let final = OCRPage(blocks: [OCRBlock(id: "a", text: "おはよう", bounds: bounds, replacementPNG: patch, replacementAllowed: true)], skippedCount: 1, elapsed: 0)
        let started = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var previews: [PageTranslation] = []
        let result = try TranslationPipeline.run(runner: CommandRunner(), recognize: { ready in
            ready(draft)
            guard started.wait(timeout: .now() + 2) == .success else { throw AppError.message("Translation waited for repairs") }
            lock.lock(); let early = previews.count; lock.unlock()
            try check(early == 0, "unfinished repairs never reach the overlay")
            return final
        }, translate: { page, _, preview in
            let translated = PageTranslation(summary: "", dialogues: [Dialogue.recognized(page.blocks[0], text: "早上好")], notes: "", skippedCount: 1, ocrSkippedCount: 1)
            preview(translated); started.signal()
            return translated
        }, preview: { page, _, _ in lock.lock(); previews.append(page); lock.unlock() })
        try check(result.0.dialogues.first?.replacementPNG == patch, "early translation binds final background patches")
        try check(result.0.skippedCount == 1 && result.0.untranslatedCount == 0, "OCR omissions retain their own count")
        try check(result.1.firstResult != nil, "first visible result is timed after geometry is ready")
        try check(previews.allSatisfy { $0.dialogues.first?.replacementAllowed == true }, "all previews use repaired geometry")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32)!
        for (index, value) in [UInt8](arrayLiteral: 0, 0, 0, 0, 255, 255, 255, 255,
                                     255, 255, 255, 255, 0, 0, 0, 0).enumerated() {
            bitmap.bitmapData![index] = value
        }
        let validPatch = bitmap.representation(using: .png, properties: [:])!
        let safe = OCRBlock(id: "safe", text: "おはよう", bounds: bounds, replacementPNG: validPatch, replacementAllowed: true)
        let pending = OCRBlock(id: "pending", text: "こんにちは", bounds: bounds, replacementAllowed: false)
        let open = OCRBlock(id: "open", text: "ざわざわ", bounds: bounds, replacementPNG: validPatch,
                            replacementAllowed: true, textStyle: "outlinedDark")
        let mixed = OCRPage(blocks: [safe, pending, open], skippedCount: 1, elapsed: 0)
        var repairedPending = pending; repairedPending.replacementPNG = validPatch; repairedPending.replacementAllowed = true
        let repaired = OCRPage(blocks: [safe, repairedPending, open], skippedCount: 1, elapsed: 0)
        let allText = PageTranslation(summary: "", dialogues: zip(mixed.blocks, ["早安", "你好", "沙沙"]).map {
            Dialogue.recognized($0.0, text: $0.1)
        }, notes: "")
        let firstVisible = DispatchSemaphore(value: 0)
        var mixedPreviews: [PageTranslation] = []
        let fast = try TranslationPipeline.run(runner: CommandRunner(), recognize: { ready in
            ready(mixed)
            guard firstVisible.wait(timeout: .now() + 2) == .success else { throw AppError.message("Safe balloon waited for complex background") }
            lock.lock(); let early = mixedPreviews; lock.unlock()
            try check(!early.isEmpty && early.allSatisfy { $0.dialogues.map(\.location) == ["safe"] }, "only a verified closed-balloon PNG appears before complex repairs")
            try check(early[0].skippedCount == 3 && early[0].ocrSkippedCount == 1, "unready backgrounds remain pending without losing OCR omissions")
            Thread.sleep(forTimeInterval: 0.04)
            return repaired
        }, translate: { _, _, preview in preview(allText); return allText }, preview: { page, _, _ in
            lock.lock(); mixedPreviews.append(page); lock.unlock(); firstVisible.signal()
        })
        try check(fast.0.dialogues.count == 3 && fast.0.untranslatedCount == 0, "final repairs add remaining backgrounds without losing early text")
        try check(fast.1.firstResult! < fast.1.ocr, "first visible balloon is timed before all-page repair completion")
        var broken = safe; broken.replacementPNG = Data([1, 2, 3])
        var missing = safe; missing.replacementPNG = nil
        try check(!TranslationPipeline.earlyPatchIsReady(broken) && !TranslationPipeline.earlyPatchIsReady(missing)
                  && !TranslationPipeline.earlyPatchIsReady(open), "missing, damaged and open-background patches cannot enable a draft preview")
        let cancelledEarly = CommandRunner(), earlyShown = DispatchSemaphore(value: 0)
        var cancelPreviews = 0
        do {
            _ = try TranslationPipeline.run(runner: cancelledEarly, recognize: { ready in
                ready(mixed)
                guard earlyShown.wait(timeout: .now() + 2) == .success else { throw AppError.message("No early preview") }
                cancelledEarly.cancel(); return repaired
            }, translate: { _, _, preview in
                preview(allText); Thread.sleep(forTimeInterval: 0.08); preview(allText); return allText
            }, preview: { _, _, _ in lock.lock(); cancelPreviews += 1; lock.unlock(); earlyShown.signal() })
            throw AppError.message("FAIL: cancelled early pipeline succeeded")
        } catch is CancellationError {
            try check(cancelPreviews == 1, "cancelled early page suppresses late translation and final geometry previews")
        }
        let wrong = OCRPage(blocks: [OCRBlock(id: "a", text: "違うページ", bounds: bounds)], skippedCount: 0, elapsed: 0)
        try check(TranslationPipeline.bind(result.0, to: wrong).dialogues.isEmpty, "different OCR text cannot inherit an old translation")
        var invoked = false
        let empty = try TranslationPipeline.run(runner: CommandRunner(), recognize: { _ in OCRPage(blocks: [], skippedCount: 2, elapsed: 0) }, translate: { _, _, _ in invoked = true; return result.0 }, preview: { _, _, _ in })
        try check(!invoked && empty.0.skippedCount == 2, "empty OCR never makes a network request")
        let cancelled = CommandRunner()
        do {
            _ = try TranslationPipeline.run(runner: cancelled, recognize: { _ in cancelled.cancel(); return final }, translate: { _, _, _ in throw AppError.message("Must not run") }, preview: { _, _, _ in })
            throw AppError.message("FAIL: cancelled pipeline succeeded")
        } catch is CancellationError { try check(true, "cancellation prevents translation launch") }
        let failed = CommandRunner()
        do {
            _ = try TranslationPipeline.run(runner: failed, recognize: { ready in
                ready(draft)
                let deadline = Date().addingTimeInterval(2)
                while !failed.isCancelled && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
                try failed.checkCancellation()
                throw AppError.message("Repairs were not cancelled on translation failure")
            }, translate: { _, _, _ in throw AppError.configuration("Service denied") }, preview: { _, _, _ in })
            throw AppError.message("FAIL: service error succeeded")
        } catch let error as AppError {
            try check(error.needsUserAction && error.localizedDescription == "Service denied", "service failure cancels repairs and preserves the original error")
        }
        func page(_ blocks: [OCRBlock], skipped: Int = 0) -> OCRPage {
            OCRPage(blocks: blocks, skippedCount: skipped, elapsed: 0)
        }
        func block(_ id: String, _ text: String) -> OCRBlock {
            OCRBlock(id: id, text: text, bounds: bounds, replacementPNG: validPatch, replacementAllowed: true)
        }
        func translated(_ page: OCRPage) -> PageTranslation {
            PageTranslation(summary: "", dialogues: page.blocks.map { Dialogue.recognized($0, text: "译：" + $0.text) }, notes: "")
        }
        func wait(_ semaphore: DispatchSemaphore, _ label: String) throws {
            guard semaphore.wait(timeout: .now() + 2) == .success else { throw AppError.message("FAIL: " + label) }
        }
        let first = block("first", "早い")
        let second = block("second", "後から")
        let send = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        var requests: [[String]] = []
        let whole = page([first, second], skipped: 2)
        let singleRequest = try TranslationPipeline.run(runner: CommandRunner(), renderPatches: false,
            recognize: { ready in
                ready(whole)
                try wait(send, "whole-page translation starts before background repairs")
                release.signal()
                return whole
            }, translate: { input, context, preview in
                requests.append(input.blocks.map(\.id))
                guard context.blocks.count == 2 else { throw AppError.message("Missing context") }
                preview(translated(input)); send.signal()
                try wait(release, "allow the whole-page request to finish")
                return translated(input)
            }, preview: { _, _, _ in })
        try check(requests == [["first", "second"]] && singleRequest.timings.translationBatches == 1,
                  "final text reaches one request in page reading order")
        try check(singleRequest.translation.ocrSkippedCount == 2
                    && singleRequest.translation.untranslatedCount == 0, "OCR omissions remain separate from translation omissions")

        let startedChange = DispatchSemaphore(value: 0)
        do {
            _ = try TranslationPipeline.run(runner: CommandRunner(), recognize: { ready in
                ready(whole)
                try wait(startedChange, "validated text begins translation")
                return page([block("first", "誤った別の原文"), second])
            }, translate: { input, _, _ in
                startedChange.signal(); return translated(input)
            }, preview: { _, _, _ in })
            throw AppError.message("FAIL: changed final text reused the old request")
        } catch let error as AppError {
            try check(error.localizedDescription.contains("叠层内容不一致"), "patch-only completion rejects unexpected changed text")
        }

        var incompletePreviews: [PageTranslation] = []
        let incomplete = try TranslationPipeline.run(runner: CommandRunner(),
            recognize: { _ in whole },
            translate: { input, _, preview in
                preview(translated(input))
                return translated(page([first]))
            }, preview: { value, _, _ in incompletePreviews.append(value) })
        try check(incomplete.translation.untranslatedCount == 1
                    && incompletePreviews.last?.dialogues.map(\.location) == [first.id],
                  "an omitted provider final withdraws its streaming result and leaves the page incomplete")

        do {
            _ = try TranslationPipeline.run(runner: CommandRunner(), recognize: { _ in page([first, first]) },
                translate: { _, _, _ in throw AppError.message("Should not start translating duplicate IDs") },
                preview: { _, _, _ in })
            throw AppError.message("FAIL: duplicate OCR ids succeeded")
        } catch let error as AppError {
            try check(error.localizedDescription.contains("重复气泡"), "duplicate final IDs fail before a network request")
        }
        var manual = Dialogue.recognized(block("first", "人工確認"), text: "手动译文□")
        manual.userEdited = true
        var restored = Dialogue.recognized(second, text: "旧译文")
        restored.preserveOriginal = true; restored.userRestoredOriginal = true
        var absent = Dialogue.recognized(block("absent", "別の頁"), text: "不在本页")
        absent.userEdited = true
        let automatic = block("auto", "確認しました")
        var manualDraft = first; manualDraft.replacementPNG = nil; manualDraft.replacementAllowed = false
        let current = page([first, second, automatic])
        let corrected = try TranslationPipeline.run(runner: CommandRunner(), corrections: [manual, restored, absent],
            recognize: { ready in
                ready(page([manualDraft, second, automatic])); return current
            }, translate: { input, context, _ in
                guard input.blocks.map(\.id) == ["auto"], context.blocks.first?.text == manual.original else {
                    throw AppError.message("Invalid correction/context")
                }
                return translated(input)
            }, preview: { _, _, _ in })
        let rebound = corrected.translation.dialogues.first
        try check(rebound?.original == manual.original && rebound?.translation == manual.translation
                    && rebound?.replacementPNG == validPatch && rebound?.uncertainRanges == manual.uncertainRanges,
                  "manual correction uses current pixels while preserving the edited text and uncertainty")
        try check(corrected.translation.dialogues.count == 3
                    && corrected.translation.dialogues[1].userRestoredOriginal == true,
                  "restored originals stay visible and absent corrections cannot add a region")
        let manualOnly = try TranslationPipeline.run(runner: CommandRunner(), corrections: [manual],
            recognize: { _ in page([first]) },
            translate: { _, _, _ in throw AppError.message("Manual regions do not need a request") },
            preview: { _, _, _ in })
        try check(manualOnly.timings.translationBatches == 0 && manualOnly.translation.dialogues.first?.userEdited == true,
                  "a page containing only manual corrections completes locally")

        func scope(_ raw: String) -> ReadingScope { ReadingScope(windowID: 5, documentURL: URL(string: raw)!) }
        try check(scope("https://shonenjumpplus.com/episode/42?page=1#viewer") == scope("https://shonenjumpplus.com/episode/42?page=8"), "known episode pagination stays in scope")
        try check(scope("https://shonenjumpplus.com/episode/42") != scope("https://shonenjumpplus.com/episode/43"), "other episode pauses automatic reading")
        try check(scope("https://e-hentai.org/s/abc/123-1") == scope("https://e-hentai.org/s/xyz/123-20"), "gallery image keys do not break pagination")
        try check(scope("https://exhentai.org/g/123/token/?p=1") == scope("https://exhentai.org/s/xyz/123-20"),
                  "opening an image after starting at gallery thumbnails keeps reading enabled")
        try check(scope("https://e-hentai.org/g/123/token/") != scope("https://e-hentai.org/s/xyz/456-1"),
                  "a different gallery remains outside the original reading session")
        try check(scope("https://exhentai.org/g/123-invalid/token/") != scope("https://exhentai.org/s/xyz/123-1"),
                  "a malformed gallery identifier cannot authorize another reader page")
        try check(scope("https://reader.example/?p=1") != scope("https://reader.example/?p=2"), "unknown query routes remain distinct")
        try check(scope("https://reader.example/#/one") != scope("https://reader.example/#/two"), "SPA fragment routes remain distinct")
        try check(!scope("https://reader.example/").accepts(windowID: 6, documentURL: URL(string: "https://reader.example/")), "another window cannot enter the reading session")
        try check(!scope("https://reader.example/").accepts(windowID: 5, documentURL: nil), "missing browser identity cannot match a known page")
        let legacy = Data(#"{"model":"gpt-6-luna","effort":"low","promptVersion":17,"context":"test"}"#.utf8)
        let old = try JSONDecoder().decode(TranslationOptions.self, from: legacy)
        try check(old.provider == .codex && old.cacheNamespace == "gpt-6-luna|low|zh-Hans|17", "existing Codex settings and caches stay compatible")
        let google = TranslationOptions(model: old.model, effort: old.effort, provider: .google)
        try check(old != google, "translation services never share a cache namespace")
        print("\(count) pipeline/scope checks passed")
    }
}
