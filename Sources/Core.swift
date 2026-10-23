import AppKit
import CryptoKit
import Foundation

enum AppStorage {
    static func directory() throws -> URL {
        let files = FileManager.default
        let parent = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let current = parent.appendingPathComponent("Shiori")
        let previous = parent.appendingPathComponent("KedaTranslate")
        if !files.fileExists(atPath: current.path), files.fileExists(atPath: previous.path) {
            try files.moveItem(at: previous, to: current)
        }
        try files.createDirectory(at: current, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return current
    }
}

enum AppError: LocalizedError {
    case message(String)
    case configuration(String)
    var errorDescription: String? {
        switch self { case .message(let text), .configuration(let text): return text }
    }
    var needsUserAction: Bool { if case .configuration = self { return true }; return false }

    static func translationFailure(_ detail: String) -> AppError {
        let text = detail.lowercased()
        if ["usage limit", "usage_limit", "insufficient_quota", "quota exceeded"].contains(where: text.contains) {
            return .configuration("Codex 额度已用完，请恢复后再开始阅读。")
        }
        if ["unauthorized", "authentication", "not logged in", "token expired", "401"].contains(where: text.contains) {
            return .configuration("Codex 登录已失效，请登录后再开始阅读。")
        }
        return .message("翻译失败：" + String(detail.suffix(800)))
    }
}

struct TextGap: Codable, Equatable {
    let location: Int
    let length: Int
    var range: NSRange { NSRange(location: location, length: length) }

    func within(offset: Int, length: Int) -> TextGap? {
        let overlap = NSIntersectionRange(range, NSRange(location: offset, length: length))
        return overlap.length == 0 ? nil : TextGap(location: overlap.location-offset, length: overlap.length)
    }
}

// Convert model notation into presentation data before caching or typesetting.
// Old replies remain readable, without placing diagnostic prose in the balloon.
struct TranslationText {
    let text: String
    let gaps: [TextGap]
    var hasReadableText: Bool { text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) } }

    init(_ raw: String) {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for marker in ["[原文不清]", "［原文不清］", "【原文不清】"] {
            value = value.replacingOccurrences(of: marker, with: "□")
        }
        text = value
        let string = value as NSString
        var found: [TextGap] = [], start = 0
        while start < string.length {
            let range = string.range(of: "□", range: NSRange(location: start, length: string.length-start))
            if range.location == NSNotFound { break }
            found.append(TextGap(location: range.location, length: range.length))
            start = NSMaxRange(range)
        }
        gaps = found
    }
}

struct Dialogue: Codable {
    let location: String
    let original: String
    let translation: String
    var bounds: DialogueBounds? = nil
    var replacementPNG: Data? = nil
    var replacementAllowed: Bool? = nil
    var textStyle: String? = nil
    var layoutBounds: DialogueBounds? = nil
    var layoutRegions: [DialogueBounds]? = nil
    var vertical: Bool? = nil
    var fontSize: Double? = nil
    var uncertainRanges: [TextGap]? = nil
    var preserveOriginal: Bool? = nil

    var needsReview: Bool { preserveOriginal == true || !(uncertainRanges ?? []).isEmpty }

    static func recognized(_ block: OCRBlock, text: String) -> Dialogue {
        let reading = TranslationText(text)
        return Dialogue(location: block.id, original: block.text, translation: reading.text, bounds: block.bounds,
                        replacementPNG: block.replacementPNG, replacementAllowed: block.replacementAllowed,
                        textStyle: block.textStyle, layoutBounds: block.layoutBounds, layoutRegions: block.layoutRegions,
                        vertical: block.vertical, fontSize: block.fontSize,
                        uncertainRanges: reading.gaps.isEmpty ? nil : reading.gaps,
                        preserveOriginal: !reading.gaps.isEmpty && !reading.hasReadableText ? true : nil)
    }
}

struct DialogueBounds: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    func rect(in size: CGSize) -> CGRect? {
        guard [x, y, width, height].allSatisfy({ $0.isFinite }), width > 0, height > 0 else { return nil }
        let rect = CGRect(x: x * size.width / 1000, y: y * size.height / 1000,
                          width: width * size.width / 1000, height: height * size.height / 1000)
            .intersection(CGRect(origin: .zero, size: size))
        return rect.isNull || rect.isEmpty ? nil : rect
    }
}

struct PageTranslation: Codable {
    let summary: String
    let dialogues: [Dialogue]
    let notes: String
    var skippedCount: Int = 0
    var ocrSkippedCount: Int? = nil

    var untranslatedCount: Int { max(0, skippedCount - (ocrSkippedCount ?? 0)) }
    var unclearCount: Int { dialogues.filter(\.needsReview).count }
    var preservedCount: Int { dialogues.filter { $0.preserveOriginal == true }.count }
    var translatedCount: Int { dialogues.count - preservedCount }
    var pendingCount: Int { skippedCount + unclearCount }
}

struct ModelInfo: Codable {
    struct Effort: Codable { let effort: String }
    let slug: String
    let display_name: String
    let visibility: String?
    let input_modalities: [String]?
    let supported_reasoning_levels: [Effort]?
}

enum TranslationProvider: String, Codable {
    case codex, google
}

struct TranslationOptions: Codable, Equatable {
    var model: String
    var effort: String
    // Increment when the prompt, OCR grouping or reading-order rules change.
    var promptVersion = 17
    var context = ""
    var provider: TranslationProvider = .codex
    init(model: String, effort: String, promptVersion: Int = 17, context: String = "", provider: TranslationProvider = .codex) {
        self.model = model; self.effort = effort; self.promptVersion = promptVersion
        self.context = context; self.provider = provider
    }
    private enum CodingKeys: String, CodingKey { case model, effort, promptVersion, context, provider }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        model = try values.decode(String.self, forKey: .model)
        effort = try values.decode(String.self, forKey: .effort)
        promptVersion = try values.decode(Int.self, forKey: .promptVersion)
        context = try values.decodeIfPresent(String.self, forKey: .context) ?? ""
        provider = try values.decodeIfPresent(TranslationProvider.self, forKey: .provider) ?? .codex
    }
    var cacheNamespace: String {
        let base = "\(model)|\(effort)|zh-Hans|\(promptVersion)"
        return provider == .codex ? base : provider.rawValue + "|" + base
    }
    var readingScope: String { cacheNamespace + "|" + context }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.cacheNamespace == rhs.cacheNamespace }
}

struct CapturedPage {
    let image: CGImage
    let digest: String
    let displaySize: CGSize
    let contentRect: CGRect
    private let appearance: [UInt8]
    private let contentPixels: [UInt8]

    init(image: CGImage, displaySize: CGSize? = nil, contentRect: CGRect? = nil) throws {
        self.image = image
        self.displaySize = displaySize ?? CGSize(width: image.width, height: image.height)
        self.contentRect = contentRect ?? CGRect(origin: .zero, size: self.displaySize)
        // Area-filter fine manga lines before comparing different capture sizes.
        // Low interpolation aliases the same page differently at 640 and 2600 px.
        appearance = Self.grayPixels(image, width: 64, height: 64, quality: .high)
        contentPixels = Self.grayPixels(image, width: 256, height: 256)
        guard let pixels = image.dataProvider?.data else { throw AppError.message("无法读取漫画截图。") }
        var hash = SHA256()
        hash.update(data: Data("\(image.width)x\(image.height)|\(image.bytesPerRow)|\(self.contentRect)|".utf8))
        hash.update(data: pixels as Data)
        digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func isVisuallySimilar(to other: CapturedPage) -> Bool {
        guard image.width == other.image.width, image.height == other.image.height,
              displaySize == other.displaySize, contentRect == other.contentRect else { return false }
        var difference = 0, changed = 0
        for (a, b) in zip(appearance, other.appearance) {
            let delta = abs(Int(a)-Int(b)); difference += delta
            if delta > 20 { changed += 1 }
        }
        return Double(difference)/Double(appearance.count) <= 2
            && Double(changed)/Double(appearance.count) <= 0.03
    }

    func hasSameTextRegions(as other: CapturedPage, regions: [DialogueBounds]) -> Bool {
        guard !regions.isEmpty, image.width == other.image.width, image.height == other.image.height,
              displaySize == other.displaySize, contentRect == other.contentRect else { return false }
        let size = CGSize(width: image.width, height: image.height)
        for bounds in regions {
            guard let rect = bounds.rect(in: size)?.integral,
                  let first = image.cropping(to: rect), let second = other.image.cropping(to: rect),
                  Self.grayPixels(first, width: first.width, height: first.height)
                    == Self.grayPixels(second, width: second.width, height: second.height) else { return false }
        }
        return true
    }

    // Compare local tiles across the entire window, including areas without old OCR.
    // A small new bubble must not disappear into a whole-page average.
    func hasSameContent(as other: CapturedPage) -> Bool {
        changedTiles(from: other).isEmpty
    }

    func matchesProbe(_ other: CapturedPage) -> Bool {
        guard displaySize == other.displaySize,
              abs(contentRect.width/contentRect.height - other.contentRect.width/other.contentRect.height) < 0.02 else { return false }
        let difference = zip(appearance, other.appearance).reduce(0) { $0 + abs(Int($1.0)-Int($1.1)) }
        return Double(difference)/Double(appearance.count) < 5
    }

    func hasPersistentChange(from reference: CapturedPage, previous: CapturedPage) -> Bool {
        let persistent = changedTiles(from: reference).intersection(previous.changedTiles(from: reference))
        return !persistent.subtracting(changedTiles(from: previous)).isEmpty
    }

    private func changedTiles(from other: CapturedPage) -> Set<Int> {
        if digest == other.digest && displaySize == other.displaySize { return [] }
        guard image.width == other.image.width, image.height == other.image.height,
              displaySize == other.displaySize, contentRect == other.contentRect else { return Set(0..<256) }
        var tiles: Set<Int> = []
        for top in stride(from: 0, to: 256, by: 16) {
            for left in stride(from: 0, to: 256, by: 16) {
                var difference = 0, changed = 0
                for y in top..<(top + 16) {
                    for x in left..<(left + 16) {
                        let index = y * 256 + x
                        let delta = abs(Int(contentPixels[index]) - Int(other.contentPixels[index]))
                        difference += delta
                        if delta > 24 { changed += 1 }
                    }
                }
                if difference > 384 || changed >= 4 { tiles.insert(top + left / 16) }
            }
        }
        return tiles
    }

    private static func grayPixels(_ image: CGImage, width: Int, height: Int,
                                   quality: CGInterpolationQuality = .low) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width*height)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            context.interpolationQuality = quality
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }

    func encoded(_ type: NSBitmapImageRep.FileType) throws -> Data {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: type, properties: [.compressionFactor: 0.9]) else {
            throw AppError.message("无法编码漫画截图。")
        }
        return data
    }
}

// Holds at most two captures. Failed/empty pages stay submitted until the page
// actually changes, so automatic mode neither stops nor retries in a loop.
struct PageTracker {
    private(set) var current: CapturedPage?
    private var candidate: CapturedPage?
    private var submitted: String?

    private(set) var isSettling = false
    var needsSubmission: Bool { current.map { submitted != $0.digest } ?? false }

    mutating func observe(_ page: CapturedPage) -> CapturedPage? {
        if let current, page.hasSameContent(as: current) {
            candidate = nil; isSettling = false
            return current
        }
        if let candidate {
            if let current {
                if page.hasPersistentChange(from: current, previous: candidate) {
                    adopt(page); return page
                }
                if page.isVisuallySimilar(to: current) {
                    // A changing button/spinner is not a stable page change.
                    self.candidate = page; isSettling = false; return current
                }
            } else if page.isVisuallySimilar(to: candidate) {
                adopt(page); return page
            }
        }
        candidate = page; isSettling = true
        return nil
    }
    mutating func adopt(_ page: CapturedPage) { current = page; candidate = nil; isSettling = false }
    mutating func markSubmitted(_ digest: String) { submitted = digest }
    mutating func release(_ digest: String) { if submitted == digest { submitted = nil } }
    mutating func reset() { current = nil; candidate = nil; submitted = nil; isSettling = false }
}

struct CacheEntry: Codable {
    let id: String
    let options: TranslationOptions
    let pageDigest: String
    let translation: PageTranslation
    let createdAt: Date
    let elapsed: Double
    var timings: PageTimings? = nil
}

struct PageTimings: Codable {
    let ocr: Double
    let codex: Double
    let firstResult: Double?
    var diagnosticState: [String: Any] {
        var values: [String: Any] = ["ocr": ocr, "codex": codex]
        if let firstResult { values["firstResult"] = firstResult }
        return values
    }
}

final class TranslationCache {
    let directory: URL

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        CacheFiles.trim(directory, maxBytes: 120 * 1024 * 1024)
    }

    func lookup(page: CapturedPage, options: TranslationOptions) -> CacheEntry? {
        let key = Self.key(page.digest, options)
        let file = directory.appendingPathComponent(key + ".json")
        guard let data = try? Data(contentsOf: file),
              let entry = try? JSONDecoder().decode(CacheEntry.self, from: data),
              entry.id == key, entry.pageDigest == page.digest, entry.options == options else { return nil }
        CacheFiles.touch(file)
        return entry
    }

    static func key(_ digest: String, _ options: TranslationOptions) -> String {
        SHA256.hash(data: Data((digest + options.cacheNamespace).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func save(page: CapturedPage, options: TranslationOptions, translation: PageTranslation, elapsed: Double,
              timings: PageTimings? = nil) throws -> CacheEntry {
        let entry = CacheEntry(id: Self.key(page.digest, options), options: options,
                              pageDigest: page.digest, translation: translation, createdAt: Date(), elapsed: elapsed, timings: timings)
        let data = try JSONEncoder().encode(entry)
        try data.write(to: directory.appendingPathComponent(entry.id + ".json"), options: .atomic)
        CacheFiles.trim(directory, maxBytes: 120 * 1024 * 1024)
        return entry
    }
}

// Image geometry and local erasure patches are never reused by the text cache.
// An exact match of the whole ordered OCR input preserves the model's page context.
struct TextTranslationCache: Sendable {
    let directory: URL
    private struct Entry: Codable {
        let options: TranslationOptions
        let sources: [String]
        let translations: [String]
        let notes: String
    }

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        CacheFiles.trim(directory, maxBytes: 8 * 1024 * 1024)
    }

    private func file(_ ocr: OCRPage, _ options: TranslationOptions) -> URL {
        // JSON array encoding preserves string boundaries, order and repeated dialogue.
        let input = [[options.cacheNamespace]] + ocr.blocks.map { [$0.text, $0.translationKind ?? ""] + ($0.uncertainFragments ?? []) }
        let data = try! JSONEncoder().encode(input)
        let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key + ".json")
    }

    func lookup(ocr: OCRPage, options: TranslationOptions) -> PageTranslation? {
        let url = file(ocr, options)
        guard !ocr.blocks.isEmpty, let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: data), entry.options == options,
              entry.sources == ocr.blocks.map(\.text), entry.translations.count == ocr.blocks.count,
              entry.translations.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return nil }
        CacheFiles.touch(url)
        let dialogues = zip(ocr.blocks, entry.translations).map { Dialogue.recognized($0.0, text: $0.1) }
        return PageTranslation(summary: "", dialogues: dialogues, notes: entry.notes,
                               skippedCount: ocr.skippedCount, ocrSkippedCount: ocr.skippedCount)
    }

    func save(ocr: OCRPage, options: TranslationOptions, translation: PageTranslation) throws {
        let dialogues = translation.dialogues
        guard !ocr.blocks.isEmpty, dialogues.count == ocr.blocks.count,
              Set(dialogues.map(\.location)).count == dialogues.count,
              translation.skippedCount == ocr.skippedCount else { return }
        let mapped = Dictionary(uniqueKeysWithValues: dialogues.map { ($0.location, $0) })
        var texts: [String] = []
        for block in ocr.blocks {
            guard let dialogue = mapped[block.id], dialogue.original == block.text,
                  !dialogue.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            texts.append(dialogue.translation)
        }
        let entry = Entry(options: options, sources: ocr.blocks.map(\.text), translations: texts, notes: translation.notes)
        try JSONEncoder().encode(entry).write(to: file(ocr, options), options: .atomic)
        CacheFiles.trim(directory, maxBytes: 8 * 1024 * 1024)
    }
}

enum CacheFiles {
    static func touch(_ file: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
    }

    static func trim(_ directory: URL, maxBytes: Int, maxCount: Int = 300) {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []
        let ordered = files.filter { $0.pathExtension == "json" }.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                  let bytes = values.fileSize else { return nil }
            return (url, bytes, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 > $1.2 }
        var bytes = 0, count = 0
        for (url, size, _) in ordered {
            if count < maxCount, bytes + size <= maxBytes {
                count += 1; bytes += size
            } else { try? FileManager.default.removeItem(at: url) }
        }
    }
}

struct CommandResult { let status: Int32; let stdout: Data; let stderr: Data }

// File-backed output avoids pipe deadlocks on large model catalogs and JSON event streams.
final class CommandRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func checkCancellation() throws { if isCancelled { throw CancellationError() } }

    func cancel() {
        lock.lock(); cancelled = true; let running = process; lock.unlock()
        if let running, running.isRunning {
            running.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if running.isRunning { kill(running.processIdentifier, SIGKILL) }
            }
        }
    }

    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // Use existing official ChatGPT login, never accidentally pick up API billing or a proxy provider.
        for key in Array(env.keys) where key.hasPrefix("CODEX_") || key == "OPENAI_API_KEY"
            || key == "OPENAI_BASE_URL" || key == "OPENAI_ORG_ID" || key == "OPENAI_PROJECT_ID" {
            if key != "CODEX_HOME" { env.removeValue(forKey: key) }
        }
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        return env
    }

    func run(executable: URL, arguments: [String], directory: URL, input: String? = nil,
             timeout: TimeInterval = 180, onEvent: (([String: Any]) -> Void)? = nil) throws -> CommandResult {
        let ioDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("shiori-io-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: ioDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: ioDirectory) }
        let outURL = ioDirectory.appendingPathComponent("out"), errURL = ioDirectory.appendingPathComponent("err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: outURL), err = try FileHandle(forWritingTo: errURL)
        let events = try FileHandle(forReadingFrom: outURL)
        defer { try? events.close() }
        var pending = Data()
        func readEvents() {
            guard let onEvent else { return }
            pending.append(events.availableData)
            while let newline = pending.firstIndex(of: 10) {
                let line = pending.prefix(upTo: newline)
                if let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { onEvent(event) }
                pending.removeSubrange(...newline)
            }
        }
        defer { try? out.close(); try? err.close() }
        let child = Process()
        child.executableURL = executable
        child.arguments = arguments
        child.currentDirectoryURL = directory
        child.environment = Self.environment()
        child.standardOutput = out; child.standardError = err
        let inputURL = ioDirectory.appendingPathComponent("input")
        try Data((input ?? "").utf8).write(to: inputURL)
        let stdin = try FileHandle(forReadingFrom: inputURL)
        defer { try? stdin.close() }
        child.standardInput = stdin
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        process = child
        do { try child.run(); lock.unlock() } catch { process = nil; lock.unlock(); throw error }
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while child.isRunning {
            readEvents()
            if Date() > deadline { timedOut = true; cancel(); break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        child.waitUntilExit()
        readEvents()
        lock.lock(); process = nil; let wasCancelled = cancelled; lock.unlock()
        if timedOut { throw AppError.message("这页翻译超过 \(Int(timeout)) 秒，已停止。可以换模型或重试。") }
        if wasCancelled { throw CancellationError() }
        return CommandResult(status: child.terminationStatus, stdout: try Data(contentsOf: outURL), stderr: try Data(contentsOf: errURL))
    }
}

final class CodexClient: Sendable {
    let executable: URL
    let workspace: URL
    let resources: URL
    let textCache: TextTranslationCache
    private let session: CodexSession
    private let memory = ReadingMemory()

    init(resources: URL, workspace: URL, textCacheDirectory: URL? = nil) throws {
        self.resources = resources; self.workspace = workspace
        textCache = try TextTranslationCache(directory: textCacheDirectory ?? workspace.appendingPathComponent("TextTranslations"))
        let choices = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex"
        ]
        guard let path = choices.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw AppError.configuration("没有找到 Codex CLI。请先安装 Codex 并使用 ChatGPT 账号登录。")
        }
        executable = URL(fileURLWithPath: path)
        session = CodexSession(executable: executable, directory: workspace)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    func shutdown() { session.shutdown() }
    func prepare() throws { try session.prepare() }

    func verifyLogin(runner: CommandRunner = CommandRunner()) throws {
        let r = try runner.run(executable: executable, arguments: ["--no-daemon", "login", "status"], directory: workspace, timeout: 20)
        let text = String(decoding: r.stdout + r.stderr, as: UTF8.self)
        guard r.status == 0, text.contains("ChatGPT") else {
            throw AppError.configuration("请先在 Codex 中登录 ChatGPT 账号，再重试。")
        }
    }

    func models() throws -> [ModelInfo] {
        try session.models()
    }

    func translate(ocr: OCRPage, options: TranslationOptions, runner: CommandRunner, force: Bool = false,
                   seed: PageTranslation? = nil,
                   progress: @escaping (String) -> Void = { _ in },
                   preview: ((PageTranslation) -> Void)? = nil) throws -> (PageTranslation, Double) {
        try runner.checkCancellation()
        if !force, let cached = textCache.lookup(ocr: ocr, options: options) {
            memory.remember(cached, scope: options.readingScope)
            progress("正在回填…")
            return (cached, 0)
        }
        let instructions = try String(contentsOf: resources.appendingPathComponent("translator.txt"), encoding: .utf8)
        let baseSchema = try JSONSerialization.jsonObject(with: Data(contentsOf: resources.appendingPathComponent("translation.schema.json"))) as! [String: Any]
        let began = Date()
        var accepted: [String: Dialogue] = [:], notes = ""
        if !force, let seed {
            for block in ocr.blocks {
                if let old = seed.dialogues.first(where: { $0.location == block.id && $0.original == block.text }),
                   TranslationReply.usable(source: block.text, translated: old.translation) {
                    let mapped = try TranslationReply(status: "ok", message: "", translations: [.init(id: block.id, text: old.translation)])
                        .resolve(ocr: OCRPage(blocks: [block], skippedCount: 0, elapsed: 0))
                    accepted[block.id] = mapped.dialogues.first
                }
            }
        }
        func page() -> PageTranslation {
            PageTranslation(summary: "", dialogues: ocr.blocks.compactMap { accepted[$0.id] }, notes: notes,
                            skippedCount: ocr.skippedCount + ocr.blocks.count - accepted.count, ocrSkippedCount: ocr.skippedCount)
        }
        let history = memory.context(scope: options.readingScope, excluding: ocr.blocks.map(\.text))
        func request(_ blocks: [OCRBlock], repair: Bool) throws -> TranslationReply {
            struct Input: Encodable { let id: String; let text: String; let kind: String?; let readingHint: String?; let uncertainFragments: [String]? }
            func inputBlock(_ block: OCRBlock) -> Input {
                return Input(id: block.id, text: block.text, kind: block.translationKind,
                             readingHint: block.readingHint,
                             uncertainFragments: block.uncertainFragments)
            }
            let input = String(decoding: try JSONEncoder().encode(blocks.map(inputBlock)), as: UTF8.self)
            var prompt = "逐条翻译为简体中文。一个 ID 对应一个气泡，译文只包含该 ID 的原文含义；不要把相邻气泡合并，也不要把有正文的气泡替换成省略号。\n"
            if !history.isEmpty { prompt += "前页文字，仅用于人名和语气参考：\n" + history + "\n" }
            if repair {
                let context = String(decoding: try JSONEncoder().encode(ocr.blocks.map(inputBlock)), as: UTF8.self)
                prompt += "本页上下文（仅供理解）：" + context + "\n以下条目需要补译或重新拆分，其他 ID 不要返回。\n"
            }
            prompt += input
            var schema = baseSchema
            var properties = schema["properties"] as! [String: Any]
            var array = properties["translations"] as! [String: Any]
            var item = array["items"] as! [String: Any]
            var fields = item["properties"] as! [String: Any]
            fields["id"] = ["type": "string", "enum": blocks.map(\.id)]
            item["properties"] = fields; array["items"] = item; properties["translations"] = array; schema["properties"] = properties
            let subset = OCRPage(blocks: blocks, skippedCount: 0, elapsed: 0)
            var lastPreview = ""
            return try session.translate(prompt: prompt, instructions: instructions, schema: schema,
                                         options: options, runner: runner) { text in
                try runner.checkCancellation()
                guard let partial = TranslationStream.preview(text, ocr: subset) else { return }
                for dialogue in partial.dialogues { accepted[dialogue.location] = dialogue }
                let fingerprint = ocr.blocks.compactMap { accepted[$0.id]?.translation }.joined(separator: "\u{0}")
                if fingerprint != lastPreview { lastPreview = fingerprint; preview?(page()) }
            }
        }
        var wanted = ocr.blocks.filter { accepted[$0.id] == nil }
        if !wanted.isEmpty {
            progress(seed == nil ? "等待译文…" : "补译 \(wanted.count) 处…")
            let reply = try request(wanted, repair: seed != nil)
            let resolved = try reply.resolve(ocr: OCRPage(blocks: wanted, skippedCount: 0, elapsed: 0), allowIncomplete: true)
            for block in wanted { accepted.removeValue(forKey: block.id) }
            for dialogue in resolved.dialogues { accepted[dialogue.location] = dialogue }
            notes = resolved.notes
            // One repair pass, including the preceding bubble when text has migrated between IDs.
            var repairIDs = Set(wanted.filter { accepted[$0.id] == nil }.map(\.id))
            for (index, block) in ocr.blocks.enumerated() where repairIDs.contains(block.id) && index > 0 {
                if reply.translations.contains(where: { $0.id == block.id && !Self.hasWords($0.text) }) {
                    repairIDs.insert(ocr.blocks[index-1].id)
                }
            }
            wanted = ocr.blocks.filter { repairIDs.contains($0.id) }
            if !wanted.isEmpty, seed == nil {
                progress("补译 \(wanted.count) 处…")
                do {
                    let repair = try request(wanted, repair: true)
                    let fixed = try repair.resolve(ocr: OCRPage(blocks: wanted, skippedCount: 0, elapsed: 0), allowIncomplete: true)
                    for dialogue in fixed.dialogues { accepted[dialogue.location] = dialogue }
                    notes = fixed.notes
                } catch is CancellationError { throw CancellationError() }
                catch { notes = error.localizedDescription }
            }
        }
        try runner.checkCancellation()
        let translation = page()
        try? textCache.save(ocr: ocr, options: options, translation: translation)
        memory.remember(translation, scope: options.readingScope)
        preview?(translation)
        return (translation, Date().timeIntervalSince(began))
    }

    private static func hasWords(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

}

private final class ReadingMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var scope = ""
    private var pages: [(sources: [String], text: String)] = []
    func context(scope: String, excluding sources: [String]) -> String {
        lock.lock(); defer { lock.unlock() }
        if self.scope != scope { self.scope = scope; pages = [] }
        return String(pages.filter { $0.sources != sources }.map(\.text).joined(separator: "\n").suffix(1400))
    }
    func remember(_ page: PageTranslation, scope: String) {
        guard !page.dialogues.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        if self.scope != scope { self.scope = scope; pages = [] }
        let sources = page.dialogues.map(\.original)
        pages.removeAll { $0.sources == sources }
        let text = page.dialogues.filter { !$0.needsReview }.map { "\($0.original) → \($0.translation)" }.joined(separator: "\n")
        guard !text.isEmpty else { return }
        pages.append((sources, String(text.prefix(900))))
        pages = Array(pages.suffix(2))
    }
}

struct TranslationReply: Codable {
    struct Item: Codable { let id: String; let text: String }
    let status: String
    let message: String
    let translations: [Item]

    static func usable(source: String, translated: String) -> Bool {
        let reading = TranslationText(translated)
        let value = reading.text
        guard !value.isEmpty else { return false }
        if !reading.gaps.isEmpty && !reading.hasReadableText { return true }
        let hasWords = { (s: String) in s.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) } }
        if hasWords(source) && !hasWords(value) { return false }
        let letters = { (s: String) in Array(s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }) }
        if letters(source) == letters(value) && source.unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) }) { return false }
        return true
    }

    func resolve(ocr: OCRPage, allowIncomplete: Bool = false) throws -> PageTranslation {
        guard status == "ok" || status == "partial" || status == "unreadable" else {
            throw AppError.message(message.isEmpty ? "模型未能翻译此页。" : "模型未翻译：" + message)
        }
        let items = status == "unreadable" && translations.isEmpty
            ? ocr.blocks.map { Item(id: $0.id, text: "□") } : translations
        let expected = Set(ocr.blocks.map(\.id)), actual = items.map(\.id)
        guard Set(actual).count == actual.count, Set(actual).isSubset(of: expected),
              allowIncomplete || status != "ok" || Set(actual) == expected,
              !items.isEmpty, items.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw AppError.message("译文与气泡未能对应，请重试。")
        }
        let mapped = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.text) })
        let dialogues = ocr.blocks.compactMap { block -> Dialogue? in
            guard let text = mapped[block.id], Self.usable(source: block.text, translated: text) else { return nil }
            return Dialogue.recognized(block, text: text)
        }
        return PageTranslation(summary: "", dialogues: dialogues, notes: message,
                               skippedCount: ocr.skippedCount + ocr.blocks.count - dialogues.count,
                               ocrSkippedCount: ocr.skippedCount)
    }
}
