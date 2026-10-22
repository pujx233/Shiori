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
    private var autoButton: NSButton!
    private var overlayButton: NSButton!
    private var translateButton: NSButton!
    private var statusLabel: NSTextField!
    private var detailLabel: NSTextField!
    private var spinner: NSProgressIndicator!
    private var statusDot: NSImageView!
    private var statusItem: NSStatusItem!
    private var client: CodexClient?
    private var cache: TranslationCache?
    private var ocr: LocalOCR?
    private var requestDigest: String?
    private var pageFailure: (digest: String, message: String)?
    private let translationGroup = DispatchGroup()
    private let capture = ReaderCapture()
    private let overlay = MangaOverlay()
    private var models: [ModelInfo] = []
    private var timer: Timer?
    private var modelTimer: Timer?
    private var timerStatus: Timer?
    private var tracker = PageTracker()
    private var probeTracker = PageTracker()
    private var lastProbeDigest: String?
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
        do {
            let support = try AppStorage.directory()
            cache = try TranslationCache(directory: support.appendingPathComponent("Translations"))
            client = try CodexClient(resources: Bundle.main.resourceURL!, workspace: support.appendingPathComponent("Jobs"),
                                    textCacheDirectory: support.appendingPathComponent("TextTranslations"))
            ocr = try LocalOCR(support: support, resources: Bundle.main.resourceURL!)
            if let ocr { DispatchQueue.global(qos: .utility).async { try? ocr.prepare() } }
            if let client { DispatchQueue.global(qos: .utility).async { try? client.prepare() } }
            if let data = defaults.data(forKey: "modelCatalog"),
               let saved = try? JSONDecoder().decode([ModelInfo].self, from: data), !saved.isEmpty {
                applyModels(saved)
            }
            if models.isEmpty { refreshModels() }
            let refresh = Timer(fire: Date(timeIntervalSinceNow: models.isEmpty ? 24 * 60 * 60 : 5),
                                interval: 24 * 60 * 60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshModels() }
            }
            modelTimer = refresh; RunLoop.main.add(refresh, forMode: .common)
        } catch { setStatus(error.localizedDescription, error: true) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
        showSettings(); refreshSources()
    }

    func renderPanel(to destination: URL, dark: Bool = false) throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        NSApplication.shared.appearance = appearance
        migratePreviousSettings()
        buildWindow(); refreshApplications()
        if let data = defaults.data(forKey: "modelCatalog"),
           let saved = try? JSONDecoder().decode([ModelInfo].self, from: data), !saved.isEmpty { applyModels(saved) }
        setStatus("就绪")
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
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = menu
    }

    private func buildStatusMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = ""
        statusItem.button?.toolTip = "Shiori"
        statusItem.button?.image = MangaMenuIcon.make()
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
        let panelSize = NSSize(width: 240, height: 236)
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
        modelBox = PanelPopUpButton(); modelBox.addItem(withTitle: "")
        modelBox.addItem(withTitle: defaults.string(forKey: "selectedModel") ?? "gpt-6.1-sol"); modelBox.selectItem(at: 1)
        modelBox.target = self; modelBox.action = #selector(optionsChanged); modelBox.isEnabled = false
        modelBox.menu?.delegate = self
        modelBox.setAccessibilityLabel("翻译模型")
        effortBox = PanelPopUpButton(); effortBox.addItems(withTitles: ["", "low", "medium", "high", "xhigh", "max"])
        effortBox.selectItem(withTitle: defaults.string(forKey: "effort") ?? "low")
        effortBox.target = self; effortBox.action = #selector(optionsChanged); effortBox.setAccessibilityLabel("推理")
        effortBox.menu?.delegate = self
        let fields = NSStackView()
        fields.orientation = .vertical; fields.alignment = .leading; fields.spacing = 0
        for (caption, control) in [("软件", sourceBox!), ("模型", modelBox!), ("推理", effortBox!)] {
            let name = label(caption); name.font = .systemFont(ofSize: 11)
            name.widthAnchor.constraint(equalToConstant: 24).isActive = true
            let field = row([name, control]); field.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 0)
            fields.addArrangedSubview(field)
            control.heightAnchor.constraint(equalToConstant: 30).isActive = true
            control.widthAnchor.constraint(equalTo: field.widthAnchor, constant: -42).isActive = true
            field.heightAnchor.constraint(equalToConstant: 34).isActive = true
            field.widthAnchor.constraint(equalTo: fields.widthAnchor).isActive = true
        }
        let fieldGroup = PanelGroup()
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
        for toggle in [autoButton!, overlayButton!] { toggle.font = .systemFont(ofSize: 11); toggle.controlSize = .small; toggle.heightAnchor.constraint(equalToConstant: 24).isActive = true }
        overlayButton.state = defaults.object(forKey: "showOverlay") as? Bool == false ? .off : .on
        let toggles = row([autoButton, overlayButton]); toggles.distribution = .fillEqually; toggles.spacing = 6
        toggles.heightAnchor.constraint(equalToConstant: 24).isActive = true; add(toggles)
        translateButton = PanelActionButton(title: "开始阅读", target: self, action: #selector(startReading))
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
        guard models.contains(where: { $0.slug == options.model }) else { setStatus("请先加载可用模型", error: true); return }
        autoButton.state = .on; toggleAuto()
    }
    private var options: TranslationOptions {
        TranslationOptions(model: modelBox.titleOfSelectedItem ?? "", effort: effortBox.titleOfSelectedItem ?? "low", context: capture.contextKey)
    }
    private func setStatus(_ text: String, error: Bool = false) {
        statusText = text; statusIsError = error; updateStatus()
    }
    private func updateStatus() {
        var text = statusText, error = statusIsError
        if !error, runner == nil {
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
        let old = options
        models = catalog
        modelBox.removeAllItems(); modelBox.addItems(withTitles: [""] + catalog.map(\.slug))
        modelBox.selectItem(withTitle: old.model)
        if modelBox.indexOfSelectedItem < 1 { modelBox.selectItem(at: catalog.isEmpty ? 0 : 1) }
        modelBox.isEnabled = !catalog.isEmpty; modelBox.toolTip = nil
        modelError = catalog.isEmpty ? "账号没有可用模型" : nil
        updateEfforts()
        if old != options { optionsChanged() }
    }
    private func updateEfforts() {
        let selected = effortBox.titleOfSelectedItem ?? "low"
        let supported = models.first(where: { $0.slug == options.model })?.supported_reasoning_levels?.map(\.effort)
             ?? ["low", "medium", "high"]
        effortBox.removeAllItems(); effortBox.addItems(withTitles: [""] + (supported.isEmpty ? ["low"] : supported))
        effortBox.selectItem(withTitle: selected)
        if effortBox.indexOfSelectedItem < 1 { effortBox.selectItem(at: 1) }
    }
    @objc private func optionsChanged() {
        operationEpoch += 1; updateEfforts()
        defaults.set(options.model, forKey: "selectedModel"); defaults.set(options.effort, forKey: "effort")
        cancelTranslation(); resetTracking(); overlay.hide()
        detailLabel.stringValue = ""
        shownEntry = nil
        setStatus(autoButton.state == .on ? "等待翻译…" : "就绪")
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(translateCurrent) || item.action == #selector(retranslate) || item.action == #selector(rerecognize) {
            return runner == nil && !captureBusy && capture.source != nil && !models.isEmpty
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
        }
    }
    func menuWillOpen(_ menu: NSMenu) {
        if menu === sourceActions { return }
        if menu === sourceBox.menu { refreshApplications() }
        if let control = [sourceBox, modelBox, effortBox].compactMap({ $0 }).first(where: { $0.menu === menu }) {
            for item in menu.items { item.state = item === control.selectedItem ? .on : .off }
        }
    }
    func menuDidClose(_ menu: NSMenu) {
        guard menu === sourceActions else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.statusItem.menu === menu else { return }
            self.statusItem.menu = nil
        }
    }
    private func refreshApplications() {
        applications = CaptureSource.running()
        let legacy = defaults.string(forKey: "captureSource") == "chrome" ? "com.google.Chrome" : "com.xiaogd.kedamanga"
        let preferred = defaults.string(forKey: "captureApplication") ?? legacy
        let selected = applications.first { $0.processID == capture.source?.processID } ?? applications.first { $0.identity == preferred }
        if selected?.processID != capture.source?.processID {
            stopWork(); capture.source = selected; latestPage = nil; shownEntry = nil; overlay.hide()
        }
        sourceBox.removeAllItems(); sourceBox.addItem(withTitle: "选择软件"); sourceBox.item(at: 0)?.isEnabled = false
        for app in applications {
            sourceBox.addItem(withTitle: app.title); sourceBox.lastItem?.representedObject = app.processID
            if let icon = app.application?.icon?.copy() as? NSImage { icon.size = NSSize(width: 16, height: 16); sourceBox.lastItem?.image = icon }
        }
        sourceBox.selectItem(at: selected.flatMap { source in applications.firstIndex { $0.processID == source.processID }.map { $0 + 1 } } ?? 0)
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
        window?.makeFirstResponder(nil); captureBusy = true
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
            guard capture.source != nil, models.contains(where: { $0.slug == options.model }) else {
                stopWork(); setStatus(capture.source == nil ? "请先选择软件" : "请先加载可用模型", error: true); return
            }
            guard ensureCaptureAccess() else { stopWork(); return }
            window?.makeFirstResponder(nil); resetTracking(); setStatus("自动翻译已开启")
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
        guard !captureBusy, autoButton.state == .on || runner != nil || shownEntry != nil else { return }
        guard let source = capture.source else { return }
        guard source.application?.isTerminated == false else { stopWork(); overlay.hide(); refreshApplications(); setStatus("阅读软件已关闭"); return }
        guard let visibleWindow = ReaderCapture.visibleWindowID(processID: source.processID) else {
            overlay.hide()
            if autoButton.state == .on { setStatus("等待阅读窗口…") }
            return
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
                return
            }
            if lastProbeDigest == probe.digest {
                updateOverlay()
                if runner == nil, statusText == "正在检查新页面…", let entry = shownEntry { show(entry, cached: true) }
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
        } catch is CancellationError { overlay.hide() }
        catch {
            if operationEpoch == epoch {
                overlay.hide()
                if (error as? AppError)?.needsUserAction == true { stopWork() }
                setStatus(error.localizedDescription, error: true)
            }
        }
    }
    private func updateOverlay() {
        guard !tracker.isSettling, !probeTracker.isSettling, overlayButton.state == .on, let entry = shownEntry, entry.options == options,
              let page = latestPage, page.digest == entry.pageDigest,
              let target = capture.selectedID, let source = capture.source else { overlay.hide(); return }
        overlay.show(entry, page: page, windowID: target, processID: source.processID, topInset: capture.topInset)
    }

    private func submit(_ page: CapturedPage, force: Bool, refreshOCR: Bool = false) {
        guard let client, let cache, let ocr else { setStatus("翻译组件尚未就绪", error: true); return }
        let selected = options
        guard models.contains(where: { $0.slug == selected.model }) else {
            stopWork(); setStatus("请先加载可用模型", error: true); return
        }
        defaults.set(selected.model, forKey: "selectedModel"); defaults.set(selected.effort, forKey: "effort")
        pageFailure = nil
        tracker.markSubmitted(page.digest)
        let cached = force ? nil : cache.lookup(page: page, options: selected)
        if let entry = cached {
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
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { group.leave() }
            let result = Result { () -> (PageTranslation, PageTimings) in
                let ocrStart = Date()
                let recognized = try ocr.recognize(page: page, runner: jobRunner, force: refreshOCR, progress: report)
                let ocrTime = Date().timeIntervalSince(ocrStart)
                try jobRunner.checkCancellation()
                if recognized.blocks.isEmpty {
                    return (PageTranslation(summary: "", dialogues: [], notes: "未识别到日文",
                                            skippedCount: recognized.skippedCount, ocrSkippedCount: recognized.skippedCount),
                            PageTimings(ocr: ocrTime, codex: 0, firstResult: nil))
                }
                let accepted = DispatchQueue.main.sync { () -> Bool in
                    MainActor.assumeIsolated {
                        guard let self, self.requestID == taskID else { return false }
                        if (self.autoButton.state == .on && self.probeTracker.isSettling) || self.tracker.isSettling || self.latestPage?.digest != page.digest {
                            self.tracker.release(page.digest); self.cancelTranslation(); self.shownEntry = nil; self.overlay.hide()
                            self.setStatus("正在检查新页面…"); return false
                        }
                        return true
                    }
                }
                guard accepted else { throw CancellationError() }
                let codexStart = Date()
                var firstResult: Double?
                let translation = try client.translate(ocr: recognized, options: selected, runner: jobRunner,
                                                       force: force, seed: cached?.translation, progress: report, preview: { partial in
                    if firstResult == nil { firstResult = Date().timeIntervalSince(began) }
                    let elapsed = Date().timeIntervalSince(began)
                    let timings = PageTimings(ocr: ocrTime, codex: Date().timeIntervalSince(codexStart), firstResult: firstResult)
                    DispatchQueue.main.async {
                        guard let self, self.requestID == taskID, self.options == selected,
                              self.latestPage?.digest == page.digest else { return }
                        self.shownEntry = CacheEntry(id: "preview-\(taskID)-\(partial.dialogues.count)", options: selected,
                            pageDigest: page.digest, translation: partial, createdAt: Date(), elapsed: elapsed, timings: timings)
                        self.updateOverlay()
                        let rendered = self.overlay.renderedCount
                        self.setStatus("已译 \(partial.translatedCount)/\(recognized.blocks.count) · 显示 \(rendered)")
                    }
                }).0
                return (translation, PageTimings(ocr: ocrTime, codex: Date().timeIntervalSince(codexStart), firstResult: firstResult))
            }
            DispatchQueue.main.async {
                guard let self, self.requestID == taskID else { return }
                self.finishBusyState()
                switch result {
                case .success(let (translation, timings)):
                    do {
                        guard let currentCache = self.cache else { return }
                        let entry = try currentCache.save(page: page, options: selected, translation: translation,
                                                         elapsed: Date().timeIntervalSince(began), timings: timings)
                        if self.options == selected, self.latestPage?.digest == page.digest {
                            self.show(entry, cached: false)
                        } else { self.setStatus("等待翻译当前页…") }
                    } catch { self.setStatus("保存译文失败：\(error.localizedDescription)", error: true) }
                case .failure(let error):
                    if let partial = self.shownEntry, partial.pageDigest == page.digest,
                       !partial.translation.dialogues.isEmpty {
                        let previous = partial.translation
                        let kept = PageTranslation(summary: "", dialogues: previous.dialogues,
                            notes: error.localizedDescription, skippedCount: previous.skippedCount,
                            ocrSkippedCount: previous.ocrSkippedCount)
                        if let saved = try? self.cache?.save(page: page, options: selected, translation: kept,
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
    private func finishBusyState() {
        runner = nil; requestID = nil; requestDigest = nil; startTime = nil
        timerStatus?.invalidate(); timerStatus = nil; spinner.stopAnimation(nil); spinner.isHidden = true
        updateStatus()
    }
    private func cancelTranslation() { runner?.cancel(); finishBusyState() }
    private func resetTracking() { tracker.reset(); probeTracker.reset(); lastProbeDigest = nil }
    private func stopWork() {
        operationEpoch += 1; autoButton?.state = .off
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

private enum MangaMenuIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState(); defer { context.restoreGState() }
            context.setFillColor(NSColor.black.cgColor)
            context.fillEllipse(in: CGRect(x: 1.5, y: 3.5, width: 15, height: 12.5))
            context.move(to: CGPoint(x: 5.2, y: 6))
            context.addLine(to: CGPoint(x: 3.6, y: 1.4))
            context.addLine(to: CGPoint(x: 10, y: 4.8)); context.closePath(); context.fillPath()
            context.setBlendMode(.clear)
            context.fill(CGRect(x: 0, y: 9.1, width: 18, height: 1.1))
            context.setLineWidth(1.15)
            context.move(to: CGPoint(x: 8.9, y: 0)); context.addLine(to: CGPoint(x: 12.1, y: 18)); context.strokePath()
            return true
        }
        image.isTemplate = true
        return image
    }
}

private enum PanelPalette {
    static func color(_ light: (Double, Double, Double), _ dark: (Double, Double, Double)) -> NSColor {
        NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        }
    }
    static let canvas = NSColor.windowBackgroundColor
    static let surface = color((1, 1, 1), (0.18, 0.18, 0.19))
    static let accent = NSColor.controlAccentColor
    static let selected = NSColor.labelColor.withAlphaComponent(0.045)
    static let action = NSColor.controlAccentColor
    static let actionText = NSColor.white
    static let line = NSColor.labelColor.withAlphaComponent(0.08)
}

private enum PanelPaint {
    static func text(_ text: String, in rect: NSRect, size: CGFloat, weight: NSFont.Weight = .regular,
                     color: NSColor = .labelColor, alignment: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = alignment; paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color, .paragraphStyle: paragraph])
    }
    static func symbol(_ name: String, in rect: NSRect, color: NSColor, weight: NSFont.Weight = .medium) {
        let configuration = NSImage.SymbolConfiguration(pointSize: rect.height, weight: weight)
            .applying(.init(paletteColors: [color]))
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)?
            .draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    static func frame(_ rect: NSRect, radius: CGFloat, fill: NSColor?, stroke: NSColor? = nil) {
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        if let fill { fill.setFill(); path.fill() }
        if let stroke { stroke.setStroke(); path.lineWidth = 1; path.stroke() }
    }
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
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        PanelPaint.frame(bounds, radius: 9, fill: PanelPalette.surface, stroke: PanelPalette.line)
        PanelPalette.line.setFill()
        for y in [37.0, 71.0] { NSRect(x: 10, y: y, width: bounds.width-20, height: 0.5).fill() }
    }
}

private final class PanelPopUpButton: NSPopUpButton {
    private let showsIcon: Bool
    var contextActions: NSMenu?
    private var hovered = false
    private var hoverArea: NSTrackingArea?
    override var isFlipped: Bool { true }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    init(showsIcon: Bool = false) {
        self.showsIcon = showsIcon
        super.init(frame: .zero, pullsDown: true)
        isBordered = false; focusRingType = .none; font = .systemFont(ofSize: 12)
        (cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        (cell as? NSPopUpButtonCell)?.preferredEdge = .maxY
        (cell as? NSPopUpButtonCell)?.altersStateOfSelectedItem = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func menu(for event: NSEvent) -> NSMenu? { contextActions }
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
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func becomeFirstResponder() -> Bool { let accepted = super.becomeFirstResponder(); needsDisplay = true; return accepted }
    override func resignFirstResponder() -> Bool { let accepted = super.resignFirstResponder(); needsDisplay = true; return accepted }
    override func draw(_ dirtyRect: NSRect) {
        let focused = window?.firstResponder === self
        let tint: NSColor? = hovered || isHighlighted ? PanelPalette.selected : nil
        PanelPaint.frame(bounds, radius: 6, fill: tint,
                         stroke: focused ? PanelPalette.accent.withAlphaComponent(0.65) : nil)
        let foreground: NSColor = isEnabled ? .labelColor : .tertiaryLabelColor
        if showsIcon {
            let iconRect = NSRect(x: 9, y: (bounds.height-16)/2, width: 16, height: 16)
            if let image = selectedItem?.image {
                image.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else { PanelPaint.symbol("macwindow", in: iconRect.insetBy(dx: 3, dy: 3), color: .secondaryLabelColor) }
        }
        let textX: CGFloat = showsIcon ? 31 : 10
        PanelPaint.text(titleOfSelectedItem ?? "", in: NSRect(x: textX, y: 6, width: bounds.width-textX-27, height: 18),
                        size: 12, weight: .medium, color: foreground)
        PanelPaint.symbol("chevron.down", in: NSRect(x: bounds.width-19, y: (bounds.height-6)/2, width: 8, height: 6),
                          color: .secondaryLabelColor, weight: .semibold)
    }
}

private class PanelHoverButton: NSButton {
    private(set) var hovered = false
    private var hoverArea: NSTrackingArea?
    override var isFlipped: Bool { true }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false; focusRingType = .none
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func becomeFirstResponder() -> Bool { let accepted = super.becomeFirstResponder(); needsDisplay = true; return accepted }
    override func resignFirstResponder() -> Bool { let accepted = super.resignFirstResponder(); needsDisplay = true; return accepted }
    var keyboardFocused: Bool { window?.firstResponder === self }
}

private final class PanelActionButton: PanelHoverButton {
    static var accent: NSColor { PanelPalette.accent }
    var active = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let fill = active ? PanelPalette.surface : PanelPalette.action
        let foreground: NSColor = active ? .labelColor : PanelPalette.actionText
        PanelPaint.frame(bounds, radius: 9, fill: fill.withAlphaComponent(isHighlighted ? 0.78 : hovered ? 0.90 : 1),
                         stroke: active ? PanelPalette.line : NSColor.white.withAlphaComponent(0.09))
        if keyboardFocused { PanelPaint.frame(bounds.insetBy(dx: 2, dy: 2), radius: 7, fill: nil, stroke: foreground.withAlphaComponent(0.45)) }
        PanelPaint.text(title, in: NSRect(x: 12, y: 9, width: bounds.width-42, height: 18), size: 12, weight: .medium, color: foreground)
        let symbol = active ? (title.contains("停止") ? "stop.fill" : "pause.fill") : "arrow.right"
        PanelPaint.symbol(symbol, in: NSRect(x: bounds.width-24, y: 12, width: 11, height: 11), color: foreground)
    }
}
