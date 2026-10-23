import Foundation

// Text can leave the OCR worker while its local background repairs are still
// running. Only final geometry/patches are ever sent to the overlay or cache.
enum TranslationPipeline {
    typealias Translate = (OCRPage, @escaping (PageTranslation) -> Void) throws -> PageTranslation

    static func run(runner: CommandRunner, began: Date = Date(),
                    recognize: (@escaping (OCRPage) -> Void) throws -> OCRPage,
                    translate: @escaping Translate,
                    preview: @escaping (PageTranslation, PageTimings) -> Void) throws -> (PageTranslation, PageTimings) {
        let state = PipelineState(began: began, preview: preview)
        let finished = DispatchSemaphore(value: 0)
        var started = false
        func start(_ draft: OCRPage) {
            guard !started, !draft.blocks.isEmpty, !runner.isCancelled else { return }
            started = true
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
        state.setGeometry(final, elapsed: ocrTime)
        guard !final.blocks.isEmpty else {
            return (PageTranslation(summary: "", dialogues: [], notes: "未识别到日文",
                                    skippedCount: final.skippedCount, ocrSkippedCount: final.skippedCount),
                    PageTimings(ocr: ocrTime, codex: 0, firstResult: nil))
        }
        start(final)
        while finished.wait(timeout: .now() + 0.05) != .success {
            if runner.isCancelled { throw state.failure ?? CancellationError() }
        }
        if runner.isCancelled { throw state.failure ?? CancellationError() }
        return try state.result()
    }

    static func bind(_ translated: PageTranslation, to ocr: OCRPage) -> PageTranslation {
        let mapped = Dictionary(translated.dialogues.map { ($0.location, $0) }, uniquingKeysWith: { first, _ in first })
        let dialogues = ocr.blocks.compactMap { block -> Dialogue? in
            guard let text = mapped[block.id], text.original == block.text else { return nil }
            return Dialogue.recognized(block, text: text.translation)
        }
        return PageTranslation(summary: translated.summary, dialogues: dialogues, notes: translated.notes,
                               skippedCount: ocr.skippedCount + ocr.blocks.count - dialogues.count,
                               ocrSkippedCount: ocr.skippedCount)
    }
}

private final class PipelineState: @unchecked Sendable {
    private let lock = NSLock()
    private let began: Date
    private let preview: (PageTranslation, PageTimings) -> Void
    private var geometry: OCRPage?
    private var partial: PageTranslation?
    private var outcome: Result<PageTranslation, Error>?
    private var ocrTime = 0.0
    private var translationTime = 0.0
    private var firstResult: Double?
    init(began: Date, preview: @escaping (PageTranslation, PageTimings) -> Void) {
        self.began = began; self.preview = preview
    }
    private var timings: PageTimings { PageTimings(ocr: ocrTime, codex: translationTime, firstResult: firstResult) }
    private func publish() {
        guard let geometry, let partial else { return }
        let bound = TranslationPipeline.bind(partial, to: geometry)
        guard !bound.dialogues.isEmpty else { return }
        if firstResult == nil { firstResult = Date().timeIntervalSince(began) }
        // Callbacks are serialized, even when repair completion races a network
        // preview. AppController dispatches the lightweight result to AppKit.
        preview(bound, timings)
    }
    func update(_ value: PageTranslation, elapsed: Double) {
        lock.lock(); defer { lock.unlock() }
        partial = value; translationTime = elapsed; publish()
    }
    func setGeometry(_ page: OCRPage, elapsed: Double) {
        lock.lock(); defer { lock.unlock() }
        geometry = page; ocrTime = elapsed; publish()
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
