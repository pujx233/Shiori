import AppKit
import Carbon

@MainActor
final class ReaderHotkeys {
    enum Action: UInt32 { case edit = 1, undo, redo }
    var onAction: ((Action) -> Void)?
    private var handler: EventHandlerRef?
    private var keys: [EventHotKeyRef] = []
    private(set) var unavailable = false

    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, pointer in
            guard let event, let pointer else { return noErr }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == 0x53686f72, let action = Action(rawValue: id.id) else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<ReaderHotkeys>.fromOpaque(pointer).takeUnretainedValue()
            DispatchQueue.main.async { owner.onAction?(action) }
            return noErr
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard InstallEventHandler(GetApplicationEventTarget(), callback, 1, &type, context, &handler) == noErr else {
            unavailable = true; return
        }
        for (action, code, modifiers) in [(Action.edit, UInt32(kVK_ANSI_E), UInt32(controlKey | optionKey)),
            (.undo, UInt32(kVK_ANSI_Z), UInt32(controlKey | optionKey)),
            (.redo, UInt32(kVK_ANSI_Z), UInt32(controlKey | optionKey | shiftKey))] {
            var key: EventHotKeyRef?
            let id = EventHotKeyID(signature: 0x53686f72, id: action.rawValue)
            if RegisterEventHotKey(code, modifiers, id, GetApplicationEventTarget(), 0, &key) == noErr, let key {
                keys.append(key)
            } else { unavailable = true }
        }
    }
    deinit {
        keys.forEach { UnregisterEventHotKey($0) }
        if let handler { RemoveEventHandler(handler) }
    }
}

@MainActor
final class WorkSettingsPanel: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let chooser = NSPopUpButton()
    private let name = NSTextField()
    private let style = NSTextView()
    private let table = NSTableView()
    private let remove = NSButton()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let profiles: [WorkProfile]
    private var selected: WorkProfile
    private var words: [WorkTerm] = []
    var onSave: ((WorkProfile) throws -> Void)?

    init(profile: WorkProfile, profiles: [WorkProfile], showsStyle: Bool = true) {
        self.selected = profile; self.profiles = profiles
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: showsStyle ? 510 : 420),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "作品用词"; window.isReleasedWhenClosed = false
        super.init(window: window)
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 9
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor)])
        func add(_ view: NSView) {
            root.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true
        }
        add(NSTextField(labelWithString: "作品"))
        for item in profiles {
            chooser.addItem(withTitle: item.title)
            chooser.lastItem?.representedObject = item.id
        }
        chooser.menu?.addItem(.separator())
        chooser.addItem(withTitle: "新建作品…"); chooser.lastItem?.representedObject = "new"
        chooser.addItem(withTitle: "重命名…"); chooser.lastItem?.representedObject = "rename"
        chooser.selectItem(at: profiles.firstIndex(where: { $0.id == profile.id }) ?? 0)
        chooser.target = self; chooser.action = #selector(changed)
        chooser.setAccessibilityLabel("作品"); add(chooser)
        name.placeholderString = "作品名称"; name.setAccessibilityLabel("作品名称")
        name.isHidden = true; add(name)
        style.isRichText = false; style.allowsUndo = true; style.font = .systemFont(ofSize: 13)
        style.textContainerInset = CGSize(width: 6, height: 6)
        style.isVerticallyResizable = true; style.autoresizingMask = .width
        style.textContainer?.widthTracksTextView = true; style.setAccessibilityLabel("翻译风格")
        if showsStyle {
            add(NSTextField(labelWithString: "翻译风格"))
            let scroll = NSScrollView(); scroll.borderType = .bezelBorder; scroll.hasVerticalScroller = true
            scroll.documentView = style; add(scroll); scroll.heightAnchor.constraint(equalToConstant: 65).isActive = true
        }
        add(NSTextField(labelWithString: "译名"))
        for (id, title) in [("source", "原文"), ("translation", "译名")] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title; column.width = 205; column.minWidth = 100
            table.addTableColumn(column)
        }
        table.delegate = self; table.dataSource = self; table.autoresizingMask = [.width]
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.rowHeight = 26; table.allowsMultipleSelection = true
        table.setAccessibilityLabel("译名列表")
        let scroll = NSScrollView(); scroll.borderType = .bezelBorder; scroll.hasVerticalScroller = true
        scroll.documentView = table; add(scroll); scroll.heightAnchor.constraint(equalToConstant: 155).isActive = true
        let plus = NSButton(title: "添加", target: self, action: #selector(addWord)); plus.bezelStyle = .rounded
        remove.title = "删除"; remove.target = self; remove.action = #selector(removeWords)
        remove.bezelStyle = .rounded; remove.isEnabled = false
        let actions = NSStackView(views: [plus, remove]); actions.orientation = .horizontal; actions.spacing = 8
        actions.heightAnchor.constraint(equalToConstant: 24).isActive = true; add(actions)
        status.font = .systemFont(ofSize: 11); status.textColor = .systemRed
        status.maximumNumberOfLines = 2; status.isHidden = true; add(status)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        root.addArrangedSubview(spacer)
        let save = NSButton(title: "保存", target: self, action: #selector(saveProfile))
        save.bezelStyle = .rounded; save.keyEquivalent = "\r"; add(save)
        display(profile); window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func display(_ profile: WorkProfile) {
        selected = profile; name.stringValue = profile.title; style.string = profile.style
        words = profile.terms; name.isHidden = true; status.isHidden = true
        table.reloadData(); remove.isEnabled = false
    }
    @objc private func changed() {
        if let id = chooser.selectedItem?.representedObject as? String,
           let profile = profiles.first(where: { $0.id == id }) { display(profile) }
        else if chooser.selectedItem?.representedObject as? String == "rename" {
            if let index = profiles.firstIndex(where: { $0.id == selected.id }) { chooser.selectItem(at: index) }
            name.isHidden = false; window?.makeFirstResponder(name)
        } else {
            display(WorkProfile(id: "work:" + UUID().uuidString, title: ""))
            name.isHidden = false; window?.makeFirstResponder(name)
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { words.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, words.indices.contains(row) else { return nil }
        let cell = NSTableCellView()
        let text = NSTextField(frame: NSRect(x: 5, y: 3, width: tableColumn.width-10, height: 20))
        text.identifier = tableColumn.identifier; text.tag = row
        text.stringValue = tableColumn.identifier.rawValue == "source" ? words[row].source : words[row].translation
        text.font = .systemFont(ofSize: 13); text.isBordered = false; text.drawsBackground = false
        text.focusRingType = .none; text.delegate = self; text.autoresizingMask = [.width]
        text.setAccessibilityLabel(tableColumn.title)
        cell.addSubview(text); cell.textField = text
        return cell
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, words.indices.contains(field.tag) else { return }
        if field.identifier?.rawValue == "source" { words[field.tag].source = field.stringValue }
        else if field.identifier?.rawValue == "translation" { words[field.tag].translation = field.stringValue }
    }
    func tableViewSelectionDidChange(_ notification: Notification) { remove.isEnabled = !table.selectedRowIndexes.isEmpty }
    private func finishWordEditing() {
        window?.makeFirstResponder(nil)
        for row in words.indices {
            if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView,
               let value = cell.textField?.stringValue { words[row].source = value }
            if let cell = table.view(atColumn: 1, row: row, makeIfNecessary: false) as? NSTableCellView,
               let value = cell.textField?.stringValue { words[row].translation = value }
        }
    }
    @objc private func addWord() {
        finishWordEditing()
        guard words.count < 100 else { status.stringValue = "最多添加 100 条。"; status.isHidden = false; return }
        words.append(WorkTerm(source: "", translation: "")); table.reloadData()
        let row = words.count-1
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
           let field = cell.textField { window?.makeFirstResponder(field) }
    }
    @objc private func removeWords() {
        finishWordEditing()
        for index in table.selectedRowIndexes.reversed() where words.indices.contains(index) { words.remove(at: index) }
        table.reloadData(); remove.isEnabled = false
    }
    @objc private func saveProfile() {
        finishWordEditing()
        do {
            var profile = selected; profile.title = name.stringValue; profile.style = style.string
            guard profile.style.count <= 1000 else { throw AppError.message("翻译风格最多 1000 字。") }
            profile.terms = try WorkProfile.validatedTerms(words)
            try onSave?(profile); close()
        } catch { status.stringValue = error.localizedDescription; status.isHidden = false }
    }
}
