import Foundation
import CryptoKit

// The public web endpoint is also used by Easydict's GTX translator. This is
// intentionally independent of Google Cloud credentials and has no SLA. A denied
// or rate-limited request stops the page; it never rotates hosts or identities.
final class GoogleTranslationClient: @unchecked Sendable {
    static let model = "google-translate"
    private let session: URLSession
    private let cache: GoogleBubbleCache
    private let serial = NSLock()
    private let concurrency: Int
    private let pageTimeout: TimeInterval

    init(cacheDirectory: URL, configuration: URLSessionConfiguration? = nil,
         concurrency: Int = 3, pageTimeout: TimeInterval = 25) throws {
        cache = try GoogleBubbleCache(directory: cacheDirectory)
        let settings = configuration ?? .ephemeral
        settings.httpMaximumConnectionsPerHost = min(6, max(1, concurrency))
        settings.timeoutIntervalForRequest = 10
        settings.timeoutIntervalForResource = 12
        settings.requestCachePolicy = .reloadIgnoringLocalCacheData
        settings.urlCache = nil
        settings.httpCookieStorage = nil
        settings.httpShouldSetCookies = false
        settings.waitsForConnectivity = false
        session = URLSession(configuration: settings)
        self.concurrency = min(6, max(1, concurrency))
        self.pageTimeout = pageTimeout
    }

    deinit { session.invalidateAndCancel() }
    func shutdown() { session.invalidateAndCancel() }

    func translate(ocr: OCRPage, options: TranslationOptions, runner: CommandRunner, force: Bool = false,
                   seed: PageTranslation? = nil,
                   progress: @escaping (String) -> Void = { _ in },
                   preview: ((PageTranslation) -> Void)? = nil) throws -> (PageTranslation, Double) {
        // Both UI previews and cache writes are delivered on the calling worker,
        // never concurrently from URLSession's completion handlers.
        while !serial.try() {
            try runner.checkCancellation()
            Thread.sleep(forTimeInterval: 0.02)
        }
        defer { serial.unlock() }
        try runner.checkCancellation()
        guard Set(ocr.blocks.map(\.id)).count == ocr.blocks.count else {
            throw AppError.message("识字结果包含重复气泡，请重新识别。")
        }

        let began = Date(), mailbox = GoogleMailbox()
        var accepted: [String: Dialogue] = [:]
        var jobs: [GoogleWork] = []
        var plans: [String: GlossaryPlan] = [:]
        var jobIndex: [String: Int] = [:]
        var active: [Int: URLSessionDataTask] = [:]
        var next = 0, failures: [String] = []
        defer { active.values.forEach { $0.cancel() }; cache.trim() }

        func page() -> PageTranslation {
            let missing = ocr.blocks.count - accepted.count
            let notes = failures.isEmpty ? "" : "Google 未能翻译 \(missing) 处：\(failures[0])"
            return PageTranslation(summary: "", dialogues: ocr.blocks.compactMap { accepted[$0.id] }, notes: notes,
                                   skippedCount: ocr.skippedCount + missing, ocrSkippedCount: ocr.skippedCount)
        }

        for block in ocr.blocks {
            try runner.checkCancellation()
            let source = Self.sourceText(block)
            let namespace = "gtx-ja-zh-CN-v1|" + options.cacheNamespace
            if source.isEmpty { failures.append("原文为空。"); continue }
            if !TranslationText(source).hasReadableText {
                accepted[block.id] = Dialogue.recognized(block, text: source)
                continue
            }
            if !force, let old = seed?.dialogues.first(where: { $0.location == block.id && $0.original == block.text }),
               Self.usable(source: source, translation: old.translation) {
                accepted[block.id] = Dialogue.recognized(block, text: old.translation)
                continue
            }
            if !force, let text = cache.lookup(source: source, namespace: namespace), Self.usable(source: source, translation: text) {
                accepted[block.id] = Dialogue.recognized(block, text: text)
                continue
            }
            // Google translates each bubble independently. Repeated text can
            // safely share a request, while each original ID keeps its geometry.
            if let index = jobIndex[source] { jobs[index].blocks.append(block) }
            else {
                jobIndex[source] = jobs.count
                plans[source] = GlossaryPlan(source: source, terms: options.terms)
                jobs.append(GoogleWork(source: source, namespace: namespace, blocks: [block]))
            }
        }
        if !accepted.isEmpty { preview?(page()) }
        guard !jobs.isEmpty else { progress("正在回填…"); return (page(), 0) }
        progress("正在翻译…")

        while next < jobs.count || !active.isEmpty {
            try runner.checkCancellation()
            if Date().timeIntervalSince(began) > pageTimeout {
                failures.append("等待超时，请重试。")
                break
            }
            while active.count < concurrency && next < jobs.count {
                let index = next, job = jobs[index]
                if let earliest = job.readyAt, Date() < earliest { break }
                next += 1
                let request: URLRequest
                do { request = try Self.request(text: plans[job.source]?.text ?? job.source) }
                catch { failures.append(error.localizedDescription); continue }
                let task = session.dataTask(with: request) { data, response, error in
                    let result: Result<String, Error>
                    do {
                        if let error { throw error }
                        result = .success(try Self.parse(data: data ?? Data(), response: response))
                    } catch { result = .failure(error) }
                    mailbox.append(index: index, result: result)
                }
                active[index] = task
                task.resume()
            }
            for (index, result) in mailbox.take(timeout: 0.05) {
                active.removeValue(forKey: index)
                try runner.checkCancellation()
                let job = jobs[index]
                switch result {
                case .success(let raw):
                    let text: String
                    do { text = try plans[job.source]?.restore(raw) ?? raw }
                    catch { failures.append(error.localizedDescription); continue }
                    guard Self.usable(source: job.source, translation: text) else {
                        failures.append("部分原文未能翻译。"); continue
                    }
                    for block in job.blocks { accepted[block.id] = Dialogue.recognized(block, text: text) }
                    cache.save(source: job.source, namespace: job.namespace, translation: text)
                    preview?(page())
                case .failure(let error):
                    if let problem = error as? GoogleTranslationError, problem.stopsPage {
                        // In particular, do not continue sending queued bubbles
                        // after 403/429 or try a different endpoint.
                        throw AppError.configuration(problem.localizedDescription)
                    }
                    if job.attempt == 0, Self.retryable(error), Date().timeIntervalSince(began) + 0.35 < pageTimeout {
                        // Requeue only this bubble once, after current page work.
                        // The ordinary wait loop keeps backoff cancellable and
                        // the retry inside the same page deadline/concurrency cap.
                        var retry = job
                        retry.attempt = 1; retry.readyAt = Date().addingTimeInterval(0.35)
                        jobs.append(retry)
                        continue
                    }
                    failures.append(Self.friendly(error))
                }
            }
        }
        try runner.checkCancellation()
        guard !accepted.isEmpty else {
            throw AppError.message("Google 翻译失败：" + (failures.first ?? "没有收到译文。"))
        }
        let result = page()
        preview?(result)
        return (result, Date().timeIntervalSince(began))
    }

    static func sourceText(_ block: OCRBlock) -> String {
        var source = TranslationText(block.text).text
        // NMT cannot use the OCR confidence hints as an LLM does. Keep uncertain
        // portions explicit instead of presenting a guessed reading as certain.
        for fragment in (block.uncertainFragments ?? []).sorted(by: { $0.count > $1.count }) where !fragment.isEmpty {
            source = source.replacingOccurrences(of: fragment, with: "□")
        }
        return source
    }

    private static func usable(source: String, translation: String) -> Bool {
        TranslationReply.usable(source: source, translated: translation)
            && TranslationText(translation).gaps.count == TranslationText(source).gaps.count
    }

    static func request(text: String) throws -> URLRequest {
        guard text.utf8.count <= 5_000 else { throw GoogleTranslationError.textTooLong }
        var url = URLComponents(string: "https://translate.google.com/translate_a/single")!
        url.queryItems = [URLQueryItem(name: "client", value: "gtx"), URLQueryItem(name: "sl", value: "ja"),
                          URLQueryItem(name: "tl", value: "zh-CN"), URLQueryItem(name: "dt", value: "t"),
                          URLQueryItem(name: "dj", value: "1"), URLQueryItem(name: "ie", value: "UTF-8"),
                          URLQueryItem(name: "q", value: text)]
        // URLComponents leaves '+' unescaped, but web query parsers often read
        // it as a space. Preserve the actual OCR text across that boundary.
        url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: url.url!)
        request.setValue("Shiori", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func parse(data: Data, response: URLResponse?) throws -> String {
        guard let http = response as? HTTPURLResponse else { throw GoogleTranslationError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw GoogleTranslationError.status(http.statusCode) }
        guard data.count <= 1_048_576,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sentences = payload["sentences"] as? [[String: Any]], !sentences.isEmpty else {
            throw GoogleTranslationError.invalidResponse
        }
        // Sentence segmentation belongs to this single request only. Never split
        // translated newlines and assign them to different bubbles.
        let fragments = sentences.compactMap { $0["trans"] as? String }
        guard fragments.count == sentences.count else { throw GoogleTranslationError.invalidResponse }
        let text = fragments.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw GoogleTranslationError.invalidResponse }
        return text
    }

    private static func friendly(_ error: Error) -> String {
        if let problem = error as? GoogleTranslationError { return problem.localizedDescription }
        if (error as NSError).code == NSURLErrorTimedOut { return "网络请求超时。" }
        return "无法连接 Google，请检查网络。"
    }

    private static func retryable(_ error: Error) -> Bool {
        if case .status(let code) = error as? GoogleTranslationError { return (500...599).contains(code) }
        let network = error as NSError
        return network.domain == NSURLErrorDomain && [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost].contains(network.code)
    }
}

private struct GoogleWork {
    let source: String
    let namespace: String
    var blocks: [OCRBlock]
    var attempt = 0
    var readyAt: Date? = nil
}

private final class GoogleMailbox: @unchecked Sendable {
    private let condition = NSCondition()
    private var completed: [(Int, Result<String, Error>)] = []
    func append(index: Int, result: Result<String, Error>) {
        condition.lock(); completed.append((index, result)); condition.signal(); condition.unlock()
    }
    func take(timeout: TimeInterval) -> [(Int, Result<String, Error>)] {
        condition.lock(); defer { condition.unlock() }
        if completed.isEmpty { _ = condition.wait(until: Date().addingTimeInterval(timeout)) }
        let result = completed; completed.removeAll(); return result
    }
}

private enum GoogleTranslationError: LocalizedError {
    case invalidResponse, textTooLong, status(Int)
    var stopsPage: Bool {
        switch self { case .status(let code): return [401, 403, 429].contains(code); default: return false }
    }
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Google 返回的内容无法读取。"
        case .textTooLong: return "单个气泡文字过长，请重新识别。"
        case .status(429): return "Google 请求过于频繁，请稍后再试或切换 Codex。"
        case .status(401), .status(403): return "Google 暂时拒绝访问，请稍后再试或切换 Codex。"
        case .status(let code): return "Google 服务暂时不可用（\(code)）。"
        }
    }
}

private final class GoogleBubbleCache {
    private let directory: URL
    private struct Entry: Codable { let source: String; let namespace: String; let translation: String }
    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        trim()
    }
    private func file(source: String, namespace: String) -> URL {
        let bytes = try! JSONEncoder().encode([namespace, source])
        let key = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key + ".json")
    }
    func lookup(source: String, namespace: String) -> String? {
        let url = file(source: source, namespace: namespace)
        guard let data = try? Data(contentsOf: url), let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.source == source, entry.namespace == namespace else { return nil }
        CacheFiles.touch(url)
        return entry.translation
    }
    func save(source: String, namespace: String, translation: String) {
        guard let data = try? JSONEncoder().encode(Entry(source: source, namespace: namespace, translation: translation)) else { return }
        try? data.write(to: file(source: source, namespace: namespace), options: .atomic)
    }
    func trim() { CacheFiles.trim(directory, maxBytes: 2 * 1024 * 1024, maxCount: 800) }
}
