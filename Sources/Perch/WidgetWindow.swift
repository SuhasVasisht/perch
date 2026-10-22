import AppKit
import ObjectiveC
import WebKit

enum Theme: String, CaseIterable {
    case glass
    case dark
    case light

    var title: String {
        switch self {
        case .glass: return "Glass"
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }
}

let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

final class FloatingPanel: NSPanel {
    var focusBeforeInteraction = true
    var beforeActivation: (() -> Void)?
    private var activationButton: Int?
    override func sendEvent(_ event: NSEvent) {
        let downs: Set<NSEvent.EventType> = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        let ups: Set<NSEvent.EventType> = [.leftMouseUp, .rightMouseUp, .otherMouseUp]
        let drags: Set<NSEvent.EventType> = [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if downs.contains(event.type) { activationButton = nil }
        if downs.contains(event.type) && (!isKeyWindow || !NSApp.isActive) {
            beforeActivation?()
            NSApp.activate(ignoringOtherApps: true)
            makeKeyAndOrderFront(nil)
            if focusBeforeInteraction {
                activationButton = event.buttonNumber
                return
            }
        }
        if activationButton == event.buttonNumber && (ups.contains(event.type) || drags.contains(event.type)) {
            if ups.contains(event.type) { activationButton = nil }
            return
        }
        super.sendEvent(event)
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// A web view with widget context-menu items and mouse-button Back.
final class PerchWebView: WKWebView {
    var extraMenuItems: (() -> [NSMenuItem])?
    var onBack: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        (window as? FloatingPanel)?.focusBeforeInteraction == false
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        let items = (extraMenuItems?() ?? []).filter { item in
            !menu.items.contains { $0.action == item.action && $0.target === item.target }
        }
        guard !items.isEmpty else { return }
        if !menu.items.isEmpty { menu.insertItem(.separator(), at: 0) }
        for item in items.reversed() { menu.insertItem(item, at: 0) }
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 3, let onBack {
            onBack()
            return
        }
        super.otherMouseUp(with: event)
    }
}

final class MessageBridge: NSObject, WKScriptMessageHandler {
    weak var owner: WidgetWindow?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.receive(message.body)
    }
}

/// Page-side message bridge shared by every widget. Moving and resizing use native chrome.
enum PerchScript {
    static let prelude = #"""
    // Common native-control semantics for widget event handlers. Each site can
    // add its own custom-element hosts without changing Perch's drag behavior.
    window.__perchInteractive = 'a, button, input, textarea, select, summary, audio, video, [contenteditable]:not([contenteditable="false"]), [role="button"], [role="slider"], [role="link"], [role="tab"], [role="textbox"], [role="combobox"], [role="menuitem"], [role="menuitemcheckbox"], [role="menuitemradio"], [role="checkbox"], [role="radio"], [role="switch"], [role="spinbutton"]';
    window.__perchPost = (body) => {
      try { window.webkit.messageHandlers.perch.postMessage(body); } catch (e) {}
    };
    // Widgets are controls, not selectable documents. Search and other editors
    // retain normal caret and selection behavior.
    const perchEditors = 'input, textarea, [contenteditable]:not([contenteditable="false"])';
    const perchStyle = document.createElement('style');
    perchStyle.id = 'perch-interaction-style';
    perchStyle.textContent = `
      *, *::before, *::after {
        -webkit-user-select: none !important; user-select: none !important;
        -webkit-user-drag: none !important;
      }
      input, textarea, [contenteditable]:not([contenteditable="false"]),
      [contenteditable]:not([contenteditable="false"]) * {
        -webkit-user-select: text !important; user-select: text !important;
      }
      :focus, :focus-visible { outline: none !important; }
    `;
    (document.head || document.documentElement).appendChild(perchStyle);
    const perchEditorTarget = event => event.composedPath().some(node => node instanceof Element && node.matches(perchEditors));
    document.addEventListener('selectstart', event => {
      if (!perchEditorTarget(event)) event.preventDefault();
    }, true);
    document.addEventListener('dragstart', event => {
      if (!perchEditorTarget(event)) event.preventDefault();
    }, true);
    """#
}

/// One borderless, draggable widget window that hosts a single web page.
/// Owns the glass or solid backing, per-widget appearance settings, window
/// placement, and the Google sign-in popup.
class WidgetWindow: NSObject, WKNavigationDelegate, WKUIDelegate {
    let id: String
    let title: String
    let home: URL
    let defaults: UserDefaults
    let panel = FloatingPanel(
        contentRect: NSRect(x: 0, y: 0, width: 420, height: 400),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    private(set) var webView: PerchWebView?
    private let pageScript: String
    private let dataStore: WKWebsiteDataStore
    private var hasBeenPlaced = false
    private(set) var chrome: WidgetChromeController!
    private let glass = NSVisualEffectView()
    private let solid = NSView()
    private let bridge = MessageBridge()
    private let popupClose = NSButton()
    private var popup: WKWebView?
    private var popupSawGoogle = false
    private var pageConstraints: [NSLayoutConstraint] = []
    private let prefix: String
    private let originKeys: (x: String, y: String)
    private var browserActive = false
    let cornerRadius: CGFloat = 22

    private(set) var theme: Theme = .glass
    private(set) var frost: Double = 0.9
    private(set) var keepsInFront = true

    /// Called after every visibility change so menus and the Perch window stay in sync.
    static var onChange: (() -> Void)?
    private(set) static var all: [String: WidgetWindow] = [:]

    var isVisible: Bool { panel.isVisible }
    var isEnabled: Bool { webView != nil }
    var focusBeforeInteraction: Bool { panel.focusBeforeInteraction }
    /// Only explicit chrome input counts. AppKit also reports automatic frame animations as live resizing.
    var isUserResizing: Bool { chrome?.isResizing == true }
    var wasOpen: Bool { defaults.object(forKey: "\(prefix)Open") as? Bool ?? true }

    init(id: String, title: String, home: URL, prefix: String, originKeys: (x: String, y: String), script: String,
         focusBeforeInteraction: Bool = true,
         defaults: UserDefaults = .standard, dataStore: WKWebsiteDataStore = .default()) {
        self.id = id
        self.title = title
        self.home = home
        self.defaults = defaults
        self.prefix = prefix
        self.originKeys = originKeys
        self.pageScript = script
        self.dataStore = dataStore
        super.init()

        let storedTheme = defaults.string(forKey: "\(prefix)Theme") ?? defaults.string(forKey: "theme") ?? ""
        theme = Theme(rawValue: storedTheme) ?? .glass
        if defaults.object(forKey: "\(prefix)Frost") != nil {
            frost = min(max(defaults.double(forKey: "\(prefix)Frost"), 0), 1)
        } else if defaults.object(forKey: "glassCover") != nil {
            frost = min(max(defaults.double(forKey: "glassCover"), 0), 1)
        }
        keepsInFront = defaults.object(forKey: "\(prefix)KeepInFront") as? Bool
            ?? defaults.object(forKey: "keepInFront") as? Bool
            ?? true
        panel.focusBeforeInteraction = defaults.object(forKey: "\(prefix)FocusBeforeInteraction") as? Bool
            ?? focusBeforeInteraction

        WidgetWindow.all[id] = self
        buildPanel()
        chrome = WidgetChromeController(owner: self)
        panel.beforeActivation = { [weak self] in self?.updateBrowserActivity() }
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            center.addObserver(self, selector: #selector(activityChanged), name: name, object: NSApp)
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            center.addObserver(self, selector: #selector(activityChanged), name: name, object: panel)
        }
    }

    // MARK: Subclass hooks

    /// Size used the first time the window is placed.
    var initialSize: NSSize { NSSize(width: 420, height: 600) }
    /// Smallest height the window may be clamped to.
    var minimumHeight: CGFloat { 72 }
    func browserDidCreate(_ browser: PerchWebView) {}
    func browserWillClose(_ browser: PerchWebView) {}
    func browserDidActivate(_ browser: PerchWebView) {}
    func browserDidDeactivate(_ browser: PerchWebView) {}
    func browserContentProcessDidTerminate(_ browser: PerchWebView) {}
    func pageDidFinishLoading() {}
    func loadInitialPage() { webView?.load(URLRequest(url: home)) }
    func themeDidChange(from old: Theme) {}
    func handle(message type: String, _ body: [String: Any]) {}
    func menuItems() -> [NSMenuItem] { [] }
    /// The sign-in popup went away; restore whatever size the page wants.
    func popupDidClose() {}
    func goBack() {
        if let webView, webView.canGoBack { webView.goBack() }
    }
    func goForward() {
        if let webView, webView.canGoForward { webView.goForward() }
    }

    @objc private func activityChanged(_ notification: Notification) { updateBrowserActivity() }

    private func updateBrowserActivity() {
        let active = webView != nil && panel.isKeyWindow && NSApp.isActive
        guard active != browserActive else { return }
        browserActive = active
        guard let browser = webView else { return }
        if active { browserDidActivate(browser) }
        else { browserDidDeactivate(browser) }
    }

    // MARK: Showing

    private func createBrowser() {
        guard webView == nil else { return }
        let content = WKUserContentController()
        content.addUserScript(WKUserScript(source: PerchScript.prelude + "\n" + pageScript,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .page))
        bridge.owner = self
        content.add(bridge, name: "perch")
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController = content
        let browser = PerchWebView(frame: .zero, configuration: config)
        webView = browser
        browser.navigationDelegate = self
        browser.uiDelegate = self
        browser.customUserAgent = safariUserAgent
        browser.isInspectable = true
        browser.focusRingType = .none
        browser.translatesAutoresizingMaskIntoConstraints = false
        browser.onBack = { [weak self] in self?.goBack() }
        browser.extraMenuItems = { [weak self] in self?.menuItems() ?? [] }
        browserDidCreate(browser)
    }

    func show() {
        let needsAppearance = webView == nil || !panel.isVisible
        createBrowser()
        if !hasBeenPlaced { place(); hasBeenPlaced = true }
        if needsAppearance { applyTheme() }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(webView)
        updateBrowserActivity()
        chrome.update()
        if webView?.url == nil { loadInitialPage() }
        defaults.set(true, forKey: "\(prefix)Open")
        WidgetWindow.onChange?()
    }

    func focus() {
        NSApp.activate(ignoringOtherApps: true)
        show()
    }

    func close() {
        guard let browser = webView else {
            defaults.set(false, forKey: "\(prefix)Open")
            chrome.hide()
            panel.orderOut(nil)
            WidgetWindow.onChange?()
            return
        }
        if browserActive {
            browserActive = false
            browserDidDeactivate(browser)
        }
        browserWillClose(browser)
        // Media teardown is immediate even if WebKit still has work queued.
        browser.pauseAllMediaPlayback(completionHandler: nil)
        browser.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        browser.stopLoading()
        closePopup()
        browser.navigationDelegate = nil
        browser.uiDelegate = nil
        browser.onBack = nil
        browser.extraMenuItems = nil
        browser.configuration.userContentController.removeScriptMessageHandler(forName: "perch")
        browser.configuration.userContentController.removeAllUserScripts()
        NSLayoutConstraint.deactivate(pageConstraints)
        pageConstraints = []
        panel.makeFirstResponder(nil)
        browser.removeFromSuperview()
        webView = nil
        chrome.hide()
        panel.orderOut(nil)
        defaults.set(false, forKey: "\(prefix)Open")
        WidgetWindow.onChange?()
    }

    func toggle() {
        if isVisible { close() } else { show() }
    }

    @objc private func reloadFromContextMenu() { reload() }

    func reload() {
        webView?.load(URLRequest(url: home))
    }

    // MARK: Appearance

    func setTheme(_ theme: Theme) {
        let old = self.theme
        self.theme = theme
        defaults.set(theme.rawValue, forKey: "\(prefix)Theme")
        applyTheme()
        if old != theme { themeDidChange(from: old) }
    }

    func setFrost(_ value: Double) {
        frost = min(max(value, 0), 1)
        defaults.set(frost, forKey: "\(prefix)Frost")
        applyTheme()
    }

    func setKeepsInFront(_ on: Bool) {
        keepsInFront = on
        defaults.set(on, forKey: "\(prefix)KeepInFront")
        panel.level = on ? .floating : .normal
        chrome?.update()
    }

    func setFocusBeforeInteraction(_ on: Bool) {
        panel.focusBeforeInteraction = on
        defaults.set(on, forKey: "\(prefix)FocusBeforeInteraction")
        WidgetWindow.onChange?()
    }

    private func buildPanel() {
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.title = title
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.level = keepsInFront ? .floating : .normal

        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.translatesAutoresizingMaskIntoConstraints = false
        solid.translatesAutoresizingMaskIntoConstraints = false
        solid.wantsLayer = true

        popupClose.bezelStyle = .glass
        popupClose.title = "Cancel"
        popupClose.controlSize = .large
        popupClose.target = self
        popupClose.action = #selector(closePopupFromButton)
        popupClose.isHidden = true
        popupClose.translatesAutoresizingMaskIntoConstraints = false

        guard let content = panel.contentView else { return }
        content.wantsLayer = true
        content.layer?.cornerRadius = cornerRadius
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        content.addSubview(solid)
        content.addSubview(glass)
        content.addSubview(popupClose)
        NSLayoutConstraint.activate([
            solid.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            solid.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            solid.topAnchor.constraint(equalTo: content.topAnchor),
            solid.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            glass.topAnchor.constraint(equalTo: content.topAnchor),
            glass.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            popupClose.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            popupClose.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
        ])
    }

    /// The transparent page sits above an always-active native material.
    /// Clear uses no material. Frosted uses the same blur whether focused or
    /// inactive, without taking keyboard focus from another window.
    func applyTheme() {
        let glassTheme = theme == .glass
        panel.appearance = NSAppearance(named: theme == .light ? .aqua : .darkAqua)
        let pageColor: NSColor = glassTheme ? .clear : (theme == .light ? .white : .black)
        guard let webView else { return }
        webView.underPageBackgroundColor = pageColor
        webView.wantsLayer = true
        webView.layer?.isOpaque = !glassTheme
        webView.layer?.backgroundColor = pageColor.cgColor
        setWebFlag(webView, "_setDrawsTransparentBackground:", glassTheme)
        setWebFlag(webView, "_setDrawsBackground:", !glassTheme)
        solid.layer?.backgroundColor = pageColor.cgColor
        solid.isHidden = glassTheme
        panel.hasShadow = !glassTheme
        placePage()
        glass.isHidden = !glassTheme || frost < 0.5
        panel.level = keepsInFront ? .floating : .normal
        panel.invalidateShadow()
    }

    private func placePage() {
        guard let content = panel.contentView, let webView else { return }
        if webView.superview !== content {
            NSLayoutConstraint.deactivate(pageConstraints)
            webView.removeFromSuperview()
            content.addSubview(webView, positioned: .above, relativeTo: glass)
            pageConstraints = [
                webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                webView.topAnchor.constraint(equalTo: content.topAnchor),
                webView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ]
            NSLayoutConstraint.activate(pageConstraints)
        }
        if let popup { content.addSubview(popup) }
        content.addSubview(popupClose)
    }

    private func setWebFlag(_ target: NSObject, _ name: String, _ value: Bool) {
        let selector = NSSelectorFromString(name)
        guard target.responds(to: selector), let method = class_getInstanceMethod(type(of: target), selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method_getImplementation(method), to: Setter.self)(target, selector, value)
    }

    // MARK: Placement

    var screenFrame: NSRect {
        panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1400, height: 900)
    }

    private func place() {
        let screen = screenFrame
        let size = initialSize
        var frame = NSRect(x: screen.midX - size.width / 2, y: screen.maxY - size.height - 40, width: size.width, height: size.height)
        if let x = defaults.object(forKey: originKeys.x) as? Double, let y = defaults.object(forKey: originKeys.y) as? Double {
            frame.origin = NSPoint(x: x, y: y)
        }
        if let top = defaults.object(forKey: "\(prefix)Top") as? Double {
            frame.origin.y = top - size.height
        }
        panel.setFrame(clamped(frame), display: true)
    }

    /// Resizes while keeping the top edge where it is.
    func resize(to size: NSSize, animate: Bool = false) {
        var frame = panel.frame
        let top = frame.maxY
        frame.size = size
        frame.origin.y = top - size.height
        frame = clamped(frame)
        let current = panel.frame
        guard abs(frame.height - current.height) > 1 || abs(frame.width - current.width) > 1 || abs(frame.minY - current.minY) > 1 else { return }
        panel.setFrame(frame, display: true, animate: animate)
        saveOrigin()
    }

    func clamped(_ frame: NSRect) -> NSRect {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(center) })?.visibleFrame ?? screenFrame
        var frame = frame
        let minWidth = max(320, panel.minSize.width)
        let maxWidth = min(screen.width - 16, max(minWidth, panel.maxSize.width))
        frame.size.width = min(max(frame.width, minWidth), maxWidth)
        frame.size.height = min(max(frame.height, minimumHeight), max(minimumHeight, screen.height - WidgetChromeController.stripHeight - 8))
        if frame.maxX > screen.maxX - 8 { frame.origin.x = screen.maxX - frame.width - 8 }
        if frame.minX < screen.minX + 8 { frame.origin.x = screen.minX + 8 }
        if frame.maxY > screen.maxY - WidgetChromeController.stripHeight { frame.origin.y = screen.maxY - frame.height - WidgetChromeController.stripHeight }
        if frame.minY < screen.minY + 8 { frame.origin.y = screen.minY + 8 }
        return frame
    }

    /// Subclasses can constrain manual resizing while sharing native chrome.
    func frameForUserResize(_ frame: NSRect) -> NSRect { clamped(frame) }

    func saveOrigin() {
        defaults.set(Double(panel.frame.origin.x), forKey: originKeys.x)
        defaults.set(Double(panel.frame.origin.y), forKey: originKeys.y)
        defaults.set(Double(panel.frame.maxY), forKey: "\(prefix)Top")
    }

    // MARK: Messages

    func receive(_ body: Any) {
        guard let dict = body as? [String: Any], let type = dict["type"] as? String else { return }
        if type == "contextMenu", let webView,
           let x = dict["x"] as? Double, let y = dict["y"] as? Double {
            let menu = NSMenu()
            for item in menuItems() { menu.addItem(item) }
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            menu.addItem(withTitle: "Reload", action: #selector(reloadFromContextMenu), keyEquivalent: "").target = self
            menu.popUp(positioning: nil, at: NSPoint(x: x, y: webView.bounds.height - y), in: webView)
            return
        }
        handle(message: type, dict)
    }

    // MARK: Navigation and sign-in popup

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard isEnabled, webView === self.webView || webView === popup else { return nil }
        // Google opens a real second page, often blank first and then navigated.
        // Returning a view built from WebKit's configuration lets sign-in render.
        closePopup()
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.navigationDelegate = self
        popup.uiDelegate = self
        popup.customUserAgent = safariUserAgent
        popup.underPageBackgroundColor = .white
        popup.translatesAutoresizingMaskIntoConstraints = false
        guard let content = panel.contentView else { return popup }
        content.addSubview(popup)
        NSLayoutConstraint.activate([
            popup.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            popup.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            popup.topAnchor.constraint(equalTo: content.topAnchor),
            popup.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        self.popup = popup
        popupClose.isHidden = false
        content.addSubview(popupClose)
        if panel.frame.height < 560 {
            resize(to: NSSize(width: max(panel.frame.width, 460), height: 640))
        }
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard webView == popup else { return }
        let sawGoogle = popupSawGoogle
        closePopup()
        // Google closes its window after the account is chosen. Reload so the
        // page picks up the new session.
        if sawGoogle { self.webView?.load(URLRequest(url: home)) }
    }

    @objc private func closePopupFromButton() {
        closePopup()
    }

    private func closePopup() {
        guard let popup else { return }
        popup.pauseAllMediaPlayback(completionHandler: nil)
        popup.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        popup.stopLoading()
        popup.navigationDelegate = nil
        popup.uiDelegate = nil
        popup.removeFromSuperview()
        self.popup = nil
        popupSawGoogle = false
        popupClose.isHidden = true
        popupDidClose()
    }

    var hasPopup: Bool { popup != nil }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView == self.webView {
            applyTheme()
            pageDidFinishLoading()
            return
        }
        guard webView == popup, let url = webView.url else { return }
        if url.host?.lowercased().contains("google.") == true { popupSawGoogle = true }
        guard popupSawGoogle, url.host?.lowercased() == home.host?.lowercased() else { return }
        closePopup()
        self.webView?.load(URLRequest(url: home))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let browser = self.webView, webView === browser else { return }
        browserContentProcessDidTerminate(browser)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if webView == popup {
            decisionHandler(.allow)
            return
        }
        // A target=_blank link with no popup returned would otherwise open Safari.
        if navigationAction.targetFrame == nil {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func evaluate(_ script: String) {
        webView?.evaluateJavaScript(script, completionHandler: nil)
    }
}
