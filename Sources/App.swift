import AppKit
import CoreGraphics

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, NSMenuItemValidation {
    private var window: NSWindow!
    private let popover = NSPopover()
    private var applications: [CaptureSource] = []
    private var sourceActions: NSMenu!
    private var modelBox: NSPopUpButton!
    private var effortBox: NSPopUpButton!
    private var sourceBox: NSPopUpButton!
    private var providerBox: NSPopUpButton!
    private var modelRow: NSView!
    private var effortRow: NSView!
    private var autoButton: NSButton!
    private var overlayButton: NSButton!
    private var translateButton: NSButton!
    private var statusLabel: NSTextField!
    private var detailLabel: NSTextField!
    private var spinner: NSProgressIndicator!
    private var statusDot: NSImageView!
    private var statusItem: NSStatusItem!
    private var client: CodexClient?
    private var google: GoogleTranslationClient?
    private var cache: TranslationCache?
    private var ocr: LocalOCR?
    private var requestDigest: String?
    private var pageFailure: (digest: String, message: String)?
    private let translationGroup = DispatchGroup()
    private let capture = ReaderCapture()
    private let overlay = MangaOverlay()
    private var models: [ModelInfo] = []
    private var trackingSelectionMenus = Set<ObjectIdentifier>()
    private var pendingModelCatalog: [ModelInfo]?
    private var pendingApplicationRefresh = false
    private var timer: Timer?
    private var modelTimer: Timer?
    private var timerStatus: Timer?
    private var tracker = PageTracker()
    private var probeTracker = PageTracker()
    private var lastProbeDigest: String?
    private var settlingProbe: Task<Void, Never>?
    private var didConfirmCandidate = false
    private var probeCaptures = 0
    private var fullCaptures = 0
    private var latestPage: CapturedPage?
    private var shownEntry: CacheEntry?
    private var runner: CommandRunner?
    private var requestID: UUID?
    private var captureBusy = false
    private var startTime: Date?
    private var refreshingModels = false
    private var modelError: String?
    private var statusText = "选择软件"
    private var statusIsError = false
    private var operationEpoch = 0
    private var isCorrectingBubble = false
    private var correctionRunner: CommandRunner?
    private var correctionID: UUID?
    private var correctionCandidates: (digest: String, dialogues: [Dialogue])?
    private let defaults = UserDefaults.standard

    private func migratePreviousSettings() {
        guard Bundle.main.bundleIdentifier == "local.sai.Shiori" else { return }
        if !defaults.bool(forKey: "didMigrateSettings") {
            let previous = defaults.persistentDomain(forName: "local.sai.KedaTranslate") ?? [:]
            let current = defaults.persistentDomain(forName: "local.sai.Shiori") ?? [:]
            defaults.setPersistentDomain(previous.merging(current) { _, currentValue in currentValue }, forName: "local.sai.Shiori")
            defaults.set(true, forKey: "didMigrateSettings")
        }
        if let previous = defaults.persistentDomain(forName: "local.sai.KedaTranslate"), !previous.isEmpty {
            defaults.removePersistentDomain(forName: "local.sai.KedaTranslate")
        }
        defaults.removeObject(forKey: "didMigrateKedaSettings")
        defaults.removeObject(forKey: "NSWindow Frame KedaTranslateMain")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        migratePreviousSettings()
        buildMenu(); buildWindow(); buildStatusMenu()
        overlay.onBubbleAction = { [weak self] id, action in self?.correctBubble(id: id, action: action) }
        overlay.onEditingChanged = { [weak self] editing in
            guard let self else { return }
            self.isCorrectingBubble = editing
            if editing {
                self.settlingProbe?.cancel(); self.settlingProbe = nil
                self.setStatus("点选要修正的气泡")
            } else {
                self.correctionRunner?.cancel(); self.correctionRunner = nil; self.correctionID = nil
                self.settlingProbe?.cancel(); self.settlingProbe = nil; self.didConfirmCandidate = false
                self.probeTracker.reset(); self.lastProbeDigest = nil
                // Revalidate the underlying reader before showing any edited
                // snapshot: the user may have scrolled while the editor was open.
                self.overlay.hide()
                if self.shownEntry != nil { self.setStatus("正在检查新页面…") }
            }
        }
        do {
            let support = try AppStorage.directory()
            cache = try TranslationCache(directory: support.appendingPathComponent("Translations"))
            google = try GoogleTranslationClient(cacheDirectory: support.appendingPathComponent("GoogleTranslations"), concurrency: 6)
            ocr = try LocalOCR(support: support, resources: Bundle.main.resourceURL!)
            if let ocr { DispatchQueue.global(qos: .utility).async { try? ocr.prepare() } }
            do {
                client = try CodexClient(resources: Bundle.main.resourceURL!, workspace: support.appendingPathComponent("Jobs"),
                                        textCacheDirectory: support.appendingPathComponent("TextTranslations"))
                if options.provider == .codex, let client { DispatchQueue.global(qos: .utility).async { try? client.prepare() } }
            } catch { modelError = error.localizedDescription }
            if let data = defaults.data(forKey: "modelCatalog"),
               let saved = try? JSONDecoder().decode([ModelInfo].self, from: data), !saved.isEmpty {
                applyModels(saved)
            }
            if models.isEmpty, options.provider == .codex { refreshModels() }
            let refresh = Timer(fire: Date(timeIntervalSinceNow: models.isEmpty ? 24 * 60 * 60 : 5),
                                interval: 24 * 60 * 60, repeats: true) { [weak self] _ in
                Task { @MainActor in if self?.options.provider == .codex { self?.refreshModels() } }
            }
            modelTimer = refresh; RunLoop.main.add(refresh, forMode: .common)
        } catch { setStatus(error.localizedDescription, error: true) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
        updateProviderUI(); showSettings(); refreshSources()
    }

    func renderPanel(to destination: URL, dark: Bool = false, provider: TranslationProvider? = nil) throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        NSApplication.shared.appearance = appearance
        migratePreviousSettings()
        buildWindow(); refreshApplications()
        if let provider { providerBox.selectItem(at: provider == .google ? 0 : 1) }
        if let data = defaults.data(forKey: "modelCatalog"),
           let saved = try? JSONDecoder().decode([ModelInfo].self, from: data), !saved.isEmpty { applyModels(saved) }
        updateProviderUI(); setStatus("就绪")
        let view = popover.contentViewController!.view
        view.appearance = appearance
        view.setFrameSize(popover.contentSize); view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw AppError.message("Cannot render panel") }
        appearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        stopWork(); timer?.invalidate(); modelTimer?.invalidate(); overlay.stop()
        _ = translationGroup.wait(timeout: .now() + 4)
        client?.shutdown()
        google?.shutdown()
        ocr?.shutdown()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(); return true
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { sender.orderOut(nil); return false }

    private func buildMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "退出 Shiori", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); editItem.title = "编辑"; menu.addItem(editItem)
        let edit = NSMenu(title: "编辑"); editItem.submenu = edit
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = menu
    }

    private func buildStatusMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = ""
        statusItem.button?.toolTip = "Shiori"
        statusItem.button?.image = ShioriIcon.menuImage()
        statusItem.button?.setAccessibilityLabel("Shiori")
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.target = self; statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        sourceActions = NSMenu(); sourceActions.delegate = self
        rebuildSourceActions(sourceActions)
        (sourceBox as? PanelPopUpButton)?.contextActions = sourceActions
    }
    private func rebuildSourceActions(_ menu: NSMenu) {
        menu.removeAllItems()
        if (shownEntry?.translation.untranslatedCount ?? 0) > 0 {
            menu.addItem(withTitle: "补齐译文", action: #selector(translateCurrent), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "重新翻译", action: #selector(retranslate), keyEquivalent: "").target = self
        menu.addItem(withTitle: "重新识字", action: #selector(rerecognize), keyEquivalent: "").target = self
        let correction = menu.addItem(withTitle: "修正气泡…", action: #selector(editBubble), keyEquivalent: "")
        correction.target = self
        correction.toolTip = "点选气泡后可修改原文和译文。阅读时按住 ⌥ 查看原图。"
        menu.addItem(withTitle: "复制译文", action: #selector(copyTranslation), keyEquivalent: "").target = self
        menu.addItem(withTitle: "返回阅读窗口", action: #selector(showReader), keyEquivalent: "").target = self
        let needsScreen = !CGPreflightScreenCaptureAccess()
        let needsBrowser = BrowserContent.isBrowser(capture.source?.identity) && !BrowserContent.hasAccess
        if needsScreen || needsBrowser {
            menu.addItem(.separator())
            if needsScreen { menu.addItem(withTitle: "授权屏幕录制…", action: #selector(openPermissions), keyEquivalent: "").target = self }
            if needsBrowser { menu.addItem(withTitle: "授权辅助功能…", action: #selector(openAccessibility), keyEquivalent: "").target = self }
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Shiori", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
    }

    private func label(_ text: String, color: NSColor = .secondaryLabelColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 12); field.textColor = color
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .horizontal
        stack.alignment = .centerY; stack.spacing = 8
        return stack
    }

    private func buildWindow() {
        let controller = NSViewController()
        let panelSize = NSSize(width: 240, height: 270)
        let background = PanelCanvas(frame: NSRect(origin: .zero, size: panelSize))
        controller.view = background
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 8
        root.translatesAutoresizingMaskIntoConstraints = false; background.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            root.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            root.topAnchor.constraint(equalTo: background.topAnchor, constant: 12),
            root.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -12)
        ])
        func add(_ view: NSView) {
            root.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
        sourceBox = PanelPopUpButton(showsIcon: true); sourceBox.addItem(withTitle: "选择软件")
        sourceBox.target = self; sourceBox.action = #selector(sourceChanged); sourceBox.menu?.delegate = self
        sourceBox.setAccessibilityLabel("软件")
        providerBox = PanelPopUpButton(); providerBox.addItems(withTitles: ["Google", "Codex"])
        providerBox.item(at: 0)?.representedObject = "google"
        providerBox.item(at: 1)?.representedObject = "codex"
        providerBox.selectItem(at: defaults.string(forKey: "translationProvider") == "google" ? 0 : 1)
        providerBox.target = self; providerBox.action = #selector(providerChanged); providerBox.menu?.delegate = self
        providerBox.setAccessibilityLabel("翻译服务")
        modelBox = PanelPopUpButton()
        modelBox.addItem(withTitle: defaults.string(forKey: "selectedModel") ?? "gpt-6.1-sol")
        modelBox.target = self; modelBox.action = #selector(optionsChanged); modelBox.isEnabled = false
        modelBox.menu?.delegate = self; modelBox.setAccessibilityLabel("翻译模型")
        effortBox = PanelPopUpButton(); effortBox.addItems(withTitles: ["low", "medium", "high", "xhigh", "max"])
        effortBox.selectItem(withTitle: defaults.string(forKey: "effort") ?? "low")
        effortBox.target = self; effortBox.action = #selector(optionsChanged); effortBox.setAccessibilityLabel("推理")
        effortBox.menu?.delegate = self
        let fields = NSStackView()
        fields.orientation = .vertical; fields.alignment = .leading; fields.spacing = 0
        fields.detachesHiddenViews = true
        for (caption, control) in [("软件", sourceBox!), ("翻译", providerBox!), ("模型", modelBox!), ("推理", effortBox!)] {
            let name = label(caption); name.font = .systemFont(ofSize: 11)
            name.widthAnchor.constraint(equalToConstant: 24).isActive = true
            let field = row([name, control]); field.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 0)
            fields.addArrangedSubview(field)
            control.heightAnchor.constraint(equalToConstant: 28).isActive = true
            control.widthAnchor.constraint(equalTo: field.widthAnchor, constant: -42).isActive = true
            field.heightAnchor.constraint(equalToConstant: 34).isActive = true
            field.widthAnchor.constraint(equalTo: fields.widthAnchor).isActive = true
            if control === modelBox { modelRow = field }
            if control === effortBox { effortRow = field }
        }
        let fieldGroup = PanelGroup(rows: fields)
        fieldGroup.addSubview(fields); fields.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            fields.leadingAnchor.constraint(equalTo: fieldGroup.leadingAnchor),
            fields.trailingAnchor.constraint(equalTo: fieldGroup.trailingAnchor, constant: -4),
            fields.topAnchor.constraint(equalTo: fieldGroup.topAnchor, constant: 3),
            fields.bottomAnchor.constraint(equalTo: fieldGroup.bottomAnchor, constant: -3)
        ])
        add(fieldGroup)
        autoButton = NSButton(checkboxWithTitle: "自动翻译", target: self, action: #selector(toggleAuto))
        overlayButton = NSButton(checkboxWithTitle: "显示译文", target: self, action: #selector(toggleOverlay))
        overlayButton.toolTip = "按住 ⌥ 临时查看原图；右键 Shiori 图标可修正气泡。"
        for toggle in [autoButton!, overlayButton!] {
            toggle.font = .systemFont(ofSize: 11); toggle.controlSize = .small
            toggle.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        overlayButton.state = defaults.object(forKey: "showOverlay") as? Bool == false ? .off : .on
        let toggles = row([autoButton, overlayButton]); toggles.distribution = .fillEqually; toggles.spacing = 6
        toggles.heightAnchor.constraint(equalToConstant: 24).isActive = true; add(toggles)
        let action = PanelActionButton(frame: .zero)
        action.title = "开始阅读"; action.target = self; action.action = #selector(startReading)
        action.active = false; translateButton = action
        translateButton.keyEquivalent = "\r"
        translateButton.heightAnchor.constraint(equalToConstant: 34).isActive = true; add(translateButton)
        spinner = NSProgressIndicator(); spinner.style = .spinning; spinner.controlSize = .mini
        spinner.isDisplayedWhenStopped = false; spinner.isHidden = true
        spinner.widthAnchor.constraint(equalToConstant: 10).isActive = true
        statusDot = NSImageView(image: NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)!)
        statusDot.setAccessibilityElement(false)
        statusDot.contentTintColor = PanelPalette.accent; statusDot.widthAnchor.constraint(equalToConstant: 5).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 5).isActive = true
        statusLabel = label("选择软件"); statusLabel.maximumNumberOfLines = 1; statusLabel.font = .systemFont(ofSize: 10.5)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detailLabel = label(""); detailLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        detailLabel.maximumNumberOfLines = 1
        detailLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let statusRow = row([statusDot, spinner, statusLabel, detailLabel]); statusRow.spacing = 5
        statusRow.heightAnchor.constraint(equalToConstant: 22).isActive = true; add(statusRow)
        popover.contentViewController = controller; popover.contentSize = panelSize; popover.behavior = .transient
    }
    @objc private func statusItemClicked() {
        if let event = NSApp.currentEvent,
           event.type == .rightMouseUp || event.modifierFlags.contains(.control),
           let button = statusItem.button {
            popover.performClose(nil)
            sourceActions.appearance = NSApp.effectiveAppearance
            statusItem.menu = sourceActions
            button.performClick(nil)
        } else {
            togglePanel()
        }
    }
    @objc private func togglePanel() { if popover.isShown { popover.performClose(nil) } else { showSettings() } }
    @objc private func showSettings() {
        refreshApplications()
        guard let button = statusItem?.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        window = popover.contentViewController?.view.window
        NSApp.activate(ignoringOtherApps: true); window?.makeKey()
    }
    @objc private func showReader() {
        guard let reader = capture.source?.application else { return }
        popover.performClose(nil); reader.activate(options: [])
    }
    @objc private func startReading() {
        if runner != nil || autoButton.state == .on { stopClicked(); return }
        guard capture.source != nil else { setStatus("请先选择软件", error: true); return }
        guard translationAvailable else { setStatus("请先加载可用模型", error: true); return }
        autoButton.state = .on; toggleAuto()
    }
    private var options: TranslationOptions {
        let provider = TranslationProvider(rawValue: providerBox?.selectedItem?.representedObject as? String ?? "codex") ?? .codex
        return TranslationOptions(model: provider == .google ? "google-translate" : modelBox.titleOfSelectedItem ?? "",
                                  effort: provider == .google ? "none" : effortBox.titleOfSelectedItem ?? "low",
                                  context: capture.contextKey, provider: provider)
    }
    private var translationAvailable: Bool {
        options.provider == .google ? google != nil : client != nil && models.contains(where: { $0.slug == options.model })
    }
    private func updateProviderUI() {
        let codex = options.provider == .codex
        modelRow.isHidden = !codex; effortRow.isHidden = !codex
        popover.contentSize = NSSize(width: 240, height: codex ? 270 : 202)
        popover.contentViewController?.view.layoutSubtreeIfNeeded()
        updateStatus()
    }
    @objc private func providerChanged() {
        defaults.set(options.provider.rawValue, forKey: "translationProvider")
        operationEpoch += 1; cancelTranslation(); resetTracking(); shownEntry = nil; overlay.hide()
        detailLabel.stringValue = ""
        updateProviderUI()
        if options.provider == .codex, models.isEmpty { refreshModels() }
        setStatus(autoButton.state == .on ? "等待翻译…" : "就绪")
    }
    private func setStatus(_ text: String, error: Bool = false) {
        statusText = text; statusIsError = error; updateStatus()
    }
    private func updateStatus() {
        var text = statusText, error = statusIsError
        if !error, runner == nil, options.provider == .codex {
            if let modelError { text = modelError; error = true }
            else if refreshingModels, models.isEmpty { text = "正在加载模型…" }
        }
        statusLabel.stringValue = text; statusLabel.textColor = error ? .systemRed : .secondaryLabelColor
        statusDot?.contentTintColor = error ? .systemOrange : runner != nil ? PanelActionButton.accent : .tertiaryLabelColor
        statusDot?.isHidden = runner != nil
        statusLabel.toolTip = text
        let active = runner != nil || autoButton?.state == .on
        let title = runner != nil ? "停止翻译" : active ? "暂停翻译" : "开始阅读"
        translateButton.title = title
        (translateButton as? PanelActionButton)?.active = active
        translateButton.setAccessibilityLabel(title)
    }

    @objc private func refreshModels() {
        guard let client, !refreshingModels else { return }
        refreshingModels = true; modelError = nil; updateStatus()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try client.models() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshingModels = false
                switch result {
                case .success(let models):
                    self.applyModels(models)
                    if !models.isEmpty, let data = try? JSONEncoder().encode(models) {
                        self.defaults.set(data, forKey: "modelCatalog")
                    }
                case .failure(let error):
                    // An unavailable catalog refresh must not disable a saved model.
                    self.modelBox.toolTip = error.localizedDescription
                    if self.models.isEmpty || (error as? AppError)?.needsUserAction == true {
                        self.modelError = error.localizedDescription
                    }
                }
                self.updateStatus()
            }
        }
    }
    private func applyModels(_ catalog: [ModelInfo]) {
        guard trackingSelectionMenus.isEmpty else { pendingModelCatalog = catalog; return }
        let old = options
        models = catalog
        let previousModel = modelBox.titleOfSelectedItem ?? defaults.string(forKey: "selectedModel") ?? ""
        modelBox.removeAllItems(); modelBox.addItems(withTitles: catalog.map(\.slug))
        modelBox.selectItem(withTitle: previousModel)
        if modelBox.indexOfSelectedItem < 0, !catalog.isEmpty { modelBox.selectItem(at: 0) }
        modelBox.isEnabled = !catalog.isEmpty; modelBox.toolTip = nil
        modelError = catalog.isEmpty ? "账号没有可用模型" : nil
        updateEfforts()
        if old != options { optionsChanged() }
    }
    private func updateEfforts() {
        let selected = effortBox.titleOfSelectedItem ?? "low"
        let supported = models.first(where: { $0.slug == modelBox.titleOfSelectedItem })?.supported_reasoning_levels?.map(\.effort)
             ?? ["low", "medium", "high"]
        let levels = supported.isEmpty ? ["low"] : supported
        guard effortBox.itemTitles != levels else { return }
        effortBox.removeAllItems(); effortBox.addItems(withTitles: levels)
        effortBox.selectItem(withTitle: selected)
        if effortBox.indexOfSelectedItem < 0 { effortBox.selectItem(at: 0) }
    }
    @objc private func optionsChanged() {
        operationEpoch += 1; updateEfforts()
        defaults.set(modelBox.titleOfSelectedItem, forKey: "selectedModel"); defaults.set(effortBox.titleOfSelectedItem, forKey: "effort")
        cancelTranslation(); resetTracking(); overlay.hide()
        detailLabel.stringValue = ""
        shownEntry = nil
        setStatus(autoButton.state == .on ? "等待翻译…" : "就绪")
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(editBubble) {
            return runner == nil && !captureBusy && correctionRunner == nil && shownEntry != nil && latestPage != nil
        }
        if item.action == #selector(translateCurrent) || item.action == #selector(retranslate) || item.action == #selector(rerecognize) {
            return runner == nil && !captureBusy && !isCorrectingBubble && capture.source != nil && translationAvailable
        }
        if item.action == #selector(stopClicked) { return runner != nil || autoButton.state == .on }
        if item.action == #selector(copyTranslation) { return shownEntry != nil }
        if item.action == #selector(showReader) { return capture.source != nil }
        return true
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === sourceActions {
            menu.appearance = NSApp.effectiveAppearance
            rebuildSourceActions(menu)
        } else if menu === sourceBox.menu {
            // Update before AppKit computes menu geometry or starts tracking.
            refreshApplications()
        }
    }
    func menuWillOpen(_ menu: NSMenu) {
        if [sourceBox, providerBox, modelBox, effortBox].compactMap({ $0 }).contains(where: { $0.menu === menu }) {
            trackingSelectionMenus.insert(ObjectIdentifier(menu))
        }
    }
    func menuDidClose(_ menu: NSMenu) {
        if menu === sourceActions {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.statusItem.menu === menu else { return }
                self.statusItem.menu = nil
            }
            return
        }
        guard trackingSelectionMenus.remove(ObjectIdentifier(menu)) != nil else { return }
        // Menu tracking and the selected item's action must both finish before
        // an asynchronous catalog or application refresh can replace items.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.trackingSelectionMenus.isEmpty else { return }
            if let catalog = self.pendingModelCatalog {
                self.pendingModelCatalog = nil
                self.applyModels(catalog)
            }
            if self.pendingApplicationRefresh {
                self.pendingApplicationRefresh = false
                self.refreshApplications()
            }
        }
    }
    private func refreshApplications() {
        guard trackingSelectionMenus.isEmpty else { pendingApplicationRefresh = true; return }
        let running = CaptureSource.running()
        let legacy = defaults.string(forKey: "captureSource") == "chrome" ? "com.google.Chrome" : "com.xiaogd.kedamanga"
        let preferred = defaults.string(forKey: "captureApplication") ?? legacy
        let selected = running.first { $0.processID == capture.source?.processID } ?? running.first { $0.identity == preferred }
        let items = sourceBox.itemArray.dropFirst()
        let unchanged = items.count == running.count && zip(items, running).allSatisfy { item, app in
            item.representedObject as? pid_t == app.processID && item.title == app.title
        }
        applications = running
        if selected?.processID != capture.source?.processID {
            stopWork(); capture.source = selected; latestPage = nil; shownEntry = nil; overlay.hide()
        }
        if !unchanged {
            sourceBox.removeAllItems(); sourceBox.addItem(withTitle: "选择软件"); sourceBox.item(at: 0)?.isEnabled = false
            for app in applications {
                // Distinct processes can have the same display name. Adding the
                // menu item directly preserves each process and its stable ID.
                let item = NSMenuItem(title: app.title, action: nil, keyEquivalent: "")
                item.representedObject = app.processID
                if let icon = app.application?.icon?.copy() as? NSImage { icon.size = NSSize(width: 16, height: 16); item.image = icon }
                sourceBox.menu?.addItem(item)
            }
        }
        let index = selected.flatMap { source in sourceBox.itemArray.firstIndex { $0.representedObject as? pid_t == source.processID } } ?? 0
        if sourceBox.indexOfSelectedItem != index { sourceBox.selectItem(at: index) }
    }
    @objc private func refreshSources() { refreshApplications(); connectReader() }
    @objc private func connectReader() {
        stopWork(); let epoch = operationEpoch
        guard capture.source != nil else { setStatus("选择软件"); return }
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.capture.refresh()
                guard self.operationEpoch == epoch else { return }
                self.setStatus("就绪")
            } catch { if self.operationEpoch == epoch { self.setStatus(error.localizedDescription, error: true) } }
        }
    }
    @objc private func sourceChanged() {
        guard let pid = sourceBox.selectedItem?.representedObject as? pid_t,
              let app = applications.first(where: { $0.processID == pid }) else { return }
        stopWork(); overlay.hide(); latestPage = nil; shownEntry = nil; capture.source = app
        defaults.set(app.identity, forKey: "captureApplication")
        connectReader()
    }
    @objc private func translateCurrent() { captureAndTranslate(force: false) }
    @objc private func retranslate() { captureAndTranslate(force: true) }
    @objc private func rerecognize() { captureAndTranslate(force: true, refreshOCR: true) }
    private func captureAndTranslate(force: Bool, refreshOCR: Bool = false) {
        guard !captureBusy, runner == nil, ensureCaptureAccess() else { return }
        window?.makeFirstResponder(nil); capture.beginReading(); captureBusy = true
        let epoch = operationEpoch; setStatus("正在读取页面…")
        Task { [weak self] in
            guard let self else { return }
            defer { self.captureBusy = false }
            do {
                let page = try await self.capture.capture()
                guard self.operationEpoch == epoch else { return }
                self.tracker.adopt(page); self.latestPage = page; self.shownEntry = nil; self.updateOverlay()
                self.submit(page, force: force, refreshOCR: refreshOCR); self.showReader()
            } catch { if self.operationEpoch == epoch { self.setStatus(error.localizedDescription, error: true) } }
        }
    }
    @objc private func toggleAuto() {
        if autoButton.state == .on {
            guard capture.source != nil, translationAvailable else {
                stopWork(); setStatus(capture.source == nil ? "请先选择软件" : "请先加载可用模型", error: true); return
            }
            guard ensureCaptureAccess() else { stopWork(); return }
            window?.makeFirstResponder(nil); capture.beginReading(); resetTracking(); setStatus("自动翻译已开启")
            showReader(); Task { await poll() }
        } else { stopWork(); setStatus("已暂停") }
    }
    @objc private func toggleOverlay() {
        defaults.set(overlayButton.state == .on, forKey: "showOverlay")
        if let entry = shownEntry, runner == nil { show(entry, cached: true) } else { updateOverlay() }
    }

    private func poll() async {
        defer {
            if defaults.bool(forKey: "diagnostics") {
                let state: [String: Any] = ["auto": autoButton.state == .on, "busy": captureBusy,
                    "running": runner != nil, "source": capture.source?.identity ?? "", "applications": applications.map(\.title), "status": statusLabel.stringValue, "target": capture.selectedID ?? 0,
                    "foreground": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "", "overlay": overlay.diagnosticState,
                    "page": latestPage?.digest ?? "", "request": requestDigest ?? "", "settling": tracker.isSettling,
                    "viewport": latestPage.map { NSStringFromRect($0.contentRect) } ?? "",
                    "timings": shownEntry?.timings?.diagnosticState ?? [:],
                    "captures": ["probe": probeCaptures, "full": fullCaptures]]
                if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: "/private/tmp/Shiori-diagnostics.json"), options: .atomic)
                }
            }
        }
        if isCorrectingBubble { await validateCorrectionPage(); return }
        guard correctionRunner == nil, !captureBusy,
              autoButton.state == .on || runner != nil || shownEntry != nil else { return }
        guard let source = capture.source else { return }
        guard source.application?.isTerminated == false else { stopWork(); overlay.hide(); refreshApplications(); setStatus("阅读软件已关闭"); return }
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard foreground == source.processID else {
            overlay.hide()
            // Opening our own panel must not interrupt a translation already
            // requested. Other applications suspend reading without taking screenshots.
            if foreground != ProcessInfo.processInfo.processIdentifier {
                suspendReading("等待阅读窗口…")
            }
            return
        }
        guard let visibleWindow = ReaderCapture.visibleWindowID(processID: source.processID) else {
            suspendReading("等待阅读窗口…")
            return
        }
        if let scope = capture.readingScope, scope.windowID != visibleWindow {
            suspendReading("等待原阅读窗口…"); return
        }
        if visibleWindow != capture.selectedID {
            cancelTranslation(); resetTracking(); latestPage = nil; shownEntry = nil; overlay.hide()
        }
        captureBusy = true; let epoch = operationEpoch
        defer { captureBusy = false }
        do {
            let sample = try await capture.capture(maxDimension: 640)
            probeCaptures += 1
            guard operationEpoch == epoch else { return }
            guard let probe = probeTracker.observe(sample) else {
                overlay.hide()
                if runner == nil, autoButton.state == .on { setStatus("正在检查新页面…") }
                // Confirm a page turn promptly, without increasing the idle
                // screenshot rate or continuously chasing an animation.
                if !didConfirmCandidate {
                    didConfirmCandidate = true
                    settlingProbe?.cancel()
                    settlingProbe = Task { @MainActor [weak self] in
                        do { try await Task.sleep(nanoseconds: 200_000_000) }
                        catch { return }
                        guard let self, self.operationEpoch == epoch else { return }
                        self.settlingProbe = nil
                        await self.poll()
                    }
                }
                return
            }
            settlingProbe?.cancel(); settlingProbe = nil; didConfirmCandidate = false
            if lastProbeDigest == probe.digest {
                updateOverlay()
                if runner == nil, ["正在检查新页面…", "等待阅读窗口…", "等待原阅读窗口…", "等待原阅读页面…"].contains(statusText), let entry = shownEntry { show(entry, cached: true) }
                if autoButton.state == .on, runner == nil, tracker.needsSubmission, let page = tracker.current {
                    submit(page, force: false)
                }
                return
            }
            let captured = try await capture.capture()
            fullCaptures += 1
            guard operationEpoch == epoch else { return }
            guard captured.matchesProbe(probe) else { probeTracker.reset(); overlay.hide(); return }
            lastProbeDigest = probe.digest
            let page: CapturedPage
            if let current = tracker.current, captured.hasSameContent(as: current) { page = current }
            else { tracker.adopt(captured); page = captured }
            let previous = latestPage
            if runner != nil, requestDigest != page.digest { cancelTranslation() }
            if previous?.digest != page.digest {
                shownEntry = nil; overlay.hide(); detailLabel.stringValue = ""
                if autoButton.state == .on { setStatus("正在检查新页面…") }
            }
            latestPage = page
            updateOverlay()
            if runner == nil, ["等待阅读窗口…", "正在检查新页面…"].contains(statusText), let entry = shownEntry { show(entry, cached: true) }
            if runner == nil, let failure = pageFailure, failure.digest == page.digest, !tracker.needsSubmission {
                setStatus(failure.message, error: true)
            }
            guard autoButton.state == .on, runner == nil, tracker.needsSubmission else { return }
            cancelTranslation(); submit(page, force: false)
        } catch is ReadingScopeError { suspendReading("等待原阅读页面…") }
        catch is CancellationError { overlay.hide() }
        catch {
            if operationEpoch == epoch {
                overlay.hide()
                if (error as? AppError)?.needsUserAction == true { stopWork() }
                setStatus(error.localizedDescription, error: true)
            }
        }
    }
    private func suspendReading(_ message: String) {
        overlay.hide()
        if let digest = requestDigest { tracker.release(digest); cancelTranslation() }
        if autoButton.state == .on { setStatus(message) }
    }
    private func updateOverlay() {
        guard !tracker.isSettling, !probeTracker.isSettling, overlayButton.state == .on, let entry = shownEntry, entry.options == options,
              let page = latestPage, page.digest == entry.pageDigest,
              let target = capture.selectedID, let source = capture.source else { overlay.hide(); return }
        overlay.show(entry, page: page, windowID: target, processID: source.processID, topInset: capture.topInset)
        if correctionCandidates?.digest == page.digest {
            overlay.setCorrectionCandidates(correctionCandidates?.dialogues ?? [])
        }
    }

    private func submit(_ page: CapturedPage, force: Bool, refreshOCR: Bool = false) {
        guard let cache, let ocr else { setStatus("翻译组件尚未就绪", error: true); return }
        let client = client, google = google
        let selected = options
        guard translationAvailable else {
            stopWork(); setStatus("请先加载可用模型", error: true); return
        }
        if selected.provider == .codex {
            defaults.set(selected.model, forKey: "selectedModel"); defaults.set(selected.effort, forKey: "effort")
        }
        pageFailure = nil
        tracker.markSubmitted(page.digest)
        let cached = force ? nil : cache.lookup(page: page, options: selected)
        let corrections = cached?.translation.dialogues.filter { $0.userEdited == true || $0.userRestoredOriginal == true } ?? []
        if let entry = cached {
            if let recognized = ocr.cachedRecognition(for: page) { setCorrectionCandidates(recognized, digest: page.digest) }
            show(entry, cached: true)
            if entry.translation.untranslatedCount == 0 { return }
        }
        let taskID = UUID(), jobRunner = CommandRunner(), began = Date()
        requestID = taskID; runner = jobRunner; requestDigest = page.digest; startTime = began
        spinner.isHidden = false; spinner.startAnimation(nil); detailLabel.stringValue = ""
        setStatus("本地识字…")
        timerStatus = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.startTime else { return }
                self.detailLabel.stringValue = "\(Int(Date().timeIntervalSince(start))) 秒"
            }
        }
        let report: (String) -> Void = { [weak self] text in
            DispatchQueue.main.async {
                guard let self, self.requestID == taskID else { return }
                self.setStatus(text)
            }
        }
        let group = translationGroup
        let recognition = RecognitionSnapshot()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { group.leave() }
            let result = Result {
                try TranslationPipeline.run(runner: jobRunner, began: began, corrections: corrections, recognize: { textReady in
                    var ready = false
                    let final = try ocr.recognize(page: page, runner: jobRunner, force: refreshOCR,
                        progress: { if !ready { report($0) } }, onTextReady: {
                            let adjusted = TranslationPipeline.applyingCorrections($0, corrections: corrections)
                            recognition.update(adjusted); ready = true; textReady(adjusted)
                        })
                    let adjusted = TranslationPipeline.applyingCorrections(final, corrections: corrections)
                    recognition.update(adjusted, final: true)
                    return adjusted
                }, translate: { recognized, preview in
                    let accepted = DispatchQueue.main.sync { () -> Bool in
                        MainActor.assumeIsolated {
                            guard let self, self.requestID == taskID else { return false }
                            return self.latestPage?.digest == page.digest
                        }
                    }
                    guard accepted else { throw CancellationError() }
                    if selected.provider == .google, let google {
                        return try google.translate(ocr: recognized, options: selected, runner: jobRunner,
                            force: force, seed: cached?.translation, progress: report, preview: preview).0
                    }
                    guard let client else { throw AppError.configuration("请先安装并登录 Codex。") }
                    let context = recognition.snapshot()
                    let isWholePage = context.final && context.page?.blocks.map(\.id) == recognized.blocks.map(\.id)
                    return try client.translate(ocr: recognized, options: selected, runner: jobRunner,
                        force: force, seed: cached?.translation, rememberResult: false,
                        pageContext: context.page, cacheResult: isWholePage, progress: report, preview: preview).0
                }, preview: { partial, timings in
                    let elapsed = Date().timeIntervalSince(began)
                    DispatchQueue.main.async {
                        guard let self, self.requestID == taskID, self.options == selected,
                              self.latestPage?.digest == page.digest else { return }
                        self.shownEntry = CacheEntry(id: "preview-\(taskID)-\(partial.dialogues.count)", options: selected,
                            pageDigest: page.digest, translation: partial, createdAt: Date(), elapsed: elapsed, timings: timings)
                        self.updateOverlay()
                        let total = partial.dialogues.count + partial.untranslatedCount
                        self.setStatus("已译 \(partial.translatedCount)/\(total)")
                    }
                })
            }
            DispatchQueue.main.async {
                guard let self, self.requestID == taskID else { return }
                self.finishBusyState()
                if let recognized = recognition.read() { self.setCorrectionCandidates(recognized, digest: page.digest) }
                switch result {
                case .success(let (translation, timings)):
                    do {
                        if selected.provider == .codex {
                            client?.remember(page: translation, options: selected, ocr: recognition.read())
                        }
                        guard let currentCache = self.cache else { return }
                        let entry = try currentCache.save(page: page, options: selected, translation: translation,
                                                         elapsed: Date().timeIntervalSince(began), timings: timings)
                        if self.options == selected, self.latestPage?.digest == page.digest {
                            self.show(entry, cached: false)
                        } else { self.setStatus("等待翻译当前页…") }
                    } catch { self.setStatus("保存译文失败：\(error.localizedDescription)", error: true) }
                case .failure(let error):
                    if error is CancellationError {
                        self.tracker.release(page.digest); self.pageFailure = nil
                        self.overlay.hide()
                        self.setStatus(self.autoButton.state == .on ? "正在检查新页面…" : "已停止")
                        return
                    }
                    if let partial = self.shownEntry, partial.pageDigest == page.digest,
                       !partial.translation.dialogues.isEmpty {
                        let previous = partial.translation
                        let kept = PageTranslation(summary: "", dialogues: previous.dialogues,
                            notes: error.localizedDescription, skippedCount: previous.skippedCount,
                            ocrSkippedCount: previous.ocrSkippedCount)
                        // A full streaming preview is not a successful final
                        // response. Persist only incomplete seeds after failure.
                        if kept.untranslatedCount > 0, let saved = try? self.cache?.save(page: page, options: selected, translation: kept,
                            elapsed: Date().timeIntervalSince(began), timings: partial.timings) {
                            self.shownEntry = saved
                        }
                        self.updateOverlay()
                    } else { self.shownEntry = nil; self.overlay.hide() }
                    self.pageFailure = (page.digest, error.localizedDescription)
                    if (error as? AppError)?.needsUserAction == true { self.stopWork() }
                    self.setStatus(error is CancellationError ? "已停止" : error.localizedDescription,
                                   error: !(error is CancellationError))
                    if self.autoButton.state == .on {
                        self.statusLabel.toolTip = error.localizedDescription + "\n右键 Shiori 图标可重试此页。"
                    }
                }
            }
        }
    }
    private func show(_ entry: CacheEntry, cached: Bool) {
        shownEntry = entry; modelError = nil; updateOverlay()
        if let failure = pageFailure, failure.digest == entry.pageDigest {
            setStatus(failure.message, error: true); return
        }
        if tracker.isSettling { setStatus("正在检查新页面…"); return }
        let translated = entry.translation.translatedCount
        let total = entry.translation.dialogues.count + entry.translation.skippedCount
        let rendered = overlay.renderedCount
        let partial = overlayButton.state == .on
            ? "已译 \(translated)/\(total) · 显示 \(rendered)"
            : "已翻译 \(translated)/\(total) 处"
        let status = total == 0 ? "未检测到日文" : entry.translation.pendingCount > 0
            ? "已译 \(translated) · \(entry.translation.pendingCount) 处待确认"
            : (overlayButton.state == .on && rendered < translated) ? partial : "翻译完成"
        setStatus(status, error: total > 0 && translated == 0 && entry.translation.preservedCount == 0)
        let unrecognized = entry.translation.ocrSkippedCount ?? 0
        var details = ["检测到 \(total) 处候选文字：已译 \(translated) 处，未译 \(entry.translation.untranslatedCount) 处，未识字 \(unrecognized) 处。"]
        if entry.translation.unclearCount > 0 {
            details.append("\(entry.translation.unclearCount) 处待确认，其中 \(entry.translation.preservedCount) 处保留原图。")
        }
        if overlayButton.state == .on, rendered < translated {
            details.append("\(translated-rendered) 处未显示：" + overlay.omittedSummary + "。右键可复制译文。")
        }
        if !entry.translation.notes.isEmpty { details.append(entry.translation.notes) }
        if let timings = entry.timings {
            details.append(String(format: "识字 %.1f 秒，翻译 %.1f 秒。", timings.ocr, timings.codex))
        }
        statusLabel.toolTip = details.joined(separator: "\n")
        detailLabel.stringValue = cached ? "" : String(format: "%.1f 秒", entry.elapsed)
    }
    private func validateCorrectionPage() async {
        guard !captureBusy, let page = latestPage, let source = capture.source,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == source.processID else { return }
        captureBusy = true
        defer { captureBusy = false }
        let epoch = operationEpoch
        do {
            // ScreenCaptureKit reads only the reader window, so the editor and
            // selection outlines cannot be mistaken for a new manga page.
            let current = try await capture.capture()
            guard isCorrectingBubble, operationEpoch == epoch else { return }
            let selected = overlay.selectedBubbleID
            let translated = shownEntry?.translation.dialogues ?? []
            var body = translated.filter {
                $0.location == selected || ($0.textStyle == nil && ($0.bounds?.y ?? 0) >= 100)
            }.compactMap(\.bounds)
            if let selected, correctionCandidates?.digest == page.digest,
               !translated.contains(where: { $0.location == selected && $0.bounds != nil }),
               let bounds = correctionCandidates?.dialogues.first(where: { $0.location == selected })?.bounds {
                body.append(bounds)
            }
            // Reader controls can animate on pointer movement. Compare the
            // original bubble pixels instead, including the selected bubble.
            let unchanged = body.isEmpty ? current.hasSameContent(as: page)
                : current.hasSameTextRegions(as: page, regions: body)
            if !unchanged {
                overlay.endCorrection()
                overlay.hide()
                setStatus("正在检查新页面…")
            }
        } catch {
            guard isCorrectingBubble, operationEpoch == epoch else { return }
            overlay.endCorrection(); overlay.hide()
            setStatus(error is ReadingScopeError ? "等待原阅读页面…" : "等待阅读窗口…")
        }
    }

    private func setCorrectionCandidates(_ recognized: OCRPage, digest: String) {
        correctionCandidates = (digest, recognized.blocks.map {
            var value = Dialogue.recognized($0, text: "")
            value.preserveOriginal = true
            return value
        })
    }

    @objc private func editBubble() {
        guard runner == nil, !captureBusy, let page = latestPage, shownEntry?.pageDigest == page.digest else { return }
        if correctionCandidates?.digest != page.digest, let recognized = ocr?.cachedRecognition(for: page) {
            setCorrectionCandidates(recognized, digest: page.digest)
        }
        popover.performClose(nil)
        overlayButton.state = .on; defaults.set(true, forKey: "showOverlay")
        showReader(); updateOverlay()
        if !overlay.beginCorrection() { setStatus("这页没有可选择的气泡") }
    }

    private func saveCorrection(_ dialogue: Dialogue, page: CapturedPage, selected: TranslationOptions) throws {
        guard let current = shownEntry, current.pageDigest == page.digest, current.options == selected,
              let cache else { throw AppError.message("页面已改变，请重新选择气泡。") }
        let order = correctionCandidates?.digest == page.digest
            ? correctionCandidates!.dialogues.map(\.location) : current.translation.dialogues.map(\.location)
        let updated = BubbleCorrection.replacing(dialogue, in: current.translation, order: order)
        let entry = try cache.save(page: page, options: selected, translation: updated,
                                   elapsed: current.elapsed, timings: current.timings)
        if updated.untranslatedCount == 0, pageFailure?.digest == page.digest { pageFailure = nil }
        show(entry, cached: true)
    }

    private func correctBubble(id: String, action: BubbleEditAction) {
        guard isCorrectingBubble, correctionRunner == nil, let page = latestPage,
              let entry = shownEntry, entry.pageDigest == page.digest,
              let original = entry.translation.dialogues.first(where: { $0.location == id })
                ?? (correctionCandidates?.digest == page.digest
                    ? correctionCandidates?.dialogues.first(where: { $0.location == id }) : nil) else {
            overlay.finishBubbleAction(id: id, dialogue: nil, error: "页面已改变，请重新选择气泡。")
            return
        }
        let selected = options
        do {
            switch action {
            case .save(let source, let translation):
                let value = try BubbleCorrection.edited(original, source: source, translation: translation)
                try saveCorrection(value, page: page, selected: selected)
                overlay.finishBubbleAction(id: id, dialogue: value)
                return
            case .restoreOriginal:
                let value = BubbleCorrection.restored(original)
                try saveCorrection(value, page: page, selected: selected)
                overlay.finishBubbleAction(id: id, dialogue: value)
                return
            case .recognize, .translate: break
            }
            guard translationAvailable, let ocr else { throw AppError.message("翻译服务尚未就绪。") }
            let taskID = UUID(), jobRunner = CommandRunner()
            correctionID = taskID; correctionRunner = jobRunner
            let client = client, google = google, group = translationGroup
            let context = OCRPage(blocks: entry.translation.dialogues.compactMap { try? BubbleCorrection.block(from: $0) },
                                  skippedCount: 0, elapsed: 0)
            setStatus("正在修正气泡…")
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                defer { group.leave() }
                let result = Result { () throws -> Dialogue in
                    try jobRunner.checkCancellation()
                    var block: OCRBlock
                    switch action {
                    case .recognize:
                        let region = try BubbleCorrection.crop(original, from: page)
                        let text = try ocr.recognizeBubble(page: region, runner: jobRunner)
                        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            throw AppError.message("没有识别到文字，可以直接修改原文。")
                        }
                        block = try BubbleCorrection.block(from: original, source: text)
                    case .translate(let source): block = try BubbleCorrection.block(from: original, source: source)
                    default: throw CancellationError()
                    }
                    let single = OCRPage(blocks: [block], skippedCount: 0, elapsed: 0)
                    let result: PageTranslation
                    if selected.provider == .google, let google {
                        result = try google.translate(ocr: single, options: selected, runner: jobRunner, force: true).0
                    } else if let client {
                        result = try client.translate(ocr: single, options: selected, runner: jobRunner, force: true,
                                                      rememberResult: false, pageContext: context, cacheResult: false).0
                    } else { throw AppError.message("翻译服务尚未就绪。") }
                    try jobRunner.checkCancellation()
                    guard let value = result.dialogues.first(where: { $0.location == id }) else {
                        throw AppError.message("这个气泡未返回译文，请重试或手动填写。")
                    }
                    var edited = value
                    edited.userEdited = true
                    return edited
                }
                DispatchQueue.main.async {
                    guard let self, self.correctionID == taskID else { return }
                    self.correctionRunner = nil; self.correctionID = nil
                    guard self.isCorrectingBubble, self.latestPage?.digest == page.digest, self.options == selected else { return }
                    do {
                        let value = try result.get()
                        try self.saveCorrection(value, page: page, selected: selected)
                        self.overlay.finishBubbleAction(id: id, dialogue: value)
                    } catch {
                        self.overlay.finishBubbleAction(id: id, dialogue: nil, error: error.localizedDescription)
                        self.setStatus(error.localizedDescription, error: !(error is CancellationError))
                    }
                }
            }
        } catch {
            overlay.finishBubbleAction(id: id, dialogue: nil, error: error.localizedDescription)
        }
    }

    private func finishBusyState() {
        runner = nil; requestID = nil; requestDigest = nil; startTime = nil
        timerStatus?.invalidate(); timerStatus = nil; spinner.stopAnimation(nil); spinner.isHidden = true
        updateStatus()
    }
    private func cancelTranslation() { runner?.cancel(); finishBusyState() }
    private func resetTracking() {
        settlingProbe?.cancel(); settlingProbe = nil; didConfirmCandidate = false
        tracker.reset(); probeTracker.reset(); lastProbeDigest = nil
    }
    private func stopWork() {
        overlay.endCorrection()
        correctionRunner?.cancel(); correctionRunner = nil; correctionID = nil
        operationEpoch += 1; autoButton?.state = .off
        capture.endReading()
        resetTracking(); cancelTranslation()
        detailLabel?.stringValue = ""
    }
    @objc private func stopClicked() { stopWork(); setStatus("已暂停") }
    @objc private func copyTranslation() {
        guard let entry = shownEntry else { return }
        let text = entry.translation.dialogues.map { "\($0.location)\n\($0.translation)" }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        setStatus("译文已复制")
    }
    private func ensureCaptureAccess() -> Bool {
        guard CGPreflightScreenCaptureAccess() else {
            setStatus("需要屏幕录制权限", error: true)
            openPermissions(); return false
        }
        guard BrowserContent.isBrowser(capture.source?.identity), !BrowserContent.hasAccess else { return true }
        BrowserContent.requestAccess(); setStatus("需要辅助功能权限", error: true); return false
    }
    @objc private func openAccessibility() {
        BrowserContent.requestAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func openPermissions() {
        CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    @objc private func openCache() { if let cache { NSWorkspace.shared.open(cache.directory) } }
}

private enum PanelPalette {
    static let canvas = NSColor.windowBackgroundColor
    static let surface = NSColor.controlBackgroundColor
    static let accent = NSColor.controlAccentColor
    static var line: NSColor { NSColor.labelColor.withAlphaComponent(0.10) }
}

private final class PanelCanvas: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        PanelPalette.canvas.setFill(); bounds.fill()
        PanelPalette.line.setFill()
        NSRect(x: 12, y: bounds.height-38, width: bounds.width-24, height: 0.5).fill()
    }
}

private final class PanelGroup: NSView {
    private weak var rows: NSStackView?
    init(rows: NSStackView) { self.rows = rows; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override var isFlipped: Bool { true }
    override func layout() { super.layout(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
        PanelPalette.surface.setFill(); path.fill()
        PanelPalette.line.setStroke(); path.lineWidth = 0.5; path.stroke()
        let visibleRows = rows?.arrangedSubviews.filter { !$0.isHidden } ?? []
        PanelPalette.line.setFill()
        for row in visibleRows.dropLast() {
            let rect = row.convert(row.bounds, to: self)
            NSRect(x: 10, y: rect.maxY, width: bounds.width-20, height: 0.5).fill()
        }
    }
}

// A pull-down anchors the menu below its field. The display item lives outside
// the menu, so every menu row is a real option and indexes have no placeholder.
private final class PanelSelectionCell: NSPopUpButtonCell {
    private var synchronizing = false
    private func refreshSelection() {
        guard !synchronizing else { return }
        synchronizing = true; defer { synchronizing = false }
        usesItemFromMenu = false
        let display = NSMenuItem(title: selectedItem?.title ?? "", action: nil, keyEquivalent: "")
        display.image = selectedItem?.image
        menuItem = display
        for item in itemArray {
            item.isHidden = false
            item.state = item === selectedItem ? .on : .off
        }
        controlView?.needsDisplay = true
    }
    override func select(_ item: NSMenuItem?) { super.select(item); refreshSelection() }
    override func selectItem(at index: Int) { super.selectItem(at: index); refreshSelection() }
    override func selectItem(withTitle title: String) { super.selectItem(withTitle: title); refreshSelection() }
    override func synchronizeTitleAndSelectedItem() { super.synchronizeTitleAndSelectedItem(); refreshSelection() }
}

private final class PanelPopUpButton: NSPopUpButton {
    var contextActions: NSMenu?
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    init(showsIcon: Bool = false) {
        super.init(frame: .zero, pullsDown: true)
        let selection = PanelSelectionCell(textCell: "", pullsDown: true)
        selection.usesItemFromMenu = false; selection.preferredEdge = .maxY
        cell = selection
        isBordered = false; controlSize = .small; font = .systemFont(ofSize: 12)
        autoenablesItems = false
        imagePosition = showsIcon ? .imageLeading : .noImage
        alignment = .left
        setAccessibilityRole(.popUpButton)
        cell?.lineBreakMode = .byTruncatingTail
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func menu(for event: NSEvent) -> NSMenu? {
        if event.type == .rightMouseDown || event.modifierFlags.contains(.control), let contextActions {
            return contextActions
        }
        return super.menu(for: event)
    }
    override func rightMouseDown(with event: NSEvent) {
        guard let contextActions else { super.rightMouseDown(with: event); return }
        contextActions.update()
        NSMenu.popUpContextMenu(contextActions, with: event, for: self)
    }
    override func accessibilityValue() -> Any? { titleOfSelectedItem }
    override func layout() {
        super.layout()
        menu?.minimumWidth = bounds.width
    }
}

private final class PanelActionButton: NSButton {
    static var accent: NSColor { PanelPalette.accent }
    var active = false { didSet { updateAppearance() } }
    override var title: String { didSet { updateAppearance() } }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override init(frame: NSRect) {
        super.init(frame: frame)
        bezelStyle = .rounded; controlSize = .large
        font = .systemFont(ofSize: 12, weight: .medium)
        imagePosition = .noImage
        updateAppearance()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    private func updateAppearance() {
        bezelColor = active ? nil : .controlAccentColor
        let foreground: NSColor = active ? .labelColor : .white
        contentTintColor = foreground
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: foreground
        ])
        needsDisplay = true
    }
}
