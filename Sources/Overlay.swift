import AppKit
import CoreText

private final class TranslationPanel: NSPanel {
    var selecting = false
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { selecting }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }
}

enum BubbleEditAction {
    case recognize
    case translate(source: String)
    case save(source: String, translation: String)
    case restoreOriginal
}

@MainActor
final class MangaOverlay {
    private let panel: TranslationPanel
    private let canvas = TranslationCanvas()
    private let peekPanel: TranslationPanel
    private let peekLabel = NSTextField(wrappingLabelWithString: "")
    private var peekID: String?
    private var windowID: CGWindowID?
    private var processID: pid_t = 0
    private var topInset: CGFloat = 32
    private var entryID: String?
    private var tracking: Timer?
    private var sourceSize: CGSize?
    private var contentRect: CGRect = .zero
    private var wantsVisible = false
    private var needsValidation = false
    private var layoutSeconds = 0.0
    private var pageDigest: String?
    private var selecting = false
    private var selectedID: String?
    private var editor: BubbleEditor?
    private var pendingAction: BubbleEditAction?
    var onBubbleAction: ((String, BubbleEditAction) -> Void)?
    var onEditingChanged: ((Bool) -> Void)?

    init() {
        panel = TranslationPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        peekPanel = TranslationPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
        panel.title = "漫画译文"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        // The translated pixels belong immediately above their reader window,
        // including when another app has focus. They must not float over it.
        panel.level = .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.contentView = canvas
        panel.onCancel = { [weak self] in self?.endCorrection() }
        canvas.onSelect = { [weak self] id in self?.editBubble(id) }
        canvas.onCancel = { [weak self] in self?.endCorrection() }
        peekPanel.title = "临时译文"
        peekPanel.isOpaque = false; peekPanel.backgroundColor = .clear
        peekPanel.hasShadow = true; peekPanel.ignoresMouseEvents = true
        peekPanel.hidesOnDeactivate = false; peekPanel.level = .normal
        peekPanel.collectionBehavior = panel.collectionBehavior
        let background = NSVisualEffectView()
        background.material = .popover; background.state = .active
        background.wantsLayer = true; background.layer?.cornerRadius = 9
        peekPanel.contentView = background
        peekLabel.font = .systemFont(ofSize: 15)
        peekLabel.setAccessibilityLabel("临时译文")
        background.addSubview(peekLabel)
    }

    func show(_ entry: CacheEntry, page: CapturedPage, windowID: CGWindowID, processID: pid_t, topInset: CGFloat) {
        if selecting && (self.windowID != windowID || pageDigest != page.digest) { endCorrection() }
        if pageDigest != nil && pageDigest != page.digest { canvas.setCorrectionCandidates([]) }
        self.windowID = windowID; self.processID = processID; self.topInset = topInset
        pageDigest = page.digest
        let identity = entry.id + String(entry.createdAt.timeIntervalSince1970)
        if entryID != identity || contentRect != page.contentRect {
            let began = Date()
            sourceSize = page.displaySize
            contentRect = page.contentRect
            let size = contentRect.size
            panel.setContentSize(size)
            canvas.setFrameSize(size)
            canvas.setTranslation(entry.translation, image: page.image)
            entryID = identity
            layoutSeconds = Date().timeIntervalSince(began)
        }
        wantsVisible = true
        needsValidation = false
        if tracking == nil {
            tracking = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updatePosition() }
            }
        }
        updatePosition()
    }

    var isVisible: Bool { panel.isVisible }
    var isRetained: Bool { wantsVisible }
    var renderedCount: Int { canvas.items.count }
    var selectedBubbleID: String? { selectedID }
    var omittedSummary: String { canvas.omittedSummary }

    func setCorrectionCandidates(_ dialogues: [Dialogue]) { canvas.setCorrectionCandidates(dialogues) }

    @discardableResult
    func beginCorrection() -> Bool {
        guard wantsVisible, !canvas.bubbles.isEmpty else { return false }
        if selecting { editor?.showWindow(nil); return true }
        selecting = true
        panel.selecting = true
        panel.ignoresMouseEvents = false
        canvas.selecting = true
        onEditingChanged?(true)
        updatePosition()
        guard selecting, panel.isVisible else { endCorrection(); return false }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(canvas)
        return true
    }

    func endCorrection() {
        guard selecting else { return }
        selecting = false; selectedID = nil; pendingAction = nil
        editor?.onClose = nil
        editor?.close(); editor = nil
        canvas.selecting = false; canvas.selectedID = nil
        panel.selecting = false; panel.ignoresMouseEvents = true
        panel.resignKey()
        onEditingChanged?(false)
        updatePosition()
    }

    func finishBubbleAction(id: String, dialogue: Dialogue?, error: String? = nil) {
        guard selecting, selectedID == id, let editor else { return }
        let action = pendingAction
        pendingAction = nil
        if let error { editor.finish(error: error); return }
        if let dialogue { editor.update(dialogue) }
        editor.finish(error: nil)
        if case .save? = action { endCorrection() }
        if case .restoreOriginal? = action { endCorrection() }
    }

    func hide() { wantsVisible = false; endCorrection(); panel.orderOut(nil); peekPanel.orderOut(nil); tracking?.invalidate(); tracking = nil }

    func stop() { hide(); tracking?.invalidate(); tracking = nil }

    var diagnosticState: [String: Any] {
        ["requested": wantsVisible, "visible": panel.isVisible, "frame": NSStringFromRect(panel.frame),
         "target": windowID ?? 0, "targetPID": processID, "items": canvas.items.count,
         "layoutSeconds": layoutSeconds, "omissions": canvas.omittedSummary,
         "correcting": selecting, "selectedBubble": selectedID ?? "", "showingOriginal": canvas.showOriginal,
         "peekVisible": peekPanel.isVisible, "windowNumber": panel.windowNumber,
         "level": panel.level.rawValue,
         "targetForeground": windowID.map { ReaderCapture.isForeground(windowID: $0, processID: processID) } ?? false]
    }

    private func editBubble(_ id: String) {
        guard selecting, pendingAction == nil, let bubble = canvas.bubbles.first(where: { $0.dialogue.location == id }) else { return }
        selectedID = id; canvas.selectedID = id
        if editor == nil {
            let value = BubbleEditor()
            value.onClose = { [weak self] in self?.endCorrection() }
            value.onAction = { [weak self] action in
                guard let self, let selectedID = self.selectedID, let callback = self.onBubbleAction else { return }
                self.pendingAction = action
                self.editor?.begin(action)
                callback(selectedID, action)
            }
            editor = value
        }
        editor?.update(bubble.dialogue)
        let rect = bubble.rect
        let screenRect = NSRect(x: panel.frame.minX + rect.minX, y: panel.frame.maxY - rect.maxY,
                                width: rect.width, height: rect.height)
        editor?.present(near: screenRect, in: panel.frame)
    }

    private func updatePosition() {
        guard wantsVisible, let windowID,
              let windows = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let info = windows.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID }),
              (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID,
              let values = info[kCGWindowBounds as String] as? [String: Any],
              let cgFrame = CGRect(dictionaryRepresentation: values as CFDictionary),
              cgFrame.size == sourceSize,
              let primary = NSScreen.screens.first else {
            needsValidation = true; panel.orderOut(nil); peekPanel.orderOut(nil); return
        }
        // CGWindow coordinates start at the primary screen's top-left; AppKit starts at bottom-left.
        let frame = CGRect(x: cgFrame.minX + contentRect.minX,
                           y: primary.frame.maxY - cgFrame.minY - contentRect.maxY,
                           width: contentRect.width, height: contentRect.height)
        // Prepare layout even when the reader is behind another app or minimized.
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let editingForeground = selecting && frontPID == ProcessInfo.processInfo.processIdentifier
        let readerForeground = ReaderCapture.isForeground(windowID: windowID, processID: processID)
        if selecting && !readerForeground && !editingForeground {
            endCorrection(); return
        }
        let stackInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let stack = stackInfo.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue }
        guard (info[kCGWindowIsOnscreen as String] as? Bool) == true, stack.contains(Int(windowID)) else {
            needsValidation = true; panel.orderOut(nil); peekPanel.orderOut(nil); return
        }
        guard !needsValidation else { panel.orderOut(nil); peekPanel.orderOut(nil); return }
        // Read current modifiers without installing a global keyboard monitor or requesting access.
        canvas.updateModifierFlags(NSEvent.modifierFlags)
        let readerIndex = stack.firstIndex(of: Int(windowID))
        let adjacent = readerIndex.map { $0 > 0 && stack[$0-1] == panel.windowNumber } ?? false
        if !panel.isVisible || !adjacent { panel.order(.above, relativeTo: Int(windowID)) }
        updatePeek(windows: stackInfo)
    }

    private func updatePeek(windows: [[String: Any]]) {
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let pointer = NSEvent.mouseLocation
        let surfaces = windows.compactMap { window -> OverlaySurface? in
            guard let id = (window[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  let value = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: value as CFDictionary) else { return nil }
            return OverlaySurface(id: id, frame: frame, layer: (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                                  alpha: (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1)
        }
        let globalPoint = CGPoint(x: pointer.x, y: (NSScreen.screens.first?.frame.maxY ?? 0)-pointer.y)
        guard !selecting, flags.contains([.control, .shift]), flags.intersection([.command, .option]).isEmpty,
              let windowID, ReaderWindowVisibility.pointerHitsReader(globalPoint, target: Int(windowID),
                  surfaces: surfaces, ignoring: [panel.windowNumber, peekPanel.windowNumber]),
              panel.isVisible, panel.frame.contains(pointer),
              let dialogue = canvas.dialogue(at: CGPoint(x: pointer.x-panel.frame.minX, y: panel.frame.maxY-pointer.y)),
              !dialogue.translation.isEmpty else {
            peekPanel.orderOut(nil); peekID = nil; return
        }
        // Pointer peeks are also tied to the reader's position in the window
        // stack. A foreground app covers the card and still receives all input.
        let identity = dialogue.location + dialogue.original + dialogue.translation
        if peekID != identity {
            let value = NSMutableAttributedString(string: String(dialogue.original.prefix(180)) + "\n\n",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
            value.append(NSAttributedString(string: String(dialogue.translation.prefix(700)),
                attributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor]))
            peekLabel.attributedStringValue = value; peekID = identity
        }
        let width: CGFloat = min(300, max(180, panel.frame.width-24))
        let height = min(320, ceil(peekLabel.attributedStringValue.boundingRect(
            with: CGSize(width: width-24, height: 1000), options: [.usesLineFragmentOrigin, .usesFontLeading]).height)+24)
        var rect = CGRect(x: pointer.x+14, y: pointer.y-height-12, width: width, height: height)
        let available = panel.frame.intersection(panel.screen?.visibleFrame ?? panel.frame).insetBy(dx: 8, dy: 8)
        rect.origin.x = max(available.minX, min(rect.minX, available.maxX-width))
        rect.origin.y = max(available.minY, min(rect.minY, available.maxY-height))
        peekPanel.setFrame(rect, display: true)
        peekLabel.frame = CGRect(x: 12, y: 12, width: width-24, height: height-24)
        peekPanel.order(.above, relativeTo: panel.windowNumber)
    }
}

@MainActor
private final class BubbleEditor: NSWindowController, NSWindowDelegate {
    private let source = NSTextView()
    private let translation = NSTextView()
    private let status = NSTextField(labelWithString: "")
    private var buttons: [NSButton] = []
    var onAction: ((BubbleEditAction) -> Void)?
    var onClose: (() -> Void)?

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 354),
                            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "修正气泡"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: panel)
        panel.delegate = self
        let content = NSStackView()
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(content)
        if let root = panel.contentView {
            NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                                         content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                                         content.topAnchor.constraint(equalTo: root.topAnchor),
                                         content.bottomAnchor.constraint(equalTo: root.bottomAnchor)])
        }
        for (title, view, buttonTitle, selector) in [
            ("原文", source, "重新识别", #selector(recognize)),
            ("译文", translation, "重新翻译", #selector(retranslate))
        ] {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12, weight: .medium)
            let action = button(buttonTitle, selector)
            action.controlSize = .small
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let row = NSStackView(views: [label, spacer, action])
            row.orientation = .horizontal; row.alignment = .centerY
            content.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -28).isActive = true
            let scroll = NSScrollView()
            scroll.borderType = .bezelBorder; scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true; scroll.drawsBackground = true
            view.isRichText = false; view.importsGraphics = false
            view.allowsUndo = true
            view.isAutomaticQuoteSubstitutionEnabled = false
            view.isAutomaticDashSubstitutionEnabled = false
            view.isAutomaticTextReplacementEnabled = false
            view.font = .systemFont(ofSize: 14)
            view.textContainerInset = NSSize(width: 6, height: 7)
            view.isVerticallyResizable = true; view.isHorizontallyResizable = false
            view.autoresizingMask = [.width]
            view.textContainer?.widthTracksTextView = true
            view.setAccessibilityLabel(title)
            scroll.documentView = view
            content.addArrangedSubview(scroll)
            NSLayoutConstraint.activate([scroll.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -28),
                                         scroll.heightAnchor.constraint(equalToConstant: 90)])
        }
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        content.addArrangedSubview(status)
        status.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -28).isActive = true
        status.heightAnchor.constraint(equalToConstant: 15).isActive = true
        let restore = button("恢复原图", #selector(restore))
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        let done = button("完成", #selector(save))
        done.keyEquivalent = "\r"
        let spacer = NSView()
        let actions = NSStackView(views: [restore, spacer, cancel, done])
        actions.orientation = .horizontal; actions.spacing = 7
        content.addArrangedSubview(actions)
        actions.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -28).isActive = true
        panel.setContentSize(NSSize(width: 340, height: content.fittingSize.height))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let value = NSButton(title: title, target: self, action: action)
        value.bezelStyle = .rounded
        buttons.append(value)
        return value
    }

    func update(_ dialogue: Dialogue) {
        source.string = dialogue.original
        translation.string = dialogue.translation
        source.undoManager?.removeAllActions()
        translation.undoManager?.removeAllActions()
        status.stringValue = ""
    }

    func present(near bubble: NSRect, in reader: NSRect) {
        guard let window else { return }
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(bubble) }) ?? NSScreen.main
        let available = screen?.visibleFrame ?? reader
        let width = window.frame.width, height = window.frame.height
        // Prefer beside the chosen bubble, falling back to the opposite side of the reader.
        var x = bubble.maxX + 12
        if x + width > available.maxX { x = bubble.minX - width - 12 }
        x = max(available.minX + 8, min(x, available.maxX - width - 8))
        let y = max(available.minY + 8, min(bubble.maxY - height, available.maxY - height - 8))
        window.setFrameOrigin(NSPoint(x: x, y: y))
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(source)
    }

    func begin(_ action: BubbleEditAction) {
        buttons.forEach { $0.isEnabled = false }
        source.isEditable = false; translation.isEditable = false
        switch action {
        case .recognize: status.stringValue = "重新识别…"
        case .translate: status.stringValue = "翻译中…"
        case .save, .restoreOriginal: status.stringValue = "保存中…"
        }
        status.textColor = .secondaryLabelColor
    }

    func finish(error: String?) {
        buttons.forEach { $0.isEnabled = true }
        source.isEditable = true; translation.isEditable = true
        status.stringValue = error ?? ""
        status.toolTip = error
        status.textColor = error == nil ? .secondaryLabelColor : .systemRed
    }

    func windowWillClose(_ notification: Notification) { onClose?() }
    @objc private func recognize() { onAction?(.recognize) }
    @objc private func retranslate() { onAction?(.translate(source: source.string)) }
    @objc private func restore() { onAction?(.restoreOriginal) }
    @objc private func save() { onAction?(.save(source: source.string, translation: translation.string)) }
    @objc private func cancel() { close() }
}

@MainActor
final class TranslationCanvas: NSView {
    enum Omission: String, CaseIterable {
        case bounds = "位置不完整"
        case length = "气泡空间不足"
        case background = "未能擦除原文"
        case open = "保留原图"
    }
    struct Item {
        let rect: CGRect
        let mask: NSImage
        let texts: [FittedText]
    }
    struct Bubble {
        let dialogue: Dialogue
        let rect: CGRect
    }
    var items: [Item] = []
    var bubbles: [Bubble] = []
    var selecting = false { didSet { hoverID = nil; needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    var selectedID: String? { didSet { needsDisplay = true } }
    private(set) var showOriginal = false { didSet { if oldValue != showOriginal { needsDisplay = true } } }
    var onSelect: ((String) -> Void)?
    var onCancel: (() -> Void)?
    private var hoverID: String? { didSet { if oldValue != hoverID { needsDisplay = true } } }
    private var trackingArea: NSTrackingArea?
    private var correctionCandidates: [Dialogue] = []
    private var translatedDialogues: [Dialogue] = []
    private var omissions: [Omission: Int] = [:]
    private var sourceImage: CGImage?
    private var cachedItems: [String: Item] = [:]
    var omittedSummary: String {
        Omission.allCases.compactMap { reason in omissions[reason].map { "\(reason.rawValue) \($0) 处" } }.joined(separator: "、")
    }
    func setTranslation(_ translation: PageTranslation, image: CGImage) {
        let size = CGSize(width: image.width, height: image.height)
        if sourceImage !== image { cachedItems = [:]; sourceImage = image }
        items = []; omissions = [:]
        translatedDialogues = translation.dialogues
        rebuildBubbles()
        var activeKeys = Set<String>()
        for dialogue in translation.dialogues {
            // A completely unreadable balloon must keep its original pixels and bounds.
            if dialogue.preserveOriginal == true { continue }
            guard dialogue.replacementAllowed != false else { omissions[.open, default: 0] += 1; continue }
            guard let imageRect = dialogue.bounds?.rect(in: size),
                  let rect = dialogue.bounds?.rect(in: bounds.size) else { omissions[.bounds, default: 0] += 1; continue }
            let textRect = dialogue.layoutBounds?.rect(in: bounds.size) ?? rect
            let regions = dialogue.layoutRegions?.compactMap { $0.rect(in: bounds.size) } ?? [textRect]
            // A local correction or late OCR refinement can change the patch without changing its text.
            let key = "\(dialogue.location)|\(dialogue.translation)|\(rect)|\(regions)|\(bounds.size)|\(dialogue.replacementPNG?.hashValue ?? 0)|\(dialogue.fontSize ?? 0)|\(dialogue.textStyle ?? "")|\(dialogue.vertical ?? false)|\(dialogue.uncertainRanges ?? [])"
            activeKeys.insert(key)
            if let item = cachedItems[key] { items.append(item); continue }
            let fontSize = dialogue.fontSize.map { CGFloat($0) * bounds.height / 1000 }
            guard let texts = FittedText.flow(dialogue.translation, regions: regions.map { $0.insetBy(dx: 1, dy: 1) },
                                            style: dialogue.textStyle, vertical: dialogue.vertical ?? false, maxFontSize: fontSize,
                                            gaps: dialogue.uncertainRanges ?? []) else {
                omissions[.length, default: 0] += 1; continue
            }
            let patch = dialogue.replacementPNG.flatMap { NSImage(data: $0) }
            let legacyMask = patch == nil && dialogue.textStyle == nil ? BubbleCover.make(image: image, rect: imageRect) : nil
            guard let mask = patch ?? legacyMask.map({ NSImage(cgImage: $0, size: imageRect.size) }) else {
                omissions[.background, default: 0] += 1; continue
            }
            let item = Item(rect: rect, mask: mask, texts: texts)
            items.append(item); cachedItems[key] = item
        }
        cachedItems = cachedItems.filter { activeKeys.contains($0.key) }
        needsDisplay = true
    }
    func setCorrectionCandidates(_ dialogues: [Dialogue]) {
        let unchanged = dialogues.count == correctionCandidates.count && zip(dialogues, correctionCandidates).allSatisfy {
            $0.location == $1.location && $0.original == $1.original && $0.translation == $1.translation
                && $0.bounds?.rect(in: CGSize(width: 1000, height: 1000)) == $1.bounds?.rect(in: CGSize(width: 1000, height: 1000))
        }
        correctionCandidates = dialogues
        guard !unchanged else { return }
        rebuildBubbles()
        if selecting { needsDisplay = true }
    }
    private func rebuildBubbles() {
        let translated = Set(translatedDialogues.map(\.location))
        let dialogues = translatedDialogues + correctionCandidates.filter { !translated.contains($0.location) }
        bubbles = dialogues.compactMap { dialogue in
            dialogue.bounds?.rect(in: bounds.size).map { Bubble(dialogue: dialogue, rect: $0) }
        }
    }
    override var acceptsFirstResponder: Bool { selecting }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { selecting }
    override func resetCursorRects() {
        if selecting { addCursorRect(bounds, cursor: .crosshair) }
    }
    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); trackingArea = area
        super.updateTrackingAreas()
    }
    private func bubble(at point: CGPoint) -> Bubble? {
        bubbles.filter { $0.rect.insetBy(dx: -4, dy: -4).contains(point) }
            .min { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }
    }
    func dialogue(at point: CGPoint) -> Dialogue? { bubble(at: point)?.dialogue }
    override func mouseMoved(with event: NSEvent) {
        if selecting { hoverID = bubble(at: convert(event.locationInWindow, from: nil))?.dialogue.location }
    }
    override func mouseExited(with event: NSEvent) { hoverID = nil }
    override func mouseDown(with event: NSEvent) {
        guard selecting else { return }
        if let bubble = bubble(at: convert(event.locationInWindow, from: nil)) { onSelect?(bubble.dialogue.location) }
        else { onCancel?() }
    }
    override func rightMouseDown(with event: NSEvent) { mouseDown(with: event) }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }
    func updateModifierFlags(_ flags: NSEvent.ModifierFlags) { showOriginal = flags.contains(.option) }
    override func flagsChanged(with event: NSEvent) { updateModifierFlags(event.modifierFlags) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill(); dirtyRect.fill(using: .copy)
        if !showOriginal {
            for item in items {
                item.mask.draw(in: item.rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            // Erasure patches may overlap, but must never erase an already drawn translation.
            for item in items { for text in item.texts { text.draw() } }
        }
        if selecting {
            for bubble in bubbles {
                let active = bubble.dialogue.location == selectedID || bubble.dialogue.location == hoverID
                let path = NSBezierPath(roundedRect: bubble.rect.insetBy(dx: -3, dy: -3), xRadius: 5, yRadius: 5)
                NSColor.controlAccentColor.withAlphaComponent(active ? 0.10 : 0.035).setFill(); path.fill()
                NSColor.controlAccentColor.withAlphaComponent(active ? 0.95 : 0.40).setStroke()
                path.lineWidth = active ? 2 : 1; path.stroke()
            }
        }
    }
}

// Do not erase the source if the complete translation cannot fit legibly.
@MainActor
struct FittedText {
    let frame: CTFrame
    let origin: CGPoint
    let height: CGFloat
    let clipRect: CGRect?

    init(frame: CTFrame, origin: CGPoint, height: CGFloat, clipRect: CGRect? = nil) {
        self.frame = frame; self.origin = origin; self.height = height; self.clipRect = clipRect
    }

    func draw() {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState(); defer { context.restoreGState() }
        if let clipRect { context.clip(to: clipRect) }
        context.textMatrix = .identity
        context.translateBy(x: origin.x, y: origin.y + height)
        context.scaleBy(x: 1, y: -1)
        CTFrameDraw(frame, context)
    }

    static func flow(_ text: String, regions: [CGRect], style: String?, vertical: Bool,
                     maxFontSize: CGFloat?, gaps: [TextGap] = []) -> [FittedText]? {
        let display = displayText(text, gaps: gaps)
        return flowPrepared(display.text, regions: regions, style: style, vertical: vertical,
                            maxFontSize: maxFontSize, gaps: display.gaps)
    }

    private static let punctuationSpacing = try! NSRegularExpression(pattern: "(?<=[。．…])[\\p{Zs}\\t]+(?=[．…])")

    // Remove only horizontal spacing inside CJK dot sequences, without editing cached text.
    // Positions are UTF-16 offsets, matching TextGap and Core Text even after emoji.
    static func displayText(_ text: String, gaps: [TextGap]) -> (text: String, gaps: [TextGap]) {
        let length = text.utf16.count
        let removed = punctuationSpacing.matches(in: text, range: NSRange(location: 0, length: length)).map(\.range)
        guard !removed.isEmpty else { return (text, gaps) }
        let value = NSMutableString(string: text)
        for range in removed.reversed() { value.deleteCharacters(in: range) }
        func offset(_ position: Int) -> Int {
            let position = min(length, max(0, position))
            return position - removed.reduce(0) { total, range in
                total + max(0, min(position, NSMaxRange(range)) - range.location)
            }
        }
        let mapped = gaps.compactMap { gap -> TextGap? in
            let start = offset(gap.location), end = offset(gap.location + gap.length)
            return end > start ? TextGap(location: start, length: end-start) : nil
        }
        return (value as String, mapped)
    }

    private static func flowPrepared(_ text: String, regions: [CGRect], style: String?, vertical: Bool,
                                     maxFontSize: CGFloat?, gaps: [TextGap]) -> [FittedText]? {
        guard !regions.isEmpty else { return nil }
        if regions.count == 1 || text.count < regions.count*3 {
            return make(text, rect: regions[0], style: style, vertical: vertical, maxFontSize: maxFontSize, gaps: gaps).map { [$0] }
        }
        let characters = Array(text), area = regions.reduce(CGFloat.zero) { $0 + $1.width*$1.height }
        func part(_ range: Range<Int>, in rect: CGRect) -> FittedText? {
            let value = String(characters[range]), offset = String(characters[..<range.lowerBound]).utf16.count
            let local = gaps.compactMap { $0.within(offset: offset, length: value.utf16.count) }
            return make(value, rect: rect, style: style, vertical: vertical, maxFontSize: maxFontSize, gaps: local)
        }
        if regions.count == 2 {
            let ideal = max(2, min(characters.count-2, Int(round(CGFloat(characters.count)*regions[0].width*regions[0].height/area))))
            let punctuation: Set<Character> = ["，", "。", "！", "？", "；", "、"]
            let cuts = (2...characters.count-2).sorted {
                let a = abs($0-ideal) - (punctuation.contains(characters[$0-1]) ? 2 : 0)
                let b = abs($1-ideal) - (punctuation.contains(characters[$1-1]) ? 2 : 0)
                return a == b ? $0 < $1 : a < b
            }
            for cut in cuts {
                if let first = part(0..<cut, in: regions[0]), let second = part(cut..<characters.count, in: regions[1]) {
                    return [first, second]
                }
            }
            return vertical ? flowPrepared(text, regions: regions, style: style, vertical: false, maxFontSize: maxFontSize, gaps: gaps) : nil
        }
        var start = 0, result: [FittedText] = []
        for (index, region) in regions.enumerated() {
            var end = index == regions.count-1 ? characters.count : min(characters.count-(regions.count-index-1)*2,
                start+max(2, Int(round(CGFloat(characters.count)*region.width*region.height/area))))
            if index < regions.count-1 {
                let punctuation: Set<Character> = ["，", "。", "！", "？", "；", "、"]
                let lower = max(start+2, end-3), upper = min(characters.count-2, end+4)
                if lower < upper, let split = (lower..<upper).first(where: { punctuation.contains(characters[$0-1]) }) { end = split }
            }
            guard end > start, let fitted = part(start..<end, in: region) else { return nil }
            result.append(fitted); start = end
        }
        return result
    }

    static func make(_ text: String, rect: CGRect, style: String? = nil,
                     vertical: Bool = false, maxFontSize: CGFloat? = nil, gaps: [TextGap] = []) -> FittedText? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, rect.width >= 8, rect.height >= 8 else { return nil }
        let trimOffset = (text as NSString).range(of: value).location
        let visibleGaps = gaps.compactMap { $0.within(offset: trimOffset, length: value.utf16.count) }
        let latinCount = value.unicodeScalars.filter { (65...90).contains($0.value) || (97...122).contains($0.value) }.count
        let vertical = vertical && !(latinCount >= 6 && latinCount * 2 > value.count)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center; paragraph.lineBreakMode = latinCount >= 6 ? .byWordWrapping : .byCharWrapping; paragraph.lineSpacing = 1
        let frameAttributes: [CFString: Any] = vertical ? [kCTFrameProgressionAttributeName: CTFrameProgression.rightToLeft.rawValue] : [:]
        let maximum = min(max(12, maxFontSize ?? 18), style == nil ? 22 : 40)
        let minimum: CGFloat = style == nil ? 7 : 8
        var size = maximum
        while true {
            let string = attributedText(value, size: size, style: style, vertical: vertical,
                                        paragraph: paragraph, gaps: visibleGaps)
            let setter = CTFramesetterCreateWithAttributedString(string)
            func frame(_ box: CGRect) -> CTFrame {
                CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: box, transform: nil), frameAttributes as CFDictionary)
            }
            var box = CGRect(origin: .zero, size: rect.size), fitted = frame(CGRect(origin: .zero, size: rect.size))
            if CTFrameGetVisibleStringRange(fitted).length == string.length {
                let lines = CTFrameGetLines(fitted) as! [CTLine]
                let extent = min(vertical ? rect.width : rect.height, CGFloat(lines.count) * (size * 1.22 + 1))
                if vertical { box.size.width = extent } else { box.size.height = extent }
                let centered = frame(box)
                if CTFrameGetVisibleStringRange(centered).length == string.length { fitted = centered }
                else { box.size = rect.size }
                return FittedText(frame: fitted, origin: CGPoint(x: rect.minX+(rect.width-box.width)/2,
                    y: rect.minY+(rect.height-box.height)/2), height: box.height)
            }
            if size == minimum { break }
            size = max(minimum, size - 0.5)
        }
        if vertical { return make(text, rect: rect, style: style, vertical: false, maxFontSize: maxFontSize, gaps: gaps) }
        return compactHorizontal(value, rect: rect, style: style, maximum: maximum, minimum: minimum,
                                 lineBreakMode: paragraph.lineBreakMode, gaps: visibleGaps)
    }

    private static func attributedText(_ value: String, size: CGFloat, style: String?, vertical: Bool,
                                       paragraph: NSParagraphStyle, gaps: [TextGap]) -> NSAttributedString {
        let color = style == "outlinedLight" ? NSColor.white : NSColor.black
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("PingFangSC-Medium" as CFString, size, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
            NSAttributedString.Key(kCTVerticalFormsAttributeName as String): vertical,
            .paragraphStyle: paragraph]
        if style != nil {
            attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = (style == "outlinedLight" ? NSColor.black : NSColor.white).cgColor
            attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = -2
        }
        let string = NSMutableAttributedString(string: value, attributes: attributes)
        for gap in gaps {
            string.addAttributes([
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("PingFangSC-Regular" as CFString, max(6, size*0.72), nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor(white: style == "outlinedLight" ? 0.72 : 0.48, alpha: 1).cgColor
            ], range: gap.range)
        }
        return string
    }

    // Short annotations can fit their ink while Core Text's default leading does not.
    // Retry only failed horizontal layouts, retaining the same region and font floor.
    private static func compactHorizontal(_ value: String, rect: CGRect, style: String?, maximum: CGFloat,
                                          minimum: CGFloat, lineBreakMode: NSLineBreakMode, gaps: [TextGap]) -> FittedText? {
        func fit(_ size: CGFloat) -> FittedText? {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center; paragraph.lineBreakMode = lineBreakMode
            paragraph.minimumLineHeight = size * 1.05
            paragraph.maximumLineHeight = size * 1.05
            let string = attributedText(value, size: size, style: style, vertical: false, paragraph: paragraph, gaps: gaps)
            // Extra frame height admits the font's top/bottom leading; it never enlarges the safe drawing region.
            let height = rect.height + size * 3
            let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(string), CFRange(location: 0, length: 0),
                CGPath(rect: CGRect(x: 0, y: 0, width: rect.width, height: height), transform: nil), nil)
            if CTFrameGetVisibleStringRange(frame).length == string.length,
               let ink = compactInkBounds(frame, stroke: style == nil ? 0 : size * 0.01),
               ink.width <= rect.width, ink.height <= rect.height {
                return FittedText(frame: frame, origin: CGPoint(x: rect.midX - ink.midX,
                    y: rect.midY + ink.midY - height), height: height, clipRect: rect)
            }
            return nil
        }
        // A failed minimum-size layout cannot be rescued by enlarging the same text.
        // In particular, do not repeat the whole search at every two-region split.
        guard let smallest = fit(minimum) else { return nil }
        var size = floor(maximum * 2) / 2
        while size > minimum {
            if let fitted = fit(size) { return fitted }
            size -= 0.5
        }
        return smallest
    }

    private static func compactInkBounds(_ frame: CTFrame, stroke: CGFloat) -> CGRect? {
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        var union = CGRect.null, previous = CGRect.null
        for (line, origin) in zip(lines, origins) {
            // Bitmap/color glyphs do not have reliable path bounds; leave those to the regular layout.
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                if let font = attributes[kCTFontAttributeName] {
                    let traits = CTFontGetSymbolicTraits(font as! CTFont)
                    if traits.contains(.traitColorGlyphs) { return nil }
                }
            }
            let path = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            guard !path.isNull else { continue }
            let ink = path.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -stroke, dy: -stroke)
            if !previous.isNull, previous.minY - ink.maxY < 0.25 { return nil }
            previous = ink; union = union.union(ink)
        }
        return union.isNull || union.isEmpty ? nil : union
    }
}

enum BubbleCover {
    static func make(image: CGImage, rect: CGRect) -> CGImage? {
        guard let crop = image.cropping(to: rect.integral) else { return nil }
        let width = crop.width, height = crop.height, count = width * height
        guard width > 4, height > 4 else { return nil }
        var gray = [UInt8](repeating: 0, count: count)
        gray.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        // A text box extending into artwork is not a safe replacement region.
        guard Double(gray.filter { $0 > 230 }.count) / Double(count) > 0.70 else { return nil }
        var protected = [Bool](repeating: false, count: count), queue: [Int] = []
        var borderWhite = 0, borderCount = 0
        for y in 0..<height {
            for x in 0..<width where x == 0 || y == 0 || x == width - 1 || y == height - 1 {
                let i = y * width + x; borderCount += 1
                if gray[i] > 230 { borderWhite += 1 }
                if gray[i] < 235 { protected[i] = true; queue.append(i) }
            }
        }
        guard Double(borderWhite) / Double(borderCount) > 0.80 else { return nil }
        var head = 0
        while head < queue.count {
            let i = queue[head]; head += 1; let x = i % width, y = i / width
            for yy in max(0, y - 1)...min(height - 1, y + 1) {
                for xx in max(0, x - 1)...min(width - 1, x + 1) {
                    let j = yy * width + xx
                    if !protected[j] && gray[j] < 235 { protected[j] = true; queue.append(j) }
                }
            }
        }
        var rgba = [UInt8](repeating: 0, count: count * 4)
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                guard gray[i] < 245, !protected[i] else { continue }
                for yy in (y - 1)...(y + 1) {
                    for xx in (x - 1)...(x + 1) {
                        let j = yy * width + xx
                        if !protected[j] { for c in 0..<4 { rgba[j * 4 + c] = 255 } }
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

@MainActor
enum OverlayPreview {
    static func render(_ translation: PageTranslation, image: CGImage, destination: URL, scale: CGFloat = 2) throws -> Int {
        let canvas = TranslationCanvas(frame: CGRect(x: 0, y: 0, width: CGFloat(image.width)/scale, height: CGFloat(image.height)/scale))
        canvas.setTranslation(translation, image: image)
        guard let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { throw AppError.message("无法生成回填预览") }
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: 0, space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let foreground = bitmap.cgImage else { throw AppError.message("无法合成回填预览") }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(image, in: rect); context.draw(foreground, in: rect)
        guard let composite = context.makeImage() else { throw AppError.message("无法生成回填预览") }
        try NSBitmapImageRep(cgImage: composite).representation(using: .png, properties: [:])!.write(to: destination)
        if !canvas.omittedSummary.isEmpty { fputs(canvas.omittedSummary + "\n", stderr) }
        return canvas.items.count
    }
}
