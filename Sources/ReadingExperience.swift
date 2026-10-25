import AppKit
import CryptoKit
import Foundation

struct OverlaySurface {
    let id: Int
    let frame: CGRect
    let layer: Int
    let alpha: Double
}

enum ReaderWindowVisibility {
    static func pointerHitsReader(_ point: CGPoint, target: Int, surfaces: [OverlaySurface], ignoring: Set<Int>) -> Bool {
        surfaces.first { !ignoring.contains($0.id) && $0.layer >= 0 && $0.alpha > 0.01 && $0.frame.contains(point) }?.id == target
    }
}

struct WorkTerm: Codable, Equatable, Sendable {
    var source: String
    var translation: String
}

struct WorkProfile: Codable, Equatable {
    var id: String
    var title: String
    var style = ""
    var terms: [WorkTerm] = []

    var guidance: String {
        let vocabulary = terms.map { "\($0.source) → \($0.translation)" }.joined(separator: "\n")
        return [style.isEmpty ? "" : "本作品的翻译习惯：\n" + style,
                vocabulary.isEmpty ? "" : "本作品已确认的用词，匹配原文时优先沿用：\n" + vocabulary]
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    mutating func learn(_ dialogue: Dialogue) {
        let source = dialogue.original.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = dialogue.translation.trimmingCharacters(in: .whitespacesAndNewlines)
        // Short, explicitly corrected text can be a name or recurring phrase.
        // Long sentences and uncertain OCR never become forced substitutions.
        guard dialogue.userEdited == true, dialogue.preserveOriginal != true, !dialogue.needsReview,
              !source.isEmpty, !target.isEmpty, source.count <= 20, target.count <= 30,
              !source.contains("\n"), !target.contains("\n") else { return }
        terms.removeAll { $0.source == source }
        terms.append(WorkTerm(source: source, translation: target))
        terms = Array(terms.suffix(100))
    }

    static func validatedTerms(_ entries: [WorkTerm]) throws -> [WorkTerm] {
        var result: [WorkTerm] = []
        for entry in entries {
            let source = entry.source.trimmingCharacters(in: .whitespacesAndNewlines)
            let translation = entry.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            if source.isEmpty && translation.isEmpty { continue }
            guard !source.isEmpty, !translation.isEmpty else { throw AppError.message("请补全原文和译名。") }
            guard source.count <= 100, translation.count <= 150 else { throw AppError.message("词条过长，请简短填写。") }
            result.removeAll { $0.source == source }
            result.append(WorkTerm(source: source, translation: translation))
        }
        guard result.count <= 100 else { throw AppError.message("最多添加 100 条。") }
        return result
    }

    static func parseTerms(_ text: String) throws -> [WorkTerm] {
        let entries = try text.components(separatedBy: .newlines).compactMap { line -> WorkTerm? in
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { return nil }
            guard let divider = value.range(of: "=") else { throw AppError.message("请补全原文和译名。") }
            return WorkTerm(source: String(value[..<divider.lowerBound]), translation: String(value[divider.upperBound...]))
        }
        return try validatedTerms(entries)
    }

}

@MainActor
final class WorkProfileStore {
    private struct State: Codable {
        var profiles: [String: WorkProfile] = [:]
        var documents: [String: String] = [:]
    }
    private let file: URL
    private var state: State

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        file = directory.appendingPathComponent("WorkProfiles.json")
        if FileManager.default.fileExists(atPath: file.path) {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
        } else { state = State() }
    }

    var profiles: [WorkProfile] { state.profiles.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }
    private func key(_ context: String) -> String {
        SHA256.hash(data: Data(context.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func resolve(context: String, title: String) throws -> WorkProfile {
        let document = key(context)
        if let id = state.documents[document], let profile = state.profiles[id] { return profile }
        let profile = WorkProfile(id: "work:" + document, title: String(title.prefix(180)))
        state.profiles[profile.id] = profile; state.documents[document] = profile.id
        try persist()
        return profile
    }

    func save(_ profile: WorkProfile, context: String? = nil) throws {
        var value = profile
        value.title = String(value.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(180))
        guard !value.title.isEmpty else { throw AppError.message("请填写作品名称。") }
        state.profiles[value.id] = value
        if let context { state.documents[key(context)] = value.id }
        try persist()
    }

    func profile(id: String) -> WorkProfile? { state.profiles[id] }
    private func persist() throws {
        try JSONEncoder().encode(state).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

// Google has no instruction channel. Protect matched glossary words in the
// request, then restore them before anything reaches a cache or a text layer.
struct GlossaryPlan {
    let text: String
    private let replacements: [(token: String, translation: String)]

    init(source: String, terms: [WorkTerm]) {
        let text = NSMutableString(string: source)
        var replacements: [(String, String)] = [], tokens: [String: String] = [:]
        let marker = "SHIORI" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        let vocabulary = Dictionary(terms.filter { !$0.source.isEmpty }.map { ($0.source, $0.translation) }, uniquingKeysWith: { _, last in last })
        let pattern = vocabulary.keys.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern).joined(separator: "|")
        if !pattern.isEmpty, let regex = try? NSRegularExpression(pattern: pattern) {
            // Match the original once, so an English term cannot match inside
            // a placeholder inserted for an earlier Japanese name.
            for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
                let original = (source as NSString).substring(with: match.range)
                let token = tokens[original] ?? marker + "TERM" + String(replacements.count) + "Q"
                if tokens[original] == nil {
                    tokens[original] = token; replacements.append((token, vocabulary[original]!))
                }
                text.replaceCharacters(in: match.range, with: token)
            }
        }
        self.text = text as String; self.replacements = replacements
    }

    func restore(_ translated: String) throws -> String {
        var result = translated
        for replacement in replacements {
            // Some engines insert spaces between ASCII letters or change case.
            let pattern = replacement.token.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s*")
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  !regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).isEmpty else {
                throw AppError.message("本页用词未能保留，请重试，或使用 Codex 翻译。")
            }
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                    withTemplate: NSRegularExpression.escapedTemplate(for: replacement.translation))
        }
        return result
    }
}

struct CorrectionSnapshot {
    let translation: PageTranslation
    let profile: WorkProfile?
}

struct CorrectionHistory {
    private(set) var page = ""
    private var backward: [CorrectionSnapshot] = []
    private var forward: [CorrectionSnapshot] = []
    var canUndo: Bool { !backward.isEmpty }
    var canRedo: Bool { !forward.isEmpty }
    mutating func select(_ digest: String) {
        if page != digest { page = digest; backward = []; forward = [] }
    }
    mutating func record(_ previous: CorrectionSnapshot, page: String) {
        select(page); backward.append(previous); backward = Array(backward.suffix(12)); forward = []
    }
    mutating func undo(current: CorrectionSnapshot, page: String) -> CorrectionSnapshot? {
        guard self.page == page, let value = backward.popLast() else { return nil }
        forward.append(current); return value
    }
    mutating func redo(current: CorrectionSnapshot, page: String) -> CorrectionSnapshot? {
        guard self.page == page, let value = forward.popLast() else { return nil }
        backward.append(current); return value
    }
}

struct ReleaseVersion: Comparable {
    let parts: [Int]
    init?(_ value: String) {
        let text = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let segments = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...4).contains(segments.count), segments.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              segments.allSatisfy({ Int($0) != nil }) else { return nil }
        parts = segments.map { Int($0)! }
    }
    static func == (a: Self, b: Self) -> Bool { !(a < b) && !(b < a) }
    static func < (a: Self, b: Self) -> Bool {
        for index in 0..<max(a.parts.count, b.parts.count) {
            let x = index < a.parts.count ? a.parts[index] : 0
            let y = index < b.parts.count ? b.parts[index] : 0
            if x != y { return x < y }
        }
        return false
    }
}
