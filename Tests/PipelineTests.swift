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
        }, translate: { page, preview in
            let translated = PageTranslation(summary: "", dialogues: [Dialogue.recognized(page.blocks[0], text: "早上好")], notes: "", skippedCount: 1, ocrSkippedCount: 1)
            preview(translated); started.signal()
            return translated
        }, preview: { page, _ in lock.lock(); previews.append(page); lock.unlock() })
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
        }, translate: { _, preview in preview(allText); return allText }, preview: { page, _ in
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
            }, translate: { _, preview in
                preview(allText); Thread.sleep(forTimeInterval: 0.08); preview(allText); return allText
            }, preview: { _, _ in lock.lock(); cancelPreviews += 1; lock.unlock(); earlyShown.signal() })
            throw AppError.message("FAIL: cancelled early pipeline succeeded")
        } catch is CancellationError {
            try check(cancelPreviews == 1, "cancelled early page suppresses late translation and final geometry previews")
        }
        let wrong = OCRPage(blocks: [OCRBlock(id: "a", text: "違うページ", bounds: bounds)], skippedCount: 0, elapsed: 0)
        try check(TranslationPipeline.bind(result.0, to: wrong).dialogues.isEmpty, "different OCR text cannot inherit an old translation")
        var invoked = false
        let empty = try TranslationPipeline.run(runner: CommandRunner(), recognize: { _ in OCRPage(blocks: [], skippedCount: 2, elapsed: 0) }, translate: { _, _ in invoked = true; return result.0 }, preview: { _, _ in })
        try check(!invoked && empty.0.skippedCount == 2, "empty OCR never makes a network request")
        let cancelled = CommandRunner()
        do {
            _ = try TranslationPipeline.run(runner: cancelled, recognize: { _ in cancelled.cancel(); return final }, translate: { _, _ in throw AppError.message("Must not run") }, preview: { _, _ in })
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
            }, translate: { _, _ in throw AppError.configuration("Service denied") }, preview: { _, _ in })
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
        let initial = block("first", "早い"), added = block("added", "後から"), removed = block("removed", "消える")
        let firstBatch = DispatchSemaphore(value: 0), releaseFirst = DispatchSemaphore(value: 0)
        var batches: [[String]] = [], incrementalPreviews: [PageTranslation] = []
        let incremental = try TranslationPipeline.run(runner: CommandRunner(), recognize: { ready in
            ready(page([initial]))
            try wait(firstBatch, "first batch begins before final OCR")
            ready(page([initial, removed]))
            ready(page([initial, added], skipped: 2))
            ready(page([initial, added], skipped: 2))
            releaseFirst.signal()
            return page([added, initial], skipped: 2)
        }, translate: { input, preview in
            lock.lock(); batches.append(input.blocks.map(\.id)); let index = batches.count; lock.unlock()
            let value = translated(input)
            if index == 1 {
                preview(value); firstBatch.signal()
                try wait(releaseFirst, "recognizer releases first batch")
            }
            return value
        }, preview: { value, _ in lock.lock(); incrementalPreviews.append(value); lock.unlock() })
        try check(batches == [["first"], ["added"]], "cumulative OCR translates additions once and skips an obsolete queued region")
        try check(incremental.0.dialogues.map(\.location) == ["added", "first"], "incremental translation follows final reading order")
        try check(incremental.0.skippedCount == 2 && incremental.0.untranslatedCount == 0, "batch accounting preserves only final OCR omissions")
        try check(incrementalPreviews.first?.dialogues.map(\.location) == ["first"], "first reliable bubble appears before OCR supplements it")

        let correctionStarted = DispatchSemaphore(value: 0), releaseCorrection = DispatchSemaphore(value: 0)
        let corrected = block("first", "訂正"), newest = block("first", "最終訂正")
        var correctionBatches: [[String]] = [], correctionPreviews: [PageTranslation] = []
        var correctionBoundary = 0
        let correction = try TranslationPipeline.run(runner: CommandRunner(), recognize: { ready in
            ready(page([initial]))
            try wait(correctionStarted, "old text streams before OCR correction")
            lock.lock(); correctionBoundary = correctionPreviews.count; lock.unlock()
            ready(page([corrected]))
            ready(page([newest, added]))
            releaseCorrection.signal()
            return page([newest, added])
        }, translate: { input, preview in
            lock.lock(); correctionBatches.append(input.blocks.map(\.text)); let index = correctionBatches.count; lock.unlock()
            let value = translated(input)
            if index == 1 {
                preview(value); correctionStarted.signal()
                try wait(releaseCorrection, "correction releases old request")
                preview(value)
            }
            return value
        }, preview: { value, _ in lock.lock(); correctionPreviews.append(value); lock.unlock() })
        try check(correctionBatches == [["早い"], ["最終訂正", "後から"]], "a source revision translates once while superseded queued OCR is discarded")
        try check(correctionPreviews.dropFirst(correctionBoundary).first?.dialogues.isEmpty == true,
                  "changed OCR retracts the old overlay before replacement text returns")
        try check(correctionPreviews.dropFirst(correctionBoundary).allSatisfy { !$0.dialogues.contains { $0.original == initial.text } },
                  "late preview and final callbacks cannot restore superseded source text")
        try check(correction.0.dialogues.map(\.original) == [newest.text, added.text], "final contains only current source revisions")

        let uncertainStarted = DispatchSemaphore(value: 0), releaseUncertain = DispatchSemaphore(value: 0)
        var uncertain = initial; uncertain.uncertainFragments = [initial.text]
        var uncertaintyCalls = 0
        let uncertainResult = try TranslationPipeline.run(runner: CommandRunner(), recognize: { ready in
            ready(page([initial])); try wait(uncertainStarted, "initial certainty begins")
            ready(page([uncertain])); releaseUncertain.signal(); return page([uncertain])
        }, translate: { input, _ in
            uncertaintyCalls += 1
            if uncertaintyCalls == 1 { uncertainStarted.signal(); try wait(releaseUncertain, "uncertainty releases request") }
            return PageTranslation(summary: "", dialogues: input.blocks.map {
                Dialogue.recognized($0, text: $0.uncertainFragments == nil ? "确定译文" : "□")
            }, notes: "")
        }, preview: { _, _ in })
        try check(uncertaintyCalls == 2 && uncertainResult.0.dialogues.first?.preserveOriginal == true,
                  "changed confidence cannot inherit an apparently certain translation")

        let removalReady = DispatchSemaphore(value: 0)
        var removalPreviews: [PageTranslation] = [], removalCalls = 0
        let removal = try TranslationPipeline.run(runner: CommandRunner(), recognize: { ready in
            ready(page([initial])); try wait(removalReady, "early translation precedes removal")
            return page([], skipped: 1)
        }, translate: { input, preview in
            removalCalls += 1; let value = translated(input); preview(value); removalReady.signal(); return value
        }, preview: { value, _ in lock.lock(); removalPreviews.append(value); lock.unlock() })
        try check(removalCalls == 1 && removal.0.dialogues.isEmpty && removal.0.ocrSkippedCount == 1,
                  "an empty final OCR page discards early false detections without another request")
        try check(removalPreviews.last?.dialogues.isEmpty == true, "a removed final bubble clears its early overlay")

        var incompleteCalls = 0, incompletePreviews: [PageTranslation] = []
        let incomplete = try TranslationPipeline.run(runner: CommandRunner(), recognize: { _ in page([initial, added]) }, translate: { input, preview in
            incompleteCalls += 1; preview(translated(input))
            return translated(page([initial]))
        }, preview: { value, _ in incompletePreviews.append(value) })
        try check(incompleteCalls == 1 && incomplete.0.untranslatedCount == 1, "an incomplete provider final does not start an unbounded retry loop")
        try check(incompletePreviews.last?.dialogues.map(\.location) == [initial.id], "streaming text absent from provider final is withdrawn")

        let cancelIncremental = CommandRunner(), cancelStarted = DispatchSemaphore(value: 0), cancelRelease = DispatchSemaphore(value: 0)
        var cancelCalls = 0, latePreviews = 0
        do {
            _ = try TranslationPipeline.run(runner: cancelIncremental, recognize: { ready in
                ready(page([initial])); try wait(cancelStarted, "cancel test begins first batch")
                ready(page([initial, added])); cancelIncremental.cancel(); cancelRelease.signal()
                return page([initial, added])
            }, translate: { input, preview in
                cancelCalls += 1; cancelStarted.signal(); try wait(cancelRelease, "cancel releases network")
                preview(translated(input)); return translated(input)
            }, preview: { _, _ in latePreviews += 1 })
            throw AppError.message("FAIL: incremental cancellation succeeded")
        } catch is CancellationError {
            try check(cancelCalls == 1 && latePreviews == 0, "cancellation stops both late previews and queued supplement requests")
        }
        var duplicateCalls = 0
        do {
            _ = try TranslationPipeline.run(runner: CommandRunner(), recognize: { _ in page([initial, initial]) }, translate: { input, _ in
                duplicateCalls += 1; return translated(input)
            }, preview: { _, _ in })
            throw AppError.message("FAIL: duplicate OCR ids succeeded")
        } catch let error as AppError {
            try check(duplicateCalls == 0 && error.localizedDescription.contains("重复气泡"), "duplicate final IDs fail before a network request")
        }
        var manual = Dialogue.recognized(block("first", "人工确认的原文"), text: "人工译文□")
        manual.userEdited = true
        var restored = Dialogue.recognized(added, text: "旧译文")
        restored.preserveOriginal = true; restored.userRestoredOriginal = true
        var absent = Dialogue.recognized(block("absent", "不在本页"), text: "不会注入")
        absent.userEdited = true
        var rawManual = initial; rawManual.uncertainFragments = [initial.text]
        var rawRestored = added; rawRestored.replacementPNG = nil; rawRestored.replacementAllowed = false
        let rawContext = page([rawManual, rawRestored, removed], skipped: 2)
        let fixedContext = TranslationPipeline.applyingCorrections(rawContext, corrections: [manual, restored, absent])
        try check(fixedContext.blocks.map(\.text) == [manual.original, restored.original, removed.text]
                  && fixedContext.blocks[0].uncertainFragments == nil && fixedContext.skippedCount == 2,
                  "manual source replaces OCR uncertainty in page context without adding absent IDs")
        let shifted = DialogueBounds(x: 200, y: 300, width: 150, height: 180)
        let finalManual = OCRBlock(id: initial.id, text: "Vision后来给出的原文", bounds: shifted,
                                  replacementPNG: validPatch, replacementAllowed: true,
                                  uncertainFragments: ["原文"])
        let firstAutomatic = block("automatic-first", "自動一"), secondAutomatic = block("automatic-second", "自動二")
        let manualStarted = DispatchSemaphore(value: 0), manualRelease = DispatchSemaphore(value: 0)
        var manualBatches: [[String]] = [], manualPreviews: [PageTranslation] = []
        let manualResult = try TranslationPipeline.run(runner: CommandRunner(), corrections: [manual, restored, absent], recognize: { ready in
            ready(page([rawManual, rawRestored, firstAutomatic]))
            try wait(manualStarted, "automatic supplement begins alongside manual bubbles")
            ready(page([finalManual, rawRestored, firstAutomatic, secondAutomatic]))
            manualRelease.signal()
            return page([finalManual, rawRestored, firstAutomatic, secondAutomatic])
        }, translate: { input, preview in
            lock.lock(); manualBatches.append(input.blocks.map(\.id)); let index = manualBatches.count; lock.unlock()
            if index == 1 {
                manualStarted.signal(); try wait(manualRelease, "manual review releases supplement")
            }
            let result = translated(input); preview(result); return result
        }, preview: { value, _ in lock.lock(); manualPreviews.append(value); lock.unlock() })
        try check(manualBatches == [[firstAutomatic.id], [secondAutomatic.id]],
                  "concurrent partial-page supplements never resend manually edited or restored bubbles")
        let reboundManual = manualResult.0.dialogues.first { $0.location == initial.id }
        try check(reboundManual?.original == manual.original && reboundManual?.translation == manual.translation
                  && reboundManual?.userEdited == true && reboundManual?.uncertainRanges == manual.uncertainRanges,
                  "later OCR and translation keep manual source, translation, flags and uncertainty ranges")
        try check(reboundManual?.bounds?.x == shifted.x && reboundManual?.bounds?.height == shifted.height
                  && reboundManual?.replacementPNG == finalManual.replacementPNG,
                  "manual text binds newly recognized positions and repaired pixels")
        try check(manualPreviews.first?.dialogues.first(where: { $0.location == added.id })?.userRestoredOriginal == true
                  && manualResult.0.dialogues.first(where: { $0.location == added.id })?.preserveOriginal == true,
                  "restore-original survives early snapshots even before a replacement patch exists")
        try check(manualResult.0.dialogues.count == 4 && manualResult.0.untranslatedCount == 0
                  && !manualResult.0.dialogues.contains(where: { $0.location == absent.location }),
                  "supplements complete the page without injecting corrections for absent regions")
        var manualOnlyRequests = 0
        let manualOnly = try TranslationPipeline.run(runner: CommandRunner(), corrections: [manual], recognize: { _ in page([initial]) }, translate: { input, _ in
            manualOnlyRequests += 1; return translated(input)
        }, preview: { _, _ in })
        try check(manualOnlyRequests == 0 && manualOnly.0.dialogues.first?.userEdited == true,
                  "a page containing only manual corrections makes no network request")
        let repairStarted = DispatchSemaphore(value: 0), releaseRepair = DispatchSemaphore(value: 0)
        var unreadyManual = rawManual; unreadyManual.replacementPNG = nil; unreadyManual.replacementAllowed = false
        var repairPreviews: [PageTranslation] = []
        let repairedManual = try TranslationPipeline.run(runner: CommandRunner(), corrections: [manual], recognize: { ready in
            ready(page([unreadyManual, firstAutomatic]))
            try wait(repairStarted, "manual text waits for safe local repairs")
            lock.lock(); let earlyManual = repairPreviews.first?.dialogues.first { $0.location == initial.id }; lock.unlock()
            try check(earlyManual?.userEdited == true && earlyManual?.translation == manual.translation
                      && earlyManual?.replacementAllowed == false,
                      "unrepaired manual text remains in partial cache without erasing original artwork")
            releaseRepair.signal(); return page([finalManual, firstAutomatic])
        }, translate: { input, _ in
            repairStarted.signal(); try wait(releaseRepair, "local repairs release supplement"); return translated(input)
        }, preview: { value, _ in lock.lock(); repairPreviews.append(value); lock.unlock() })
        try check(repairedManual.0.dialogues.first?.replacementAllowed == true
                  && repairedManual.0.dialogues.first?.userEdited == true,
                  "finished repairs restore manual rendering without losing edit metadata")
        let emptyManual = try TranslationPipeline.run(runner: CommandRunner(), corrections: [manual], recognize: { ready in
            ready(page([initial])); return page([])
        }, translate: { _, _ in throw AppError.message("Manual region must not translate") }, preview: { _, _ in })
        try check(emptyManual.0.dialogues.isEmpty, "a correction is removed when final OCR withdraws its region")
        var cleanRequests = 0
        let clean = try TranslationPipeline.run(runner: CommandRunner(), recognize: { _ in page([initial]) }, translate: { input, _ in
            cleanRequests += 1; return translated(input)
        }, preview: { _, _ in })
        try check(cleanRequests == 1 && clean.0.dialogues.first?.userEdited != true
                  && clean.0.dialogues.first?.original == initial.text,
                  "an explicit new run without page corrections does not inherit manual edits")
        func scope(_ raw: String) -> ReadingScope { ReadingScope(windowID: 5, documentURL: URL(string: raw)!) }
        try check(scope("https://shonenjumpplus.com/episode/42?page=1#viewer") == scope("https://shonenjumpplus.com/episode/42?page=8"), "known episode pagination stays in scope")
        try check(scope("https://shonenjumpplus.com/episode/42") != scope("https://shonenjumpplus.com/episode/43"), "other episode pauses automatic reading")
        try check(scope("https://e-hentai.org/s/abc/123-1") == scope("https://e-hentai.org/s/xyz/123-20"), "gallery image keys do not break pagination")
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
