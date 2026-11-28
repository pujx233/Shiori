import Foundation

@main
struct PageCompletionTests {
    static func main() throws {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) throws {
            guard value() else { throw AppError.message("FAIL: " + label) }
            count += 1; print("PASS: " + label)
        }
        let options = TranslationOptions(model: "test", effort: "low")
        let bounds = DialogueBounds(x: 10, y: 10, width: 100, height: 100)
        let blocks = (0..<23).map { OCRBlock(id: "b\($0)", text: "台詞\($0)", bounds: bounds) }
        func translations(_ input: [OCRBlock]) -> PageTranslation {
            PageTranslation(summary: "", dialogues: input.map { Dialogue.recognized($0, text: "译文" + $0.text) }, notes: "")
        }
        let full = OCRPage(blocks: blocks, skippedCount: 0, elapsed: 0)
        let lastSuccess = PageResult(options: options, pageDigest: "one", translation: translations(blocks), elapsed: 1)
        let key = PageKey(digest: lastSuccess.pageDigest, options: options)
        var recent = RecentPages<PageKey, PageResult>()
        recent.store(lastSuccess, for: key)
        var shown: PageResult?
        do {
            _ = try TranslationPipeline.run(runner: CommandRunner(), renderPatches: false,
                recognize: { ready in ready(full); return full },
                translate: { source, _, preview in
                    preview(translations(Array(source.blocks.prefix(3))))
                    throw AppError.message("Provider disconnected")
                }, preview: { translation, timings, review in
                    shown = PageResult(options: options, pageDigest: key.digest, translation: translation,
                        elapsed: 1, timings: timings, review: review, state: .translating)
                })
            throw AppError.message("FAIL: interrupted provider succeeded")
        } catch let error as AppError {
            try check(error.localizedDescription == "Provider disconnected", "provider failure is surfaced")
        }
        try check(shown?.translation.dialogues.count == 3 && shown?.translation.untranslatedCount == 20,
                  "three streamed translations retain the full page denominator")
        try check(shown?.isReusable == false && recent.lookup(key)?.id == lastSuccess.id,
                  "a failed retranslation cannot replace the last successful result")
        let degraded = PageResult(options: options, pageDigest: key.digest, translation: translations(blocks),
                                   elapsed: 1, review: .unavailable)
        try check(!degraded.isReusable && lastSuccess.isReusable, "complete translation cannot hide an unreviewed OCR page")

        for digest in ["two", "three"] {
            let entry = PageResult(options: options, pageDigest: digest, translation: translations(blocks), elapsed: 1)
            recent.store(entry, for: PageKey(digest: digest, options: options))
        }
        try check(recent.lookup(key) == nil && recent.lookup(PageKey(digest: "two", options: options)) != nil,
                  "session retains only the last two pages")
        let restarted = RecentPages<PageKey, PageResult>()
        var empty = restarted
        try check(empty.lookup(key) == nil, "a new session starts without cached pages")
        print("\(count) page completion checks passed")
    }
}
