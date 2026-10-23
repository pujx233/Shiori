import Foundation
import ImageIO

// Text can leave the OCR worker while its local background repairs are still
// running. A completed closed-balloon patch may render early, while every other
// block waits for final repairs. Persistent page caches still receive only finals.
enum TranslationPipeline {
    typealias Translate = (OCRPage, @escaping (PageTranslation) -> Void) throws -> PageTranslation

    static func run(runner: CommandRunner, began: Date = Date(),
                    recognize: (@escaping (OCRPage) -> Void) throws -> OCRPage,
                    translate: @escaping Translate,
                    preview: @escaping (PageTranslation, PageTimings) -> Void) throws -> (PageTranslation, PageTimings) {
        let state = PipelineState(began: began, runner: runner, preview: preview)
        let finished = DispatchSemaphore(value: 0)
        var started = false
        func start(_ draft: OCRPage) {
            guard !started, !draft.blocks.isEmpty, !runner.isCancelled else { return }
            started = true
            state.setDraft(draft, elapsed: Date().timeIntervalSince(began))
            DispatchQueue.global(qos: .userInitiated).async {
                let translationStart = Date()
                let result = Result {
                    try runner.checkCancellation()
                    return try translate(draft) { state.update($0, elapsed: Date().timeIntervalSince(translationStart)) }
                }
                state.finish(result, elapsed: Date().timeIntervalSince(translationStart))
                if case .failure = result { runner.cancel() }
                finished.signal()
            }
        }
        let final: OCRPage
        do {
            final = try recognize(start)
            try runner.checkCancellation()
        } catch {
            runner.cancel()
            if started { _ = finished.wait(timeout: .now() + 5) }
            throw state.failure ?? error
        }
        let ocrTime = Date().timeIntervalSince(began)
        guard !final.blocks.isEmpty else {
            return (PageTranslation(summary: "", dialogues: [], notes: "未识别到日文",
                                    skippedCount: final.skippedCount, ocrSkippedCount: final.skippedCount),
                    PageTimings(ocr: ocrTime, codex: 0, firstResult: nil))
        }
        start(final)
        state.setGeometry(final, elapsed: ocrTime)
        while finished.wait(timeout: .now() + 0.05) != .success {
            if runner.isCancelled { throw state.failure ?? CancellationError() }
        }
        if runner.isCancelled { throw state.failure ?? CancellationError() }
        return try state.result()
    }

    static func bind(_ translated: PageTranslation, to ocr: OCRPage, allowedIDs: Set<String>? = nil) -> PageTranslation {
        let mapped = Dictionary(translated.dialogues.map { ($0.location, $0) }, uniquingKeysWith: { first, _ in first })
        let dialogues = ocr.blocks.compactMap { block -> Dialogue? in
            guard let text = mapped[block.id], text.original == block.text else { return nil }
            if let allowedIDs, !allowedIDs.contains(block.id) { return nil }
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

private final class PipelineState: @unchecked Sendable {
    private let lock = NSLock()
    private let began: Date
    private let runner: CommandRunner
    private let preview: (PageTranslation, PageTimings) -> Void
    private var geometry: OCRPage?
    private var partial: PageTranslation?
    private var outcome: Result<PageTranslation, Error>?
    private var ocrTime = 0.0
    private var translationTime = 0.0
    private var firstResult: Double?
    private var earlyIDs: Set<String>?
    init(began: Date, runner: CommandRunner, preview: @escaping (PageTranslation, PageTimings) -> Void) {
        self.began = began; self.runner = runner; self.preview = preview
    }
    private var timings: PageTimings { PageTimings(ocr: ocrTime, codex: translationTime, firstResult: firstResult) }
    private func publish() {
        guard !runner.isCancelled, let geometry, let partial else { return }
        let bound = TranslationPipeline.bind(partial, to: geometry, allowedIDs: earlyIDs)
        guard !bound.dialogues.isEmpty else { return }
        if firstResult == nil { firstResult = Date().timeIntervalSince(began) }
        // Callbacks are serialized, even when repair completion races a network
        // preview. AppController dispatches the lightweight result to AppKit.
        preview(bound, timings)
    }
    func setDraft(_ page: OCRPage, elapsed: Double) {
        let ready = Set(page.blocks.filter(TranslationPipeline.earlyPatchIsReady).map(\.id))
        lock.lock(); defer { lock.unlock() }
        geometry = page; earlyIDs = ready; ocrTime = elapsed; publish()
    }
    func update(_ value: PageTranslation, elapsed: Double) {
        lock.lock(); defer { lock.unlock() }
        partial = value; translationTime = elapsed; publish()
    }
    func setGeometry(_ page: OCRPage, elapsed: Double) {
        lock.lock(); defer { lock.unlock() }
        geometry = page; earlyIDs = nil; ocrTime = elapsed; publish()
    }
    func finish(_ value: Result<PageTranslation, Error>, elapsed: Double) {
        lock.lock(); defer { lock.unlock() }
        outcome = value; translationTime = elapsed
        if case .success(let translation) = value { partial = translation; publish() }
    }
    func result() throws -> (PageTranslation, PageTimings) {
        lock.lock(); defer { lock.unlock() }
        guard let outcome, let geometry else { throw AppError.message("翻译任务未完成。") }
        return (TranslationPipeline.bind(try outcome.get(), to: geometry), timings)
    }
    var failure: Error? {
        lock.lock(); defer { lock.unlock() }
        guard case .failure(let error) = outcome, !(error is CancellationError) else { return nil }
        return error
    }
}
