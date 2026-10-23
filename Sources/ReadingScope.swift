import Foundation

enum ReadingScopeError: LocalizedError {
    case changed
    var errorDescription: String? { "等待原阅读页面…" }
}

// A reading session belongs to one window and one document. Browser pagination
// may change a page number, but changing sites or chapters starts a new session.
struct ReadingScope: Equatable {
    let windowID: UInt32
    let document: String?

    init(windowID: UInt32, documentURL: URL?) {
        self.windowID = windowID
        document = documentURL.map(Self.documentKey)
    }

    static func documentKey(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        parts.user = nil; parts.password = nil
        let host = parts.host?.lowercased() ?? ""
        parts.host = host
        let segments = parts.path.split(separator: "/").map(String.init)
        // Each E-Hentai image has a different image key and page suffix. Keep
        // the gallery ID, which does not change when moving between its pages.
        if ["e-hentai.org", "exhentai.org"].contains(host), segments.count == 3,
           segments[0] == "s", let gallery = segments[2].split(separator: "-").first,
           !gallery.isEmpty, gallery.allSatisfy(\.isNumber) {
            parts.path = "/gallery/" + gallery; parts.query = nil; parts.fragment = nil
        } else if ["shonenjumpplus.com", "tonarinoyj.jp", "comic-days.com", "comic-action.com"].contains(host),
                  segments.first == "episode" {
            parts.fragment = nil
            let pagination = Set(["page"])
            parts.queryItems = parts.queryItems?.filter { !pagination.contains($0.name.lowercased()) }
            if parts.queryItems?.isEmpty == true { parts.query = nil }
        }
        // Unknown sites keep query and fragment. For example ?p=123 can be a
        // different article, and #/chapter/2 can be a different SPA document.
        return parts.string ?? url.absoluteString
    }

    func accepts(windowID: UInt32, documentURL: URL?) -> Bool {
        guard self.windowID == windowID else { return false }
        // A temporarily missing URL must not authorize an unrelated webpage.
        return document == documentURL.map(Self.documentKey)
    }
}
