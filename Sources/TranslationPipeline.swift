import Foundation
import ImageIO

// OCR publishes cumulative pages: reliable balloons can arrive before Vision,
// and later snapshots may add, correct or remove regions. Translate only new
// source revisions, then bind every preview to the latest local geometry.
enum TranslationPipeline {
    typealias Translate = (OCRPage, @escaping (PageTranslation) -> Void) throws -> PageTranslation
    enum Scheduling { case progressive, verified, verifiedWithPreview }

    static func run(runner: CommandRunner, began: Date = Date(), corrections: [Dialogue] = [],
                    scheduling: Scheduling = .progressive, renderPatches: Bool = true,
                    recognize: (@escaping (OCRPage) -> Void) throws -> OCRPage,
                    translate: @escaping Translate,
                    preview: @escaping (PageTranslation, PageTimings) -> Void) throws -> (PageTranslation, PageTimings) {
        let state = PipelineState(began: began, runner: runner, corrections: corrections,
                                  scheduling: scheduling, renderPatches: renderPatches, preview: preview)
        let finished = DispatchGroup()
        // The preview may overlap the verified request on a separate Codex
        // session. Google and small pages retain a single request at a time.
        for _ in 0..<(scheduling == .verifiedWithPreview ? 2 : 1) {
            finished.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { finished.leave() }
                while let batch = state.nextBatch() {
                    let result = Result {
                        try runner.checkCancellation()
                        return try translate(batch.page) { state.update($0, for: batch) }
                    }
                    if state.finish(result, for: batch) { runner.cancel(); return }
                }
            }
        }
        do {
            let final = try recognize { state.accept($0, final: false) }
            try runner.checkCancellation()
            state.accept(final, final: true)
        } catch {
            runner.cancel()
            state.wake()
            _ = finished.wait(timeout: .now() + 5)
            throw state.failure ?? error
        }
        while finished.wait(timeout: .now() + 0.05) != .success {
            if runner.isCancelled { throw state.failure ?? CancellationError() }
        }
        if runner.isCancelled { throw state.failure ?? CancellationError() }
        return try state.result()
    }

    // Corrections belong to the caller's exact page cache. They may replace an
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
        return OCRPage(blocks: blocks, skippedCount: ocr.skippedCount, elapsed: ocr.elapsed,
                       verifiedText: ocr.verifiedText, textOnly: ocr.textOnly, previewBatch: ocr.previewBatch, stages: ocr.stages)
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

private struct SourceRevision: Hashable {
    let id: String
    let text: String
    let uncertainFragments: [String]
    let kind: String?

    init(_ block: OCRBlock) {
        id = block.id; text = block.text
        // Geometry and repaired pixels do not change a translation. Confidence
        // annotations do: a newly uncertain fragment must not inherit an earlier
        // apparently certain translation, even when its OCR string is unchanged.
        uncertainFragments = Array(Set(block.uncertainFragments ?? [])).sorted()
        kind = block.translationKind
    }
}

private struct TranslationBatch {
    let id: Int
    let page: OCRPage
}

private final class PipelineState: @unchecked Sendable {
    private let condition = NSCondition()
    private let began: Date
    private let runner: CommandRunner
    private let preview: (PageTranslation, PageTimings) -> Void
    private let corrections: [String: Dialogue]
    private let scheduling: TranslationPipeline.Scheduling
    private let renderPatches: Bool
    private var geometry: OCRPage?
    private var isFinal = false
    private var attempted: Set<SourceRevision> = []
    private var completed: [SourceRevision: Dialogue] = [:]
    private var streaming: [Int: [SourceRevision: Dialogue]] = [:]
    private var error: Error?
    private var ocrTime = 0.0
    private var translationTime = 0.0
    private var translationBatches = 0
    private var activeSince: Date?
    private var firstResult: Double?
    private var earlyIDs: Set<String>?
    private var summary = ""
    private var notes: [String] = []
    private var geometryRevision = 0
    private var lastPublication: String?
    private var hasPublished = false

    init(began: Date, runner: CommandRunner, corrections: [Dialogue],
         scheduling: TranslationPipeline.Scheduling, renderPatches: Bool,
         preview: @escaping (PageTranslation, PageTimings) -> Void) {
        self.began = began; self.runner = runner; self.preview = preview
        self.corrections = Dictionary(corrections.map { ($0.location, $0) }, uniquingKeysWith: { _, latest in latest })
        self.scheduling = scheduling; self.renderPatches = renderPatches
    }

    private var timings: PageTimings {
        let activeTime = activeSince.map { Date().timeIntervalSince($0) } ?? 0
        return PageTimings(ocr: ocrTime, codex: translationTime + activeTime, firstResult: firstResult,
                    translationBatches: translationBatches, ocrStages: geometry?.stages)
    }

    private func page(allowEarlyOnly: Bool) -> PageTranslation? {
        guard let geometry else { return nil }
        let dialogues = geometry.blocks.compactMap { block -> Dialogue? in
            let manual = TranslationPipeline.correction(for: block, in: Array(corrections.values))
            let ready = !allowEarlyOnly || (earlyIDs?.contains(block.id) ?? true)
            if let manual {
                var rebound = TranslationPipeline.bindCorrection(manual, to: block)
                // Retain manual work in partial caches even before local repairs
                // finish. It cannot erase artwork until the current patch is
                // ready; restoring the original needs no patch at all.
                if !ready, rebound.preserveOriginal != true { rebound.replacementAllowed = false }
                return rebound
            }
            guard ready else { return nil }
            let key = SourceRevision(block)
            let pending = streaming.values.lazy.compactMap { $0[key] }.first
            guard let value = pending ?? completed[key] else { return nil }
            return Dialogue.recognized(block, text: value.translation)
        }
        return PageTranslation(summary: summary, dialogues: dialogues,
            notes: geometry.blocks.isEmpty ? "未识别到日文" : notes.joined(separator: "\n"),
            skippedCount: geometry.skippedCount + geometry.blocks.count - dialogues.count,
            ocrSkippedCount: geometry.skippedCount)
    }

    private func publish() {
        guard !runner.isCancelled, let value = page(allowEarlyOnly: true) else { return }
        // An empty update retracts a previously visible OCR revision. Otherwise
        // corrected/removed balloons would stay on screen until a new answer.
        guard hasPublished || !value.dialogues.isEmpty else { return }
        let signature = "\(geometryRevision)|" + value.dialogues.map {
            "\($0.location.utf8.count):\($0.location)\($0.translation.utf8.count):\($0.translation)"
        }.joined()
        guard signature != lastPublication else { return }
        lastPublication = signature; hasPublished = true
        if firstResult == nil, value.dialogues.contains(where: {
            $0.preserveOriginal != true && (!renderPatches || $0.replacementAllowed != false)
        }) {
            firstResult = Date().timeIntervalSince(began)
        }
        // Serialization also prevents an old network callback overtaking a newer
        // OCR snapshot. The caller enqueues this lightweight value to AppKit.
        preview(value, timings)
    }

    func accept(_ incoming: OCRPage, final: Bool) {
        let value = TranslationPipeline.applyingCorrections(incoming, corrections: Array(corrections.values))
        let ready = final || !renderPatches ? nil : Set(value.blocks.filter(TranslationPipeline.earlyPatchIsReady).map(\.id))
        condition.lock()
        guard !runner.isCancelled, !isFinal else { condition.unlock(); return }
        guard Set(value.blocks.map(\.id)).count == value.blocks.count else {
            error = AppError.message("识字结果包含重复气泡，请重新识别。")
            condition.broadcast(); condition.unlock(); runner.cancel(); return
        }
        geometry = value; earlyIDs = ready; isFinal = final
        geometryRevision += 1; ocrTime = Date().timeIntervalSince(began)
        publish(); condition.broadcast(); condition.unlock()
    }

    func nextBatch() -> TranslationBatch? {
        condition.lock(); defer { condition.unlock() }
        while !runner.isCancelled, error == nil {
            if let geometry {
                let verified = isFinal || geometry.verifiedText == true
                let preview = scheduling == .verifiedWithPreview && !verified
                    && translationBatches == 0 && geometry.previewBatch == true
                let mayTranslate = verified || scheduling == .progressive || preview
                if mayTranslate {
                    let blocks = geometry.blocks.filter {
                        TranslationPipeline.correction(for: $0, in: Array(corrections.values)) == nil
                            && !attempted.contains(SourceRevision($0))
                    }
                    if !blocks.isEmpty {
                        attempted.formUnion(blocks.map(SourceRevision.init))
                        translationBatches += 1
                        let batch = TranslationBatch(id: translationBatches,
                            page: OCRPage(blocks: blocks, skippedCount: 0, elapsed: geometry.elapsed,
                                          verifiedText: verified, previewBatch: preview))
                        streaming[batch.id] = [:]
                        if activeSince == nil { activeSince = Date() }
                        return batch
                    }
                }
            }
            if isFinal { return nil }
            _ = condition.wait(until: Date().addingTimeInterval(0.05))
        }
        return nil
    }

    private func mapped(_ value: PageTranslation, for batch: OCRPage) -> [SourceRevision: Dialogue] {
        let byID = Dictionary(value.dialogues.map { ($0.location, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [SourceRevision: Dialogue] = [:]
        for block in batch.blocks {
            guard let dialogue = byID[block.id], dialogue.original == block.text else { continue }
            result[SourceRevision(block)] = dialogue
        }
        return result
    }

    func update(_ value: PageTranslation, for batch: TranslationBatch) {
        condition.lock(); defer { condition.unlock() }
        guard !runner.isCancelled else { return }
        // Preview callbacks are cumulative within this translation batch. Replace
        // them, rather than accidentally retaining entries a provider withdrew.
        streaming[batch.id] = mapped(value, for: batch.page)
        publish()
    }

    func finish(_ value: Result<PageTranslation, Error>, for batch: TranslationBatch) -> Bool {
        condition.lock(); defer { condition.unlock() }
        streaming.removeValue(forKey: batch.id)
        if streaming.isEmpty, let since = activeSince {
            translationTime += Date().timeIntervalSince(since); activeSince = nil
        }
        switch value {
        case .success(let translation):
            let values = mapped(translation, for: batch.page)
            for (key, dialogue) in values { completed[key] = dialogue }
            if batch.page.previewBatch == true {
                attempted.subtract(batch.page.blocks.map(SourceRevision.init).filter { values[$0] == nil })
            }
            if !translation.summary.isEmpty { summary = translation.summary }
            if !translation.notes.isEmpty, !notes.contains(translation.notes) { notes.append(translation.notes) }
            publish()
        case .failure(let failure):
            if batch.page.previewBatch == true, (failure as? AppError)?.needsUserAction != true {
                // A missed preview is eligible for translation from verified text.
                attempted.subtract(batch.page.blocks.map(SourceRevision.init))
            } else if error == nil || error is CancellationError { error = failure }
        }
        condition.broadcast()
        return error != nil
    }

    func result() throws -> (PageTranslation, PageTimings) {
        condition.lock(); defer { condition.unlock() }
        if let error { throw error }
        guard isFinal, let value = page(allowEarlyOnly: false) else { throw AppError.message("翻译任务未完成。") }
        return (value, timings)
    }

    func wake() { condition.lock(); condition.broadcast(); condition.unlock() }

    var failure: Error? {
        condition.lock(); defer { condition.unlock() }
        guard let error, !(error is CancellationError) else { return nil }
        return error
    }
}
