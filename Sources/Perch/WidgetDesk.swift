import AppKit

/// A rounded settings group like the ones in System Settings.
final class FormGroup: NSView {
    let stack = NSStackView()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = (dark ? NSColor.white.withAlphaComponent(0.05) : NSColor.black.withAlphaComponent(0.03)).cgColor
        layer?.borderColor = (dark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.08)).cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    @discardableResult
    func addRow(_ title: String, _ control: NSView, bold: Bool = false) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = bold ? .systemFont(ofSize: 13, weight: .semibold) : .systemFont(ofSize: 13)
        return addRow(leading: label, trailing: control)
    }

    @discardableResult
    func addRow(leading: NSView?, trailing: NSView) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        if !stack.arrangedSubviews.isEmpty {
            let line = NSBox()
            line.boxType = .separator
            line.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(line)
            NSLayoutConstraint.activate([
                line.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
                line.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
                line.topAnchor.constraint(equalTo: row.topAnchor),
            ])
        }
        trailing.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(trailing)
        var constraints = [
            row.heightAnchor.constraint(equalToConstant: 40),
            trailing.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
            trailing.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ]
        if let leading {
            leading.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(leading)
            constraints += [
                leading.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
                leading.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                trailing.leadingAnchor.constraint(greaterThanOrEqualTo: leading.trailingAnchor, constant: 12),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return row
    }
}

/// Targets retained by the settings view, with native controls as their senders.
private final class SettingsBinding: NSObject {
    let invoke: (NSControl) -> Void
    init(_ invoke: @escaping (NSControl) -> Void) { self.invoke = invoke }
    @objc func run(_ sender: NSControl) { invoke(sender) }
}

private final class SettingsStack: NSStackView {
    override var isFlipped: Bool { true }
}

final class WidgetDetail: NSObject {
    let registration: WidgetRegistration
    let stack: NSStackView = SettingsStack()
    private var bindings: [SettingsBinding] = []
    private var refreshers: [() -> Void] = []
    private let changed: () -> Void

    init(_ registration: WidgetRegistration, changed: @escaping () -> Void) {
        self.registration = registration
        self.changed = changed
        super.init()
        let widget = registration.widget
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(image: registration.icon)
        icon.widthAnchor.constraint(equalToConstant: 40).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 40).isActive = true
        let title = NSTextField(labelWithString: widget.title)
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let heading = NSStackView(views: [icon, title])
        heading.spacing = 12
        stack.addArrangedSubview(heading)
        note(registration.help)
        let common = FormGroup()
        addGroup(common)
        let enabled = toggle("Enable \(widget.title)", id: "enabled", get: { widget.isEnabled }) { on in
            if on { widget.show() } else { widget.close() }
        }
        common.addRow("Enabled", enabled)
        let appearance = NSSegmentedControl(labels: Theme.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
        appearance.segmentStyle = .automatic
        bind(appearance, id: "appearance", label: "\(widget.title) appearance") { control in
            let index = (control as! NSSegmentedControl).selectedSegment
            if Theme.allCases.indices.contains(index) { widget.setTheme(Theme.allCases[index]) }
        }
        refreshers.append { appearance.selectedSegment = Theme.allCases.firstIndex(of: widget.theme) ?? 0 }
        common.addRow("Appearance", appearance)
        let frost = NSSegmentedControl(labels: ["Clear", "Frosted"], trackingMode: .selectOne, target: nil, action: nil)
        bind(frost, id: "frost", label: "\(widget.title) glass material") { control in
            widget.setFrost((control as! NSSegmentedControl).selectedSegment == 0 ? 0 : 1)
        }
        let frostRow = common.addRow("Frost", frost)
        refreshers.append {
            frost.selectedSegment = widget.frost >= 0.5 ? 1 : 0
            frostRow.isHidden = widget.theme != .glass
        }
        common.addRow("Keep in Front", toggle("Keep \(widget.title) in front", id: "front", get: { widget.keepsInFront }, set: widget.setKeepsInFront))
        common.addRow("First Click Focuses", toggle("First click focuses \(widget.title)", id: "focus-click", get: { widget.focusBeforeInteraction }, set: widget.setFocusBeforeInteraction))
        note("When on, the first click focuses the widget and the next click interacts. When off, controls respond immediately.")
        note("Disabling the widget closes its page and stops playback. Your settings and sign-in are kept.")
        let actions = FormGroup()
        addGroup(actions)
        actions.addRow("Show widget", button(WidgetAction(title: "Focus Widget", perform: { widget.focus() }), id: "focus"))
        actions.addRow("Refresh page", button(WidgetAction(title: "Reload", isEnabled: { widget.isEnabled }, perform: { widget.reload() }), id: "reload"))
        if !registration.settings.isEmpty {
            let extras = FormGroup()
            addGroup(extras)
            for (index, setting) in registration.settings.enumerated() {
                switch setting {
                case let .toggle(title, get, set): extras.addRow(title, toggle(title, id: "extra-\(index)", get: get, set: set))
                case let .action(action): extras.addRow(leading: nil, trailing: button(action, id: "extra-\(index)"))
                case let .note(text): note(text)
                }
            }
        }
        refresh()
    }
    private func addGroup(_ group: FormGroup) {
        stack.addArrangedSubview(group)
        group.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
    }
    private func note(_ text: String) {
        guard !text.isEmpty else { return }
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        stack.addArrangedSubview(label)
        label.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
    }
    private func bind(_ control: NSControl, id: String, label: String, invoke: @escaping (NSControl) -> Void) {
        let binding = SettingsBinding { [weak self] sender in invoke(sender); self?.changed() }
        bindings.append(binding)
        control.target = binding
        control.action = #selector(SettingsBinding.run(_:))
        control.identifier = NSUserInterfaceItemIdentifier("\(registration.widget.id)-\(id)")
        control.setAccessibilityLabel(label)
    }
    private func toggle(_ label: String, id: String, get: @escaping () -> Bool, set: @escaping (Bool) -> Void) -> NSSwitch {
        let control = NSSwitch()
        control.controlSize = .small
        bind(control, id: id, label: label) { set(($0 as! NSSwitch).state == .on) }
        refreshers.append { control.state = get() ? .on : .off }
        return control
    }
    private func button(_ action: WidgetAction, id: String) -> NSButton {
        let control = NSButton(title: action.title, target: nil, action: nil)
        control.bezelStyle = .push
        control.controlSize = .small
        bind(control, id: id, label: action.title) { _ in if action.isEnabled() { action.perform() } }
        refreshers.append { control.isEnabled = action.isEnabled() }
        return control
    }
    func refresh() { refreshers.forEach { $0() } }
}

final class PerchController: NSObject, NSWindowDelegate, NSMenuDelegate, NSMenuItemValidation, NSTableViewDataSource, NSTableViewDelegate {
    let registrations: [WidgetRegistration]
    let window: NSWindow
    let sidebar = NSTableView()
    private(set) var selectedID: String?
    private let detailScroll = NSScrollView()
    private var detail: WidgetDetail?
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let statusMenu = NSMenu()

    init(registrations: [WidgetRegistration]) {
        self.registrations = registrations
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 620),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Perch"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.titlebarSeparatorStyle = .none
        window.tabbingMode = .disallowed
        window.contentMinSize = NSSize(width: 700, height: 520)
    }
    func install() {
        buildWindow()
        buildMenus()
        WidgetWindow.onChange = { [weak self] in self?.refresh() }
        refresh()
        if !window.setFrameUsingName("PerchSettings") { window.center() }
        // Older releases saved a narrower settings form.
        if let content = window.contentView, content.bounds.width < 700 || content.bounds.height < 520 {
            window.setContentSize(NSSize(width: 700, height: 620))
        }
        window.setFrameAutosaveName("PerchSettings")
    }
    private func buildWindow() {
        guard let content = window.contentView else { return }
        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .behindWindow
        let list = NSScrollView()
        list.drawsBackground = false
        list.hasVerticalScroller = true
        sidebar.addTableColumn(NSTableColumn(identifier: .init("apps")))
        sidebar.headerView = nil
        sidebar.rowHeight = 58
        sidebar.intercellSpacing = NSSize(width: 0, height: 2)
        sidebar.style = .sourceList
        sidebar.backgroundColor = .clear
        sidebar.dataSource = self
        sidebar.delegate = self
        sidebar.allowsEmptySelection = false
        sidebar.setAccessibilityLabel("Widget apps")
        list.documentView = sidebar
        background.addSubview(list)
        detailScroll.drawsBackground = false
        detailScroll.hasVerticalScroller = true
        content.addSubview(background)
        content.addSubview(detailScroll)
        let divider = NSBox(); divider.boxType = .separator
        content.addSubview(divider)
        for view in [background, list, detailScroll, divider] { view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: content.leadingAnchor), background.topAnchor.constraint(equalTo: content.topAnchor), background.bottomAnchor.constraint(equalTo: content.bottomAnchor), background.widthAnchor.constraint(equalToConstant: 200),
            list.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 8), list.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -8), list.topAnchor.constraint(equalTo: background.topAnchor, constant: 12), list.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -12),
            divider.leadingAnchor.constraint(equalTo: background.trailingAnchor), divider.topAnchor.constraint(equalTo: content.topAnchor), divider.bottomAnchor.constraint(equalTo: content.bottomAnchor), divider.widthAnchor.constraint(equalToConstant: 1),
            detailScroll.leadingAnchor.constraint(equalTo: divider.trailingAnchor), detailScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor), detailScroll.topAnchor.constraint(equalTo: content.topAnchor), detailScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        sidebar.reloadData()
        if !registrations.isEmpty { sidebar.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false); selectRegistration(id: registrations[0].widget.id) }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { registrations.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let registration = registrations[row]
        let cell = NSTableCellView()
        let image = NSImageView(image: registration.icon)
        let title = NSTextField(labelWithString: registration.widget.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        let status = NSTextField(labelWithString: registration.widget.isEnabled ? "Enabled" : "Off")
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [title, status]); labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 3
        for view in [image, labels] { cell.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8), image.centerYAnchor.constraint(equalTo: cell.centerYAnchor), image.widthAnchor.constraint(equalToConstant: 28), image.heightAnchor.constraint(equalToConstant: 28), labels.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 10), labels.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4), labels.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        cell.setAccessibilityLabel("Select \(registration.widget.title), \(registration.widget.isEnabled ? "enabled" : "off")")
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard registrations.indices.contains(sidebar.selectedRow) else { return }
        selectRegistration(id: registrations[sidebar.selectedRow].widget.id)
    }
    func selectRegistration(id: String) {
        guard let index = registrations.firstIndex(where: { $0.widget.id == id }) else { return }
        if sidebar.selectedRow != index { sidebar.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        guard selectedID != id else { return }
        selectedID = id
        let next = WidgetDetail(registrations[index]) { [weak self] in self?.refresh() }
        detail = next
        detailScroll.documentView = next.stack
        next.stack.widthAnchor.constraint(equalTo: detailScroll.contentView.widthAnchor).isActive = true
        next.stack.layoutSubtreeIfNeeded()
        detailScroll.contentView.scroll(to: .zero)
    }
    private func refresh() {
        detail?.refresh()
        // Update status text without disturbing selection or keyboard focus.
        if sidebar.numberOfRows > 0 { sidebar.reloadData(forRowIndexes: IndexSet(integersIn: 0..<registrations.count), columnIndexes: IndexSet(integer: 0)) }
    }
    private func add(_ action: WidgetAction, to menu: NSMenu) {
        let item = menu.addItem(withTitle: action.title, action: #selector(runMenu(_:)), keyEquivalent: action.key)
        item.target = self
        item.keyEquivalentModifierMask = action.modifiers
        item.representedObject = MenuInvocation(action)
        item.isEnabled = action.isEnabled()
        item.state = action.isOn?() == true ? .on : .off
    }
    @objc private func runMenu(_ item: NSMenuItem) {
        guard let action = (item.representedObject as? MenuInvocation)?.action, action.isEnabled() else { return }
        action.perform()
        refresh()
    }
    private func buildMenus() {
        let main = NSMenu()
        let app = NSMenu(title: "Perch")
        app.addItem(withTitle: "About Perch", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(showWindow), keyEquivalent: ",").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Perch", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hide = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hide.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Perch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: app, title: "Perch")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z").keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu: edit, title: "Edit")
        let view = NSMenu(title: "View"); view.delegate = self
        for registration in registrations {
            add(WidgetAction(title: registration.widget.title, key: registration.shortcut, perform: { registration.widget.focus() }), to: view)
        }
        for registration in registrations where !registration.menuActions.isEmpty {
            view.addItem(.separator())
            for action in registration.menuActions { add(action, to: view) }
        }
        main.addItem(submenu: view, title: "View")
        let go = NSMenu(title: "Go"); go.delegate = self
        add(WidgetAction(title: "Back", key: "[", isEnabled: { [weak self] in self?.focused?.webView?.canGoBack == true }, perform: { [weak self] in self?.focused?.goBack() }), to: go)
        add(WidgetAction(title: "Forward", key: "]", isEnabled: { [weak self] in self?.focused?.webView?.canGoForward == true }, perform: { [weak self] in self?.focused?.goForward() }), to: go)
        for registration in registrations {
            for action in registration.navigationActions {
                add(WidgetAction(title: action.title, key: action.key, modifiers: action.modifiers,
                                 isEnabled: { [weak self] in self?.focused === registration.widget && action.isEnabled() },
                                 isOn: action.isOn, perform: action.perform), to: go)
            }
        }
        go.addItem(.separator())
        add(WidgetAction(title: "Reload", key: "r", isEnabled: { [weak self] in self?.focused != nil }, perform: { [weak self] in self?.focused?.reload() }), to: go)
        main.addItem(submenu: go, title: "Go")
        let windows = NSMenu(title: "Window")
        windows.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(withTitle: "Close", action: #selector(closeKey), keyEquivalent: "w").target = self
        windows.addItem(.separator())
        windows.addItem(withTitle: "Perch Settings", action: #selector(showWindow), keyEquivalent: "").target = self
        main.addItem(submenu: windows, title: "Window")
        NSApp.windowsMenu = windows
        NSApp.mainMenu = main
        statusItem.button?.image = StatusIcon.image()
        statusItem.button?.toolTip = "Perch"
        statusMenu.delegate = self
        statusItem.menu = statusMenu
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === statusMenu {
            menu.removeAllItems()
            for registration in registrations {
                let widget = registration.widget
                let actions = NSMenu(title: widget.title)
                add(WidgetAction(title: "Focus", perform: { widget.focus() }), to: actions)
                add(WidgetAction(title: "Enabled", isOn: { widget.isEnabled }, perform: {
                    if widget.isEnabled { widget.close() } else { widget.show() }
                }), to: actions)
                actions.addItem(.separator())
                add(WidgetAction(title: "Configure…", perform: { [weak self] in self?.configure(id: widget.id) }), to: actions)
                let item = NSMenuItem(title: widget.title, action: nil, keyEquivalent: "")
                let icon = registration.icon.copy() as! NSImage
                icon.size = NSSize(width: 18, height: 18)
                item.image = icon
                item.state = widget.isEnabled ? .on : .off
                item.submenu = actions
                menu.addItem(item)
            }
            menu.addItem(.separator())
            menu.addItem(withTitle: "Settings…", action: #selector(showWindow), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Perch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        }
        for item in menu.items {
            if let action = (item.representedObject as? MenuInvocation)?.action {
                item.isEnabled = action.isEnabled()
                item.state = action.isOn?() == true ? .on : .off
            }
        }
    }
    private var focused: WidgetWindow? {
        let enabled = registrations.map(\.widget).filter(\.isEnabled)
        return enabled.first { $0.panel.isKeyWindow } ?? enabled.first { $0.panel.isMainWindow }
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let action = (item.representedObject as? MenuInvocation)?.action else { return true }
        item.state = action.isOn?() == true ? .on : .off
        return action.isEnabled()
    }
    @objc private func closeKey() {
        if let focused { focused.close() } else { window.performClose(nil) }
    }
    func configure(id: String) { selectRegistration(id: id); showWindow() }
    @objc func showWindow() {
        refresh()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

private final class MenuInvocation: NSObject {
    let action: WidgetAction
    init(_ action: WidgetAction) { self.action = action }
}

extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
