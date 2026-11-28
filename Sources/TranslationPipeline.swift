import Foundation
import ImageIO

// Recognition publishes the whole page of text once. Translation can then
// stream while the worker finishes repairing the backgrounds.
enum TranslationPipeline {
    typealias Translate = (OCRPage, OCRPage, @escaping (PageTranslation) -> Void) throws -> PageTranslation

    static func run(runner: CommandRunner, began: Date = Date(), corrections: [Dialogue] = [],
                    renderPatches: Bool = true,
                    recognize: (@escaping (OCRPage) -> Void) throws -> OCRPage,
                    translate: @escaping Translate,
                    preview: @escaping (PageTranslation, PageTimings, OCRReview) -> Void)
        throws -> (translation: PageTranslation, timings: PageTimings, recognition: OCRPage) {
        let state = PageTranslationJob(began: began, runner: runner, corrections: corrections,
                                       renderPatches: renderPatches, preview: preview)
        let finished = DispatchGroup()
        func accept(_ page: OCRPage, final: Bool) {
            guard let work = state.accept(page, final: final) else { return }
            finished.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { finished.leave() }
                let result = Result {
                    try runner.checkCancellation()
                    return try translate(work.request, work.page, state.update)
                }
                if state.finish(result) { runner.cancel() }
            }
        }
        do {
            let final = try recognize { accept($0, final: false) }
            try runner.checkCancellation()
            accept(final, final: true)
            if let failure = state.failure { throw failure }
            while finished.wait(timeout: .now() + 0.05) != .success {
                try runner.checkCancellation()
            }
            try runner.checkCancellation()
            return try state.result()
        } catch {
            runner.cancel()
            _ = finished.wait(timeout: .now() + 5)
            throw state.failure ?? error
        }
    }

    // Corrections belong to the caller's exact page. They may replace an
    // OCR source string, but never supply stale positions or introduce regions
    // the current recognition snapshot no longer contains.
    static func applyingCorrections(_ ocr: OCRPage, corrections: [Dialogue]) -> OCRPage {
        guard !corrections.isEmpty else { return ocr }
        let blocks = ocr.blocks.map { block -> OCRBlock in
            guard let value = correction(for: block, in: corrections) else { return block }
            return OCRBlock(id: block.id, text: value.original, bounds: block.bounds,
                replacementPNG: block.replacementPNG, replacementAllowed: block.replacementAllowed,
                textStyle: block.textStyle, layoutBounds: block.layoutBounds, layoutRegions: block.layoutRegions,
                vertical: block.vertical, fontSize: block.fontSize, uncertainFragments: nil)
        }
        var adjusted = ocr
        adjusted.blocks = blocks
        return adjusted
    }

    static func correction(for block: OCRBlock, in corrections: [Dialogue]) -> Dialogue? {
        func overlap(_ value: Dialogue) -> Double {
            guard let a = block.bounds.rect(in: CGSize(width: 1000, height: 1000)),
                  let b = value.bounds?.rect(in: CGSize(width: 1000, height: 1000)) else { return 0 }
            let shared = a.intersection(b)
            if shared.isNull { return 0 }
            return shared.width*shared.height / (a.width*a.height + b.width*b.height-shared.width*shared.height)
        }
        if let exact = corrections.last(where: {
            $0.location == block.id && ($0.correctionEngine == nil || $0.correctionEngine == LocalOCR.engineVersion || overlap($0) > 0.5)
        }) { return exact }
        let nearby = corrections.filter {
            overlap($0) > 0.85 && ($0.original == block.text || ($0.correctionEngine != nil && $0.correctionEngine != LocalOCR.engineVersion))
        }
        if let textMatch = nearby.last(where: { $0.original == block.text }) { return textMatch }
        return nearby.count == 1 ? nearby[0] : nil
    }

    fileprivate static func bindCorrection(_ value: Dialogue, to block: OCRBlock) -> Dialogue {
        var rebound = Dialogue.recognized(block, text: value.translation)
        rebound.preserveOriginal = value.preserveOriginal
        rebound.uncertainRanges = value.uncertainRanges
        rebound.userEdited = value.userEdited
        rebound.userRestoredOriginal = value.userRestoredOriginal
        rebound.correctionEngine = value.correctionEngine
        return rebound
    }

    static func bind(_ translated: PageTranslation, to ocr: OCRPage, allowedIDs: Set<String>? = nil) -> PageTranslation {
        let mapped = Dictionary(translated.dialogues.map { ($0.location, $0) }, uniquingKeysWith: { first, _ in first })
        let dialogues = ocr.blocks.compactMap { block -> Dialogue? in
            guard let text = mapped[block.id], text.original == block.text else { return nil }
            if let allowedIDs, !allowedIDs.contains(block.id) { return nil }
            if text.userEdited == true || text.userRestoredOriginal == true { return bindCorrection(text, to: block) }
            return Dialogue.recognized(block, text: text.translation)
        }
        return PageTranslation(summary: translated.summary, dialogues: dialogues, notes: translated.notes,
                               skippedCount: ocr.skippedCount + ocr.blocks.count - dialogues.count,
                               ocrSkippedCount: ocr.skippedCount)
    }

    static func earlyPatchIsReady(_ block: OCRBlock) -> Bool {
        // Never invoke the renderer's legacy white-cover fallback on a draft.
        // Decode once at handoff, so damaged/missing PNG bytes cannot accidentally
        // turn a replacementAllowed flag into permission to erase the artwork.
        guard block.replacementAllowed == true, block.textStyle == nil,
              let data = block.replacementPNG,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.png",
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { return false }
        return true
    }
}

private final class PageTranslationJob: @unchecked Sendable {
    private let lock = NSLock()
    private let began: Date
    private let runner: CommandRunner
    private let corrections: [Dialogue]
    private let renderPatches: Bool
    private let preview: (PageTranslation, PageTimings, OCRReview) -> Void

    private var geometry: OCRPage?
    private var final = false
    private var readyPatches: Set<String>?
    private var translated: PageTranslation?
    private var error: Error?
    private var ocrTime = 0.0
    private var translationBegan: Date?
    private var translationEnded: Date?
    private var firstResult: Double?
    private var lastVisible: [String] = []
    private var hasPublished = false

    init(began: Date, runner: CommandRunner, corrections: [Dialogue], renderPatches: Bool,
         preview: @escaping (PageTranslation, PageTimings, OCRReview) -> Void) {
        self.began = began; self.runner = runner; self.corrections = corrections
        self.renderPatches = renderPatches; self.preview = preview
    }

    func accept(_ input: OCRPage, final: Bool) -> (request: OCRPage, page: OCRPage)? {
        let page = TranslationPipeline.applyingCorrections(input, corrections: corrections)
        let ready = final || !renderPatches ? nil : Set(page.blocks.filter(TranslationPipeline.earlyPatchIsReady).map(\.id))
        return lock.withLock {
            guard error == nil, !runner.isCancelled, !self.final else { return nil }
            let previous = geometry
            guard Set(page.blocks.map(\.id)).count == page.blocks.count else {
                error = AppError.message("识字结果包含重复气泡，请重新识别。")
                return nil
            }
            // Patch completion must never introduce another OCR revision.
            if let previous, !previous.hasSameText(as: page) {
                error = AppError.message("识字与叠层内容不一致，请重新识别。")
                return nil
            }
            geometry = page
            self.final = final
            readyPatches = ready
            ocrTime = Date().timeIntervalSince(began)
            publish(geometryChanged: true)
            guard previous == nil else { return nil }
            let requested = page.blocks.filter { TranslationPipeline.correction(for: $0, in: corrections) == nil }
            guard !requested.isEmpty else { return nil }
            translationBegan = Date()
            return (OCRPage(blocks: requested, skippedCount: 0, elapsed: page.elapsed, review: page.review), page)
        }
    }

    private func timing() -> PageTimings {
        let translationTime = translationBegan.map { (translationEnded ?? Date()).timeIntervalSince($0) } ?? 0
        return PageTimings(ocr: ocrTime, codex: translationTime, firstResult: firstResult,
                           translationBatches: translationBegan == nil ? 0 : 1,
                           ocrStages: geometry?.stages, ocrRegions: geometry?.regions)
    }

    private func resultPage(_ page: OCRPage, visibleOnly: Bool) -> PageTranslation {
        let byID = Dictionary((translated?.dialogues ?? []).map { ($0.location, $0) },
                              uniquingKeysWith: { first, _ in first })
        let dialogues = page.blocks.compactMap { block -> Dialogue? in
            let ready = !visibleOnly || (readyPatches?.contains(block.id) ?? true)
            if let manual = TranslationPipeline.correction(for: block, in: corrections) {
                var rebound = TranslationPipeline.bindCorrection(manual, to: block)
                if !ready { rebound.replacementAllowed = false }
                return rebound
            }
            guard ready, let value = byID[block.id], value.original == block.text else { return nil }
            return Dialogue.recognized(block, text: value.translation)
        }
        return PageTranslation(summary: translated?.summary ?? "", dialogues: dialogues,
            notes: translated?.notes ?? "", skippedCount: page.skippedCount + page.blocks.count - dialogues.count,
            ocrSkippedCount: page.skippedCount)
    }

    private func publish(geometryChanged: Bool = false) {
        guard !runner.isCancelled, let geometry else { return }
        let page = resultPage(geometry, visibleOnly: true)
        guard hasPublished || !page.dialogues.isEmpty else { return }
        let words = page.dialogues.flatMap { [$0.location, $0.translation] }
        guard geometryChanged || words != lastVisible else { return }
        hasPublished = true; lastVisible = words
        if firstResult == nil, page.dialogues.contains(where: {
            $0.preserveOriginal != true && (!renderPatches || $0.replacementAllowed != false)
        }) {
            firstResult = Date().timeIntervalSince(began)
        }
        preview(page, timing(), geometry.review)
    }

    func update(_ translation: PageTranslation) {
        lock.withLock {
            guard error == nil, !runner.isCancelled else { return }
            translated = translation
            publish()
        }
    }

    func finish(_ result: Result<PageTranslation, Error>) -> Bool {
        lock.withLock {
            translationEnded = Date()
            switch result {
            case .success(let translation):
                translated = translation
                publish()
                return false
            case .failure(let failure):
                if error == nil, !(failure is CancellationError) { error = failure }
                return true
            }
        }
    }

    func result() throws -> (PageTranslation, PageTimings, OCRPage) {
        try lock.withLock {
            if let error { throw error }
            guard final, let geometry else { throw AppError.message("识字结果不完整。") }
            return (resultPage(geometry, visibleOnly: false), timing(), geometry)
        }
    }

    var failure: Error? { lock.withLock { error } }
}
