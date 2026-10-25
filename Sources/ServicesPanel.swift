import AppKit

@MainActor
final class ServicesPanel: NSWindowController, NSWindowDelegate {
    private let resources: URL
    private let component = NSTextField(wrappingLabelWithString: "")
    private let storage = NSTextField(wrappingLabelWithString: "正在统计占用…")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let updateStatus = NSTextField(wrappingLabelWithString: "")
    private let indicator = NSProgressIndicator()
    private let cancel = NSButton()
    private let installUpdate = NSButton()
    private var controls: [NSControl] = []
    private var runner: CommandRunner?
    private var operationID: UUID?
    private var release: AppRelease?
    var beforeOperation: (() throws -> Void)?
    var onPauseReading: (() -> Void)?
    var onIdle: (() throws -> Void)?
    var onPermissions: ((Bool) -> Void)?

    init(resources: URL) {
        self.resources = resources
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 410),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "应用设置"; window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        root.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor)])
        func add(_ view: NSView) { root.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -36).isActive = true }
        func heading(_ text: String) { let label = NSTextField(labelWithString: text); label.font = .systemFont(ofSize: 13, weight: .semibold); add(label) }
        func button(_ title: String, _ action: Selector) -> NSButton {
            let button = NSButton(title: title, target: self, action: action); button.bezelStyle = .rounded; controls.append(button); return button
        }
        func buttons(_ buttons: [NSButton]) {
            let row = NSStackView(views: buttons); row.orientation = .horizontal; row.spacing = 8
            row.heightAnchor.constraint(equalToConstant: 24).isActive = true; add(row)
        }
        heading("识字组件")
        component.font = .systemFont(ofSize: 12); add(component)
        var setup = [button(OCRInstallation.isReady ? "修复组件" : "安装组件", #selector(installComponents))]
        if !CGPreflightScreenCaptureAccess() { setup.append(button("允许录屏…", #selector(screenPermission))) }
        if !BrowserContent.hasAccess { setup.append(button("允许辅助功能…", #selector(browserPermission))) }
        buttons(setup)
        let help = NSTextField(wrappingLabelWithString: "首次安装约需 2 GB 空间。")
        help.isHidden = OCRInstallation.isReady
        help.font = .systemFont(ofSize: 11); help.textColor = .secondaryLabelColor; add(help)
        heading("缓存")
        storage.font = .systemFont(ofSize: 12); add(storage)
        buttons([button("清理缓存", #selector(clearCache))])
        heading("更新")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
        updateStatus.stringValue = "当前版本 \(version)"; updateStatus.font = .systemFont(ofSize: 12); add(updateStatus)
        installUpdate.title = "安装更新并重启"; installUpdate.target = self; installUpdate.action = #selector(updateApp)
        installUpdate.bezelStyle = .rounded; installUpdate.isHidden = true; controls.append(installUpdate)
        buttons([button("检查更新", #selector(checkUpdate)), installUpdate, button("发布页…", #selector(openReleases))])
        indicator.style = .bar; indicator.isIndeterminate = true; indicator.isDisplayedWhenStopped = false
        indicator.heightAnchor.constraint(equalToConstant: 4).isActive = true; add(indicator)
        status.font = .systemFont(ofSize: 11); status.maximumNumberOfLines = 3
        status.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true; status.isHidden = true; add(status)
        cancel.title = "取消"; cancel.target = self; cancel.action = #selector(cancelServices)
        cancel.bezelStyle = .rounded; cancel.isEnabled = false; cancel.isHidden = true; add(cancel)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        root.addArrangedSubview(spacer)
        if let support = try? AppStorage.directory(), let error = try? String(contentsOf: support.appendingPathComponent("UpdateError.txt"), encoding: .utf8) {
            status.stringValue = error; status.isHidden = false
        }
        refreshStorage(); window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func windowWillClose(_ notification: Notification) { cancelServices() }
    @objc func cancelServices() { runner?.cancel() }
    private func refreshStorage() {
        component.stringValue = OCRInstallation.isReady ? "已安装" : "尚未安装"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let root = try? AppStorage.directory() else { return }
            let text = AppCacheManager.summary(root: root)
            let size = ByteCountFormatter.string(fromByteCount: AppCacheManager.bytes(root.appendingPathComponent("OCR")), countStyle: .file)
            DispatchQueue.main.async {
                self?.storage.stringValue = text
                if OCRInstallation.isReady { self?.component.stringValue = "已安装 · " + size }
            }
        }
    }
    private func run(_ message: String, reloadOCR: Bool = false,
                     operation: @escaping (CommandRunner, @escaping (String) -> Void) throws -> String,
                     completion: ((String) -> Void)? = nil) {
        guard runner == nil else { return }
        if reloadOCR { onPauseReading?() }
        let task = CommandRunner(), id = UUID(), before = reloadOCR ? beforeOperation : nil
        runner = task; operationID = id; status.stringValue = message; status.isHidden = false; status.textColor = .secondaryLabelColor
        controls.forEach { $0.isEnabled = false }; cancel.isEnabled = true; cancel.isHidden = false; indicator.startAnimation(nil)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let progress: (String) -> Void = { text in DispatchQueue.main.async {
                guard let self, self.operationID == id else { return }; self.status.stringValue = text
            } }
            let result = Result { try before?(); try task.checkCancellation(); return try operation(task, progress) }
            DispatchQueue.main.async {
                guard let self, self.operationID == id else { return }
                self.runner = nil; self.operationID = nil
                self.controls.forEach { $0.isEnabled = true }; self.cancel.isEnabled = false; self.cancel.isHidden = true; self.indicator.stopAnimation(nil)
                do {
                    try task.checkCancellation()
                    let text = try result.get()
                    if reloadOCR { try self.onIdle?() }
                    self.status.stringValue = text; completion?(text)
                    self.status.isHidden = self.status.stringValue.isEmpty
                } catch {
                    self.status.stringValue = error is CancellationError ? "已取消，可稍后继续。" : error.localizedDescription
                    self.status.textColor = error is CancellationError ? .secondaryLabelColor : .systemRed
                }
                self.refreshStorage()
            }
        }
    }
    @objc private func installComponents() {
        run("正在准备本地识字组件…", reloadOCR: true, operation: { [resources] runner, progress in
            try OCRInstallation.install(resources: resources, runner: runner, progress: progress)
            return "组件已就绪。"
        })
    }
    @objc private func clearCache() {
        run("正在清理自动缓存…", reloadOCR: true, operation: { _, _ in
            let removed = try AppCacheManager.clear(root: AppStorage.directory())
            return "已清理 \(ByteCountFormatter.string(fromByteCount: removed, countStyle: .file)) 缓存。"
        })
    }
    @objc private func screenPermission() { onPermissions?(false) }
    @objc private func browserPermission() { onPermissions?(true) }
    @objc private func openReleases() { NSWorkspace.shared.open(URL(string: "https://github.com/pujx233/Shiori/releases")!) }
    @objc private func checkUpdate() {
        run("正在检查 GitHub 发行版…", operation: { runner, _ in
            let release = try AppUpdater.latest(runner: runner)
            return String(decoding: try JSONEncoder().encode(ReleaseTransfer(release)), as: UTF8.self)
        }, completion: { [weak self] text in
            guard let self, let data = text.data(using: .utf8), let transfer = try? JSONDecoder().decode(ReleaseTransfer.self, from: data),
                  let remote = ReleaseVersion(transfer.release.tag_name),
                  let local = ReleaseVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0") else { return }
            self.release = transfer.release
            self.installUpdate.isHidden = remote <= local
            self.updateStatus.stringValue = remote > local ? "发现新版本 \(transfer.release.tag_name)" : "当前已是最新版本"
            self.status.stringValue = remote > local ? "下载完成后将重启 Shiori。" : ""
        })
    }
    @objc private func updateApp() {
        guard let release else { return }
        run("正在准备更新…", operation: { [resources] runner, progress in
            try AppUpdater.prepare(release, resources: resources, runner: runner, progress: progress).path
        }, completion: { [weak self] path in
            guard let self else { return }
            do {
                guard FileManager.default.isWritableFile(atPath: Bundle.main.bundleURL.deletingLastPathComponent().path) else {
                    throw AppError.message("无法写入应用所在文件夹，请从 GitHub 发布页手动安装。")
                }
                let helper = Process(); helper.executableURL = URL(fileURLWithPath: "/bin/zsh")
                helper.arguments = [self.resources.appendingPathComponent("apply_update.sh").path,
                    String(ProcessInfo.processInfo.processIdentifier), path, Bundle.main.bundleURL.path,
                    try AppStorage.directory().path]
                helper.standardOutput = FileHandle.nullDevice; helper.standardError = FileHandle.nullDevice
                try helper.run(); NSApp.terminate(nil)
            } catch { self.status.stringValue = error.localizedDescription }
        })
    }
}

// A value crosses the worker/UI boundary without exposing mutable state there.
private struct ReleaseTransfer: Codable {
    let release: AppRelease
    init(_ release: AppRelease) { self.release = release }
}
