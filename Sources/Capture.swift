import AppKit
import ScreenCaptureKit
import ApplicationServices

enum BrowserContent {
    struct Region { let rect: CGRect; let toolbarEditing: Bool; let documentURL: URL? }
    private static let viewportLock = NSLock()
    static func isBrowser(_ identity: String?) -> Bool {
        guard let identity else { return false }
        return ["com.google.Chrome", "com.apple.Safari", "com.microsoft.edgemac", "com.brave.Browser",
                "company.thebrowser.Browser", "org.mozilla.firefox"].contains(identity)
    }

    static var hasAccess: Bool { AXIsProcessTrusted() }
    static func requestAccess() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    // Read the viewport and document identity, never the document's text. The
    // URL is used in memory to keep automatic reading on the selected document.
    static func isToolbarEditor(role: String?, frame: CGRect?, viewport: CGRect) -> Bool {
        guard ["AXTextField", "AXComboBox"].contains(role ?? ""), let frame else { return false }
        let overlap = frame.intersection(viewport)
        return overlap.isNull || overlap.width * overlap.height < frame.width * frame.height * 0.5
    }

    static func viewport(processID: pid_t, windowFrame: CGRect) -> Region? {
        viewportLock.lock(); defer { viewportLock.unlock() }
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, 0.25)
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var result: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
        }
        func frame(_ element: AXUIElement) -> CGRect? {
            guard let p = attribute(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
                  let s = attribute(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
            var position = CGPoint.zero, size = CGSize.zero
            guard AXValueGetValue(p as! AXValue, .cgPoint, &position),
                  AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
            return CGRect(origin: position, size: size)
        }
        func region(_ element: AXUIElement) -> Region? {
            if (attribute(element, "AXHidden") as? Bool) == true { return nil }
            guard let web = frame(element) else { return nil }
            let rect = web.intersection(windowFrame)
            guard !rect.isNull, rect.width >= windowFrame.width * 0.4, rect.height >= 100 else { return nil }
            var editing = false
            if let focused = attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() {
                let element = focused as! AXUIElement
                editing = isToolbarEditor(role: attribute(element, kAXRoleAttribute) as? String,
                                          frame: frame(element), viewport: rect)
            }
            let rawURL = attribute(element, kAXURLAttribute)
            let url = (rawURL as? URL) ?? (rawURL as? String).flatMap(URL.init(string:))
            return Region(rect: rect.offsetBy(dx: -windowFrame.minX, dy: -windowFrame.minY), toolbarEditing: editing, documentURL: url)
        }
        guard let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement],
              let window = windows.first(where: {
                  guard let f = frame($0) else { return false }
                  return abs(f.minX-windowFrame.minX) < 3 && abs(f.minY-windowFrame.minY) < 3
                      && abs(f.width-windowFrame.width) < 3 && abs(f.height-windowFrame.height) < 3
              }) else { return nil }
        var queue: [(AXUIElement, Int)] = [(window, 0)], index = 0
        while index < queue.count && index < 160 {
            let (element, depth) = queue[index]; index += 1
            let role = attribute(element, kAXRoleAttribute) as? String
            if role == "AXWebArea" {
                if let result = region(element) {
                    return result
                }
                continue
            }
            if depth < 12, queue.count < 160, let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                queue.append(contentsOf: children.prefix(160-queue.count).map { ($0, depth+1) })
            }
        }
        return nil
    }

    static func crop(_ image: CGImage, displaySize: CGSize, viewport: CGRect) throws -> CapturedPage {
        let scaleX = CGFloat(image.width) / displaySize.width, scaleY = CGFloat(image.height) / displaySize.height
        // Round inward so a fractional boundary cannot retain a row of toolbar pixels.
        let left = ceil(viewport.minX * scaleX), top = ceil(viewport.minY * scaleY)
        let pixels = CGRect(x: left, y: top, width: floor(viewport.maxX * scaleX)-left,
                            height: floor(viewport.maxY * scaleY)-top)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !pixels.isNull, !pixels.isEmpty, let cropped = image.cropping(to: pixels) else {
            throw AppError.message("等待网页内容…")
        }
        let content = CGRect(x: pixels.minX / scaleX, y: pixels.minY / scaleY,
                             width: pixels.width / scaleX, height: pixels.height / scaleY)
        return try CapturedPage(image: cropped, displaySize: displaySize, contentRect: content)
    }
}

struct CaptureSource {
    let processID: pid_t
    let title: String
    let identity: String

    var application: NSRunningApplication? { NSRunningApplication(processIdentifier: processID) }

    static func running() -> [CaptureSource] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated
                && $0.bundleIdentifier != Bundle.main.bundleIdentifier
                && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }.map {
            CaptureSource(processID: $0.processIdentifier, title: $0.localizedName ?? "未命名软件",
                          identity: $0.bundleIdentifier ?? $0.bundleURL?.path ?? String($0.processIdentifier))
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

@MainActor
final class ReaderCapture {
    var source: CaptureSource? {
        didSet {
            if oldValue?.processID != source?.processID {
                revision += 1; windows = []; selectedID = nil; endReading()
            }
        }
    }
    private var revision = 0
    private(set) var windows: [SCWindow] = []
    private(set) var topInset: CGFloat = 0
    private(set) var selectedID: CGWindowID?
    private(set) var contextKey = ""
    private(set) var readingScope: ReadingScope?
    private var reading = false

    func beginReading() { reading = true; readingScope = nil; revision += 1 }
    func endReading() { reading = false; readingScope = nil }

    func refresh() async throws -> [SCWindow] {
        guard let source, source.application?.isTerminated == false else {
            throw AppError.message("请从「软件」中选择已打开的软件。")
        }
        let revision = revision
        guard CGPreflightScreenCaptureAccess() else {
            throw AppError.configuration("需要屏幕录制权限")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard revision == self.revision else { throw CancellationError() }
        windows = content.windows.filter {
            $0.owningApplication?.processID == source.processID && $0.windowLayer == 0
                && $0.frame.width > 200 && $0.frame.height > 200
        }.sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
        let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let order = onScreen.compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        windows.sort { (order.firstIndex(of: $0.windowID) ?? .max) < (order.firstIndex(of: $1.windowID) ?? .max) }
        guard !windows.isEmpty else { selectedID = nil; throw AppError.message("请展开\(source.title)的窗口。") }
        selectedID = windows[0].windowID
        return windows
    }

    func capture(maxDimension: CGFloat = 2600) async throws -> CapturedPage {
        let revision = revision
        let target = Self.visibleWindowID(processID: source?.processID ?? 0)
        if let scope = readingScope, target != scope.windowID { throw ReadingScopeError.changed }
        if selectedID != target || !windows.contains(where: { $0.windowID == target }) {
            _ = try await refresh()
        }
        guard let window = windows.first(where: { $0.windowID == selectedID }),
              let frame = Self.frame(windowID: window.windowID) else {
            throw AppError.message("请展开阅读软件的窗口。")
        }
        var viewport = CGRect(origin: .zero, size: frame.size)
        var documentURL: URL?
        if BrowserContent.isBrowser(source?.identity) {
            guard BrowserContent.hasAccess else { throw AppError.configuration("请允许辅助功能后开始阅读。") }
            let processID = source!.processID
            guard let web = await Task.detached(priority: .userInitiated, operation: {
                BrowserContent.viewport(processID: processID, windowFrame: frame)
            }).value else { throw AppError.message("等待网页内容…") }
            // Address suggestions are drawn over the webpage in Chrome. Keep the
            // current page while typing, then resume detection when focus returns.
            guard !web.toolbarEditing else { throw CancellationError() }
            viewport = web.rect
            documentURL = web.documentURL
            if reading, documentURL == nil { throw AppError.message("等待网页地址…") }
        }
        if let scope = readingScope, !scope.accepts(windowID: window.windowID, documentURL: documentURL) {
            throw ReadingScopeError.changed
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = min(2.0, maxDimension / max(frame.width, frame.height))
        configuration.width = max(1, Int(frame.width * scale))
        configuration.height = max(1, Int(frame.height * scale))
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.ignoreShadowsSingleWindow = true
        let full = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard revision == self.revision, selectedID == window.windowID,
              Self.visibleWindowID(processID: source?.processID ?? 0) == window.windowID,
              Self.frame(windowID: window.windowID)?.size == frame.size else { throw CancellationError() }
        if BrowserContent.isBrowser(source?.identity), let source {
            let after = await Task.detached(priority: .userInitiated) {
                BrowserContent.viewport(processID: source.processID, windowFrame: frame)
            }.value
            guard revision == self.revision, let after, !after.toolbarEditing, after.rect == viewport else { throw CancellationError() }
            guard documentURL.map(ReadingScope.documentKey) == after.documentURL.map(ReadingScope.documentKey) else {
                throw ReadingScopeError.changed
            }
        }
        topInset = 0
        if reading, readingScope == nil { readingScope = ReadingScope(windowID: window.windowID, documentURL: documentURL) }
        let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], window.windowID) as? [[String: Any]])?.first
        contextKey = (source?.identity ?? "") + "|" + (info?[kCGWindowName as String] as? String ?? window.title ?? "")
        // Hashing/encoding large screenshots must not occupy AppKit's main thread.
        let content = viewport
        return try await Task.detached(priority: .userInitiated) {
            try BrowserContent.crop(full, displaySize: frame.size, viewport: content)
        }.value
    }

    static func frame(windowID: CGWindowID) -> CGRect? {
        guard let windows = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let values = windows.first?[kCGWindowBounds as String] as? [String: Any] else { return nil }
        return CGRect(dictionaryRepresentation: values as CFDictionary)
    }

    static func isForeground(windowID: CGWindowID, processID: pid_t) -> Bool {
        frontmostWindowID(processID: processID) == windowID
    }

    static func frontmostWindowID(processID: pid_t) -> CGWindowID? {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processID else { return nil }
        return visibleWindowID(processID: processID)
    }

    static func visibleWindowID(processID: pid_t) -> CGWindowID? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let front = windows.first {
            guard ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID,
                  ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  ($0[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let values = $0[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: values as CFDictionary) else { return false }
            return frame.width > 200 && frame.height > 200
        }
        return (front?[kCGWindowNumber as String] as? NSNumber)?.uint32Value
    }
}
