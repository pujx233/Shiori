import Foundation

// Compile with Core.swift, OCR.swift, CodexSession.swift and GoogleTranslation.swift.
// Default tests use URLProtocol and isolated caches. --live sends only the
// synthetic Japanese dialogue declared below to Google, never a captured page.
@main
struct GoogleTranslationTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shiori-google-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let options = TranslationOptions(model: GoogleTranslationClient.model, effort: "none")
        let bounds = DialogueBounds(x: 10, y: 20, width: 100, height: 120)
        func block(_ id: String, _ text: String) -> OCRBlock { OCRBlock(id: id, text: text, bounds: bounds) }
        func page(_ blocks: [OCRBlock]) -> OCRPage { OCRPage(blocks: blocks, skippedCount: 2, elapsed: 0) }
        func check(_ pass: Bool, _ name: String) throws {
            guard pass else { throw AppError.message("FAIL: " + name) }; print("PASS: " + name)
        }
        if CommandLine.arguments.contains("--live") || CommandLine.arguments.contains("--codex") {
            let sentences = ["おはよう。今日はいい天気だね。", "放課後、一緒に練習しよう。", "この曲、もう一回やってみない？", "ギターを忘れてきちゃった。",
                             "大丈夫、予備の楽器があるよ。", "先輩はまだ教室にいるのかな。", "音が少し小さいみたい。", "窓を閉めてもらってもいい？",
                             "次のライブは日曜日だよ。", "みんなで駅まで歩こう。", "そのリズム、すごくいいね。", "今日は何時まで練習する？",
                             "もう少しゆっくり弾いてみて。", "新しい歌詞を考えてきたよ。", "雨が降る前に帰ろう。", "お腹が空いたから何か食べたい。",
                             "このフレーズを覚えるのは難しい。", "失敗しても、もう一度やればいい。", "明日は文化祭の準備があるんだ。", "ありがとう。また明日ね。"]
            let input = page(sentences.enumerated().map { block("b\($0.offset)", $0.element) })
            if CommandLine.arguments.contains("--codex") {
                let client = try CodexClient(resources: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources"),
                                             workspace: root.appendingPathComponent("codex"))
                defer { client.shutdown() }
                try client.prepare()
                let codexOptions = TranslationOptions(model: "gpt-6-luna", effort: "low")
                let start = Date()
                var first: Double?
                let (result, elapsed) = try client.translate(ocr: input, options: codexOptions, runner: CommandRunner(), force: true,
                    preview: { preview in
                        if first == nil && !preview.dialogues.isEmpty { first = Date().timeIntervalSince(start) }
                    })
                let report: [String: Any] = ["bubbles": sentences.count, "translated": result.translatedCount, "model": codexOptions.model,
                                            "firstResultSeconds": first ?? -1, "translationSeconds": elapsed, "notes": result.notes,
                                            "translations": result.dialogues.map { ["source": $0.original, "translation": $0.translation] }]
                print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
                try check(result.translatedCount == 20, "all synthetic bubbles translated with Codex")
                return
            }
            let concurrency = CommandLine.arguments.contains("--six") ? 6 : 3
            let client = try GoogleTranslationClient(cacheDirectory: root.appendingPathComponent("live"), concurrency: concurrency)
            defer { client.shutdown() }
            var first: Double?, previews = 0
            let start = Date()
            let (result, elapsed) = try client.translate(ocr: input, options: options, runner: CommandRunner(), force: true,
                preview: { preview in
                    if first == nil && !preview.dialogues.isEmpty { first = Date().timeIntervalSince(start) }
                    previews += 1
                })
            let cachedStart = Date()
            let (cached, cachedTime) = try client.translate(ocr: input, options: options, runner: CommandRunner())
            let report: [String: Any] = ["bubbles": sentences.count, "translated": result.translatedCount, "concurrency": concurrency,
                                        "firstResultSeconds": first ?? -1, "translationSeconds": elapsed,
                                        "cacheWallSeconds": Date().timeIntervalSince(cachedStart), "cacheReportedSeconds": cachedTime,
                                        "cachedCount": cached.translatedCount, "previews": previews, "notes": result.notes,
                                        "translations": result.dialogues.map { ["source": $0.original, "translation": $0.translation] }]
            print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
            try check(result.translatedCount == 20, "all synthetic bubbles translated")
            return
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GoogleProtocolStub.self]
        let client = try GoogleTranslationClient(cacheDirectory: root.appendingPathComponent("mock"), configuration: configuration)
        defer { client.shutdown() }
        GoogleProtocolStub.reset([
            "おはよう": .init(fragments: ["早上好"], delay: 0.15),
            "帰ろう": .init(fragments: ["回家吧"], delay: 0.02),
            "一行\n二行": .init(fragments: ["第一行。\n", "第二行。"], delay: 0.04),
            "今日は□": .init(fragments: ["今天□"], delay: 0.01)
        ])
        var uncertain = block("uncertain", "今日は晴れ"); uncertain.uncertainFragments = ["晴れ"]
        let input = page([block("a", "おはよう"), block("b", "帰ろう"), block("duplicate", "おはよう"),
                          block("multiline", "一行\n二行"), uncertain, block("unknown", "□")])
        var counts: [Int] = []
        let result = try client.translate(ocr: input, options: options, runner: CommandRunner(), preview: { counts.append($0.dialogues.count) }).0
        try check(result.dialogues.map(\.location) == input.blocks.map(\.id), "out-of-order responses retain every original ID and reading order")
        try check(result.dialogues[3].translation == "第一行。\n第二行。", "sentence fragments and embedded newline stay inside one bubble")
        try check(GoogleProtocolStub.requestCount("おはよう") == 1, "duplicate dialogue shares a request without dropping its second ID")
        try check(GoogleProtocolStub.peak() <= 3 && GoogleProtocolStub.total() == 4, "concurrency is bounded and unreadable source needs no network")
        try check(result.dialogues[4].uncertainRanges?.count == 1 && result.dialogues[5].preserveOriginal == true, "uncertainty remains structured and wholly unreadable source is preserved")
        try check(zip(counts, counts.dropFirst()).allSatisfy { $0 <= $1 } && counts.contains { $0 > 1 && $0 < 6 }, "progressive previews are serial and monotonically complete")
        try check(result.skippedCount == 2 && result.ocrSkippedCount == 2, "OCR omissions are counted separately from translation omissions")

        let moved = OCRBlock(id: "new-id", text: "おはよう", bounds: DialogueBounds(x: 700, y: 10, width: 60, height: 90))
        let cached = try client.translate(ocr: page([moved]), options: options, runner: CommandRunner()).0
        try check(cached.dialogues.first?.location == "new-id" && cached.dialogues.first?.bounds?.x == 700 && GoogleProtocolStub.total() == 4,
                  "single-bubble cache survives page changes and always binds current geometry")
        _ = try client.translate(ocr: page([moved]), options: options, runner: CommandRunner(), force: true)
        try check(GoogleProtocolStub.requestCount("おはよう") == 2, "manual retry bypasses the bubble cache")
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("mock"), includingPropertiesForKeys: nil)
        try check(files.count == 4, "persistent cache contains only independently translated strings")

        GoogleProtocolStub.reset(["待って": .init(fragments: ["等等"], delay: 2)])
        let runner = CommandRunner(), start = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.12) { runner.cancel() }
        do {
            _ = try client.translate(ocr: page([block("cancel", "待って")]), options: options, runner: runner, force: true)
            throw AppError.message("FAIL: cancellation ignored")
        } catch is CancellationError {
            try check(Date().timeIntervalSince(start) < 0.4, "page cancellation stops without waiting for HTTP timeout")
        }

        GoogleProtocolStub.reset(["拒否": .init(fragments: [], status: 429, delay: 0.01)])
        do {
            _ = try client.translate(ocr: page((0..<9).map { block("denied\($0)", "拒否\($0)") }), options: options, runner: CommandRunner(), force: true)
            throw AppError.message("FAIL: denied page accepted")
        } catch let error as AppError {
            try check(error.needsUserAction && error.localizedDescription.contains("频繁"), "rate limiting surfaces an actionable service error")
            try check(GoogleProtocolStub.total() <= 3, "rate-limited page sends no queued requests and performs no retry")
        }

        GoogleProtocolStub.reset(["一時的": .init(fragments: ["暂时"], statuses: [500, 200])])
        let recovered = try client.translate(ocr: page([block("recover", "一時的")]), options: options, runner: CommandRunner(), force: true).0
        try check(recovered.translatedCount == 1 && recovered.untranslatedCount == 0 && recovered.notes.isEmpty
                  && GoogleProtocolStub.requestCount("一時的") == 2, "one transient 500 retries only its bubble and clears the temporary failure")

        GoogleProtocolStub.reset(["繰り返し": .init(fragments: [], status: 500), "おはよう": .init(fragments: ["早上好"])])
        let failedTwice = try client.translate(ocr: page([block("failed-twice", "繰り返し"), block("good", "おはよう")]), options: options,
                                               runner: CommandRunner(), force: true).0
        try check(failedTwice.translatedCount == 1 && failedTwice.untranslatedCount == 1 && failedTwice.notes.contains("500")
                  && GoogleProtocolStub.requestCount("繰り返し") == 2, "repeated 500 stops after one retry and keeps the bubble pending")

        GoogleProtocolStub.reset(["時間切れ": .init(fragments: ["超时"], errorCodes: [NSURLErrorTimedOut])])
        let timeoutRecovered = try client.translate(ocr: page([block("timeout-retry", "時間切れ")]), options: options, runner: CommandRunner(), force: true).0
        try check(timeoutRecovered.translatedCount == 1 && GoogleProtocolStub.requestCount("時間切れ") == 2,
                  "a transient network timeout can recover with one retry")

        GoogleProtocolStub.reset(["あとで": .init(fragments: ["稍后"], statuses: [500, 200])])
        let backoffRunner = CommandRunner(), backoffStart = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.12) { backoffRunner.cancel() }
        do {
            _ = try client.translate(ocr: page([block("backoff", "あとで")]), options: options, runner: backoffRunner, force: true)
            throw AppError.message("FAIL: retry backoff ignored cancellation")
        } catch is CancellationError {
            try check(Date().timeIntervalSince(backoffStart) < 0.3 && GoogleProtocolStub.requestCount("あとで") == 1,
                      "cancelling during retry backoff returns promptly without a second request")
        }

        GoogleProtocolStub.reset(["壊れた": .init(fragments: [], raw: Data("not json".utf8))])
        do {
            _ = try client.translate(ocr: page([block("broken", "壊れた")]), options: options, runner: CommandRunner(), force: true)
            throw AppError.message("FAIL: malformed response accepted")
        } catch let error as AppError { try check(error.localizedDescription.contains("无法读取"), "malformed JSON is not treated as a successful translation") }

        GoogleProtocolStub.reset(["今日は□": .init(fragments: ["今天天气晴朗"])])
        do {
            _ = try client.translate(ocr: page([uncertain]), options: options, runner: CommandRunner(), force: true)
            throw AppError.message("FAIL: lost uncertainty accepted")
        } catch let error as AppError { try check(error.localizedDescription.contains("未能翻译"), "translation cannot silently discard an uncertainty marker") }
        GoogleProtocolStub.reset(["今日は□": .init(fragments: ["今天天气晴朗"]), "おはよう": .init(fragments: ["早上好"])])
        let partial = try client.translate(ocr: page([uncertain, block("good", "おはよう")]), options: options, runner: CommandRunner(), force: true).0
        try check(partial.translatedCount == 1 && partial.untranslatedCount == 1 && partial.pendingCount == 3
                  && partial.dialogues.first?.location == "good" && partial.notes.contains("未能翻译 1 处"),
                  "lost uncertainty stays pending with the original bubble untouched and explicit failure detail")

        let request = try GoogleTranslationClient.request(text: "何？ A&B + C\n次の行")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        try check(query.filter { $0.name == "q" }.map(\.value) == ["何？ A&B + C\n次の行"] && request.url!.absoluteString.contains("%2B"),
                  "query encoding preserves punctuation, newlines, ampersands and plus signs")
        do { _ = try GoogleTranslationClient.request(text: String(repeating: "あ", count: 2000)); throw AppError.message("FAIL: oversized source accepted") }
        catch { try check(error.localizedDescription.contains("过长"), "oversized source is rejected without silent truncation") }
        let timeoutConfiguration = URLSessionConfiguration.ephemeral; timeoutConfiguration.protocolClasses = [GoogleProtocolStub.self]
        let short = try GoogleTranslationClient(cacheDirectory: root.appendingPathComponent("budget"), configuration: timeoutConfiguration, pageTimeout: 0.12)
        defer { short.shutdown() }
        GoogleProtocolStub.reset(["長い": .init(fragments: ["很长"], delay: 3)])
        let budgetStart = Date()
        do { _ = try short.translate(ocr: page([block("budget", "長い")]), options: options, runner: CommandRunner()); throw AppError.message("FAIL: budget ignored") }
        catch { try check(Date().timeIntervalSince(budgetStart) < 0.4 && error.localizedDescription.contains("超时"), "whole-page budget also cancels active requests") }
        GoogleProtocolStub.reset(["残り時間": .init(fragments: [], status: 500)])
        do {
            _ = try short.translate(ocr: page([block("retry-budget", "残り時間")]), options: options, runner: CommandRunner(), force: true)
            throw AppError.message("FAIL: repeated error accepted")
        } catch { try check(GoogleProtocolStub.requestCount("残り時間") == 1, "retry is not queued beyond the remaining whole-page budget") }
    }
}

private final class GoogleProtocolStub: URLProtocol, @unchecked Sendable {
    struct Reply {
        var fragments: [String]
        var status: Int = 200
        var delay: Double = 0.01
        var raw: Data? = nil
        var statuses: [Int]? = nil
        var errorCodes: [Int]? = nil
    }
    private static let lock = NSLock()
    private static var replies: [String: Reply] = [:]
    private static var requests: [String: Int] = [:]
    private static var active = 0, maximum = 0
    private var finished = false
    static func reset(_ responses: [String: Reply]) {
        lock.lock(); defer { lock.unlock() }
        replies = responses; requests = [:]; active = 0; maximum = 0
    }
    static func requestCount(_ text: String) -> Int { lock.lock(); defer { lock.unlock() }; return requests[text] ?? 0 }
    static func total() -> Int { lock.lock(); defer { lock.unlock() }; return requests.values.reduce(0, +) }
    static func peak() -> Int { lock.lock(); defer { lock.unlock() }; return maximum }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "translate.google.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let text = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value ?? ""
        Self.lock.lock()
        Self.requests[text, default: 0] += 1; Self.active += 1; Self.maximum = max(Self.maximum, Self.active)
        let reply = Self.replies[text] ?? Self.replies["拒否"] ?? Reply(fragments: ["译文"])
        let attempt = Self.requests[text]! - 1
        Self.lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [self] in
            Self.lock.lock()
            guard !finished else { Self.lock.unlock(); return }
            finished = true; Self.active -= 1
            Self.lock.unlock()
            if let codes = reply.errorCodes, attempt < codes.count {
                client?.urlProtocol(self, didFailWithError: NSError(domain: NSURLErrorDomain, code: codes[attempt])); return
            }
            let status = reply.statuses.map { $0[min(attempt, $0.count-1)] } ?? reply.status
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/2", headerFields: ["Content-Type": "application/json"])!
            let data = reply.raw ?? (try! JSONSerialization.data(withJSONObject: ["sentences": reply.fragments.map { ["trans": $0] }]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        if !finished { finished = true; Self.active -= 1 }
    }
}
