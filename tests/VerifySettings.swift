import AppKit
import WebKit

private struct SettingsFailure: Error { let message: String }
private final class SettingsWidget: WidgetWindow {
    var created = 0
    var closed = 0
    override func browserDidCreate(_ browser: PerchWebView) { created += 1 }
    override func browserWillClose(_ browser: PerchWebView) { closed += 1 }
}

@MainActor
private final class SettingsVerification: NSObject, NSApplicationDelegate {
    let suite = "local.perch.settings-verification.\(UUID().uuidString)"
    var widgets: [SettingsWidget] = []
    var perch: PerchController!
    var checks = 0
    var extra = false
    var extraActions = 0
    var navigationActions = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do {
                try await verify()
                for widget in widgets { widget.close() }
                UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite)
                print("Completed \(checks) registry/settings native checks. Three isolated widgets, no accounts.")
                exit(0)
            } catch {
                print("FAIL \(error)")
                for widget in widgets { widget.close() }
                UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite)
                exit(1)
            }
        }
    }
    func check(_ name: String, _ condition: Bool) throws {
        guard condition else { throw SettingsFailure(message: name) }
        checks += 1; print("PASS \(name)"); fflush(stdout)
    }
    func pause() async throws { try await Task.sleep(nanoseconds: 250_000_000) }
    func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { views($0) } }
    func control<T: NSControl>(_ id: String, _ type: T.Type) throws -> T {
        guard let control = views(perch.window.contentView!).first(where: { $0.identifier?.rawValue == id }) as? T else {
            throw SettingsFailure(message: "Missing control \(id)")
        }
        return control
    }
    func send(_ control: NSControl) { _ = control.sendAction(control.action, to: control.target) }
    func invoke(_ item: NSMenuItem) { NSApp.sendAction(item.action!, to: item.target, from: item) }
    func verify() async throws {
        let defaults = UserDefaults(suiteName: suite)!
        widgets = ["one", "two", "third"].map { name in
            SettingsWidget(id: name, title: name == "third" ? "Future Widget" : name.capitalized,
                           home: URL(string: "about:blank")!, prefix: name, originKeys: (name+"X", name+"Y"), script: "", defaults: defaults, dataStore: .nonPersistent())
        }
        let registrations = widgets.enumerated().map { index, widget in
            WidgetRegistration(widget: widget, help: "Local fixture \(index + 1)", shortcut: String(index + 1),
                settings: [.toggle(title: "Extra toggle", get: { self.extra }, set: { self.extra = $0 }),
                           .action(WidgetAction(title: "Extra action", perform: { self.extraActions += 1 })),
                           .note("An app-specific note")],
                menuActions: [WidgetAction(title: "Extra menu \(index)", isOn: { self.extra }, perform: { self.extra.toggle() })],
                navigationActions: [WidgetAction(title: "Navigate \(index)", perform: { self.navigationActions += 1 })])
        }
        perch = PerchController(registrations: registrations)
        perch.install()
        try check("All three registrations appear in sidebar", perch.sidebar.numberOfRows == 3)
        try check("Initial selection creates no page", widgets.allSatisfy { $0.created == 0 })
        perch.selectRegistration(id: "third")
        try check("Third widget settings selected without enabling", perch.selectedID == "third" && !widgets[2].isEnabled)
        perch.window.layoutIfNeeded()
        try check("Selected app controls use accessibility Enable label", try control("third-enabled", NSSwitch.self).accessibilityLabel() == "Enable Future Widget")
        try check("Reload is disabled while off", !(try control("third-reload", NSButton.self)).isEnabled)
        let initialFrame = perch.window.frame
        let appearance = try control("third-appearance", NSSegmentedControl.self)
        for index in Theme.allCases.indices {
            appearance.selectedSegment = index; send(appearance)
            perch.window.layoutIfNeeded()
            try check("Appearance \(index) persists while off without creating page or moving settings", widgets[2].theme == Theme.allCases[index] && !widgets[2].isEnabled && perch.window.frame == initialFrame)
        }
        appearance.selectedSegment = 0; send(appearance)
        let frost = try control("third-frost", NSSegmentedControl.self)
        frost.selectedSegment = 0; send(frost)
        try check("Common Frost changes the registered widget", widgets[2].frost == 0)
        let front = try control("third-front", NSSwitch.self)
        front.state = .off; send(front)
        try check("Common Keep in Front changes registered widget", !widgets[2].keepsInFront)
        let focusClick = try control("third-focus-click", NSSwitch.self)
        try check("Common first-click setting has a stable ID, accessible label, and default", focusClick.accessibilityLabel() == "First click focuses Future Widget" && focusClick.state == .on)
        focusClick.state = .off; send(focusClick)
        try check("First-click setting changes while disabled without creating a browser", !widgets[2].focusBeforeInteraction && widgets.allSatisfy { $0.created == 0 && $0.webView == nil })
        let restored = SettingsWidget(id: "restored-third", title: "Restored Future Widget", home: URL(string: "about:blank")!, prefix: "third", originKeys: ("thirdX", "thirdY"), script: "", defaults: defaults, dataStore: .nonPersistent())
        let restoredFirst = SettingsWidget(id: "restored-one", title: "Restored One", home: URL(string: "about:blank")!, prefix: "one", originKeys: ("oneX", "oneY"), script: "", defaults: defaults, dataStore: .nonPersistent())
        try check("First-click choice persists independently for a generic third widget", !restored.focusBeforeInteraction && restoredFirst.focusBeforeInteraction && restored.created == 0 && restoredFirst.created == 0 && widgets[0].focusBeforeInteraction && widgets[1].focusBeforeInteraction)
        widgets[0].setFocusBeforeInteraction(false)
        perch.selectRegistration(id: "one")
        try check("Changing selection refreshes that app's first-click setting", try control("one-focus-click", NSSwitch.self).state == .off && !widgets[0].isEnabled)
        let firstFocusClick = try control("one-focus-click", NSSwitch.self)
        firstFocusClick.state = .on; send(firstFocusClick)
        perch.selectRegistration(id: "third")
        try check("Returning to another app retains its independent first-click switch", try control("third-focus-click", NSSwitch.self).state == .off && widgets[0].focusBeforeInteraction && !widgets[2].focusBeforeInteraction)
        let extraControl = try control("third-extra-0", NSSwitch.self)
        extraControl.state = .on; send(extraControl)
        send(try control("third-extra-1", NSButton.self))
        try check("Third widget extra controls execute metadata closures", extra && extraActions == 1)
        let enable = try control("third-enabled", NSSwitch.self)
        enable.state = .on; send(enable)
        try await pause()
        try check("Enable creates only selected widget browser", widgets[2].created == 1 && widgets[2].isEnabled && widgets[0].created == 0)
        try check("Reload becomes available when enabled", try control("third-reload", NSButton.self).isEnabled)
        enable.state = .off; send(enable)
        try await pause()
        try check("Disable disposes page through shared lifecycle", widgets[2].webView == nil && widgets[2].closed == 1)
        perch.menuNeedsUpdate(perch.statusMenu)
        let appItems = perch.statusMenu.items.filter { $0.submenu != nil }
        try check("Tray includes future third app without renderer changes", appItems.map(\.title) == ["One", "Two", "Future Widget"])
        let future = appItems[2].submenu!
        try check("Each tray app offers Focus, Enabled, Configure", future.items.filter { !$0.isSeparatorItem }.map(\.title) == ["Focus", "Enabled", "Configure…"])
        invoke(future.items.first { $0.title == "Configure…" }!)
        try await pause()
        perch.window.layoutIfNeeded()
        let appTitle = views(perch.window.contentView!).compactMap { $0 as? NSTextField }.first { $0.stringValue == "Future Widget" && $0.font?.pointSize == 22 }!
        let enableVisible = try control("third-enabled", NSSwitch.self).visibleRect
        try check("App header and Enable are visible at top on selection", !appTitle.visibleRect.intersection(appTitle.bounds).isEmpty && !enableVisible.isEmpty)
        perch.window.setContentSize(NSSize(width: 700, height: 520))
        perch.selectRegistration(id: "one"); perch.selectRegistration(id: "third")
        perch.window.layoutIfNeeded()
        let tallTitle = views(perch.window.contentView!).compactMap { $0 as? NSTextField }.first { $0.stringValue == "Future Widget" && $0.font?.pointSize == 22 }!
        try check("Tall settings start at app header rather than bottom", !tallTitle.visibleRect.intersection(tallTitle.bounds).isEmpty && tallTitle.superview!.superview!.isFlipped)
        perch.window.setFrame(initialFrame, display: true)
        perch.window.layoutIfNeeded()
        try check("Configure selects app while leaving it off", perch.selectedID == "third" && !widgets[2].isEnabled)
        invoke(future.items.first { $0.title == "Focus" }!)
        try await pause()
        try check("Tray Focus enables and reveals app", widgets[2].isEnabled && widgets[2].panel.isVisible)
        perch.menuNeedsUpdate(perch.statusMenu)
        try check("Tray checked state reflects enabled browser", perch.statusMenu.items[2].state == .on)
        let view = NSApp.mainMenu!.items.first { $0.title == "View" }!.submenu!
        let shortcut = view.items.first { $0.title == "Future Widget" }!
        invoke(shortcut); invoke(shortcut)
        try check("Registry shortcut always focuses without toggling off", shortcut.keyEquivalent == "3" && widgets[2].isEnabled && widgets[2].created == 2)
        perch.window.makeKeyAndOrderFront(nil)
        let go = NSApp.mainMenu!.items.first { $0.title == "Go" }!.submenu!
        try check("Go actions are disabled while settings is focused", go.items.filter { $0.action != nil }.allSatisfy { !perch.validateMenuItem($0) })
        widgets[2].focus()
        try await pause()
        let navigation = go.items.first { $0.title == "Navigate 2" }!
        try check("Optional navigation only targets focused registration", perch.validateMenuItem(navigation) && !perch.validateMenuItem(go.items.first { $0.title == "Navigate 0" }!))
        invoke(navigation)
        try check("Registry navigation action executes", navigationActions == 1)
        widgets[2].close()
        perch.selectRegistration(id: "one"); perch.selectRegistration(id: "third")
        try check("Returning to settings reflects persisted common controls", try control("third-front", NSSwitch.self).state == .off && control("third-frost", NSSegmentedControl.self).selectedSegment == 0 && control("third-focus-click", NSSwitch.self).state == .off)
        try check("Settings window keeps steady frame through selection and updates", perch.window.frame == initialFrame)
    }
}

@main struct VerifySettings {
    static func main() {
        let app = NSApplication.shared
        let delegate = SettingsVerification()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
