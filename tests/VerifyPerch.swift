import AppKit
import WebKit

struct PerchFailure: Error { let message: String }
final class WeakBrowser {
    weak var value: WKWebView?
    init(_ value: WKWebView?) { self.value = value }
}

final class FixtureWidget: WidgetWindow {
    var created = 0
    var closed = 0
    var loaded = false
    var snapshotClicks = -1
    var activated = 0
    var deactivated = 0
    var processTerminations = 0
    override func browserDidActivate(_ browser: PerchWebView) {
        activated += 1
        browser.evaluateJavaScript("window.__nativeActivationCount = \(activated)", completionHandler: nil)
    }
    override func browserDidDeactivate(_ browser: PerchWebView) { deactivated += 1 }
    override func browserContentProcessDidTerminate(_ browser: PerchWebView) { processTerminations += 1 }
    override func browserDidCreate(_ browser: PerchWebView) { created += 1; loaded = false }
    override func browserWillClose(_ browser: PerchWebView) { closed += 1 }
    override func pageDidFinishLoading() {
        loaded = true
        webView?.evaluateJavaScript("window.__nativeActivationCount = \(activated)", completionHandler: nil)
    }
}

@MainActor
final class PerchVerification: NSObject, NSApplicationDelegate {
    let suite = "local.perch.shared-verification.\(UUID().uuidString)"
    var prefs: UserDefaults!
    var widget: FixtureWidget!
    var other: FixtureWidget!
    var checks = 0
    func applicationDidFinishLaunching(_ notification: Notification) {
        prefs = UserDefaults(suiteName: suite)!
        Task {
            do {
                try await run()
                widget.close(); other.close()
                prefs.removePersistentDomain(forName: suite)
                print("Completed \(checks) shared native/AppKit/local media checks. No account requests.")
                exit(0)
            } catch {
                print("FAIL \(error)")
                widget?.close(); other?.close()
                prefs.removePersistentDomain(forName: suite)
                exit(1)
            }
        }
    }
    func check(_ name: String, _ passed: Bool) throws {
        guard passed else { throw PerchFailure(message: name) }
        print("PASS \(name)"); fflush(stdout); checks += 1
    }
    func pause(_ seconds: Double = 0.2) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<80 { if condition() { return }; try await pause(0.1) }
        throw PerchFailure(message: "Timed out waiting for local browser")
    }
    func js(_ code: String) async throws -> Any? { try await widget.webView!.evaluateJavaScript(code) }
    func mouse(_ type: NSEvent.EventType, window: NSWindow, point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }
    func click(_ panel: NSWindow) {
        // The HTML button fills the top 150 points of the real WKWebView.
        let point = NSPoint(x: 80, y: panel.frame.height - 60)
        panel.sendEvent(mouse(.leftMouseDown, window: panel, point: point))
        panel.sendEvent(mouse(.leftMouseUp, window: panel, point: point))
    }
    func drag(_ control: WidgetChromeControl, delta: NSPoint) {
        let window = control.window!
        let start = control.convert(NSPoint(x: 15, y: 12), to: nil)
        let end = NSPoint(x: start.x + delta.x, y: start.y + delta.y)
        NSApp.postEvent(mouse(.leftMouseDragged, window: window, point: end), atStart: false)
        NSApp.postEvent(mouse(.leftMouseUp, window: window, point: end), atStart: false)
        control.mouseDown(with: mouse(.leftMouseDown, window: window, point: start))
    }
    func run() async throws {
        let url = URL(string: CommandLine.arguments[1])!
        widget = FixtureWidget(id: "fixture", title: "Fixture", home: url, prefix: "fixture", originKeys: ("fx", "fy"), script: "", defaults: prefs, dataStore: .nonPersistent())
        other = FixtureWidget(id: "other", title: "Other", home: url, prefix: "other", originKeys: ("ox", "oy"), script: "", defaults: prefs, dataStore: .nonPersistent())
        try check("disabled widget has no browser and no browser-created hook", widget.webView == nil && !widget.isEnabled && widget.created == 0)
        widget.evaluate("throw new Error('off must not create browser')")
        try check("evaluate while disabled does not create a browser", widget.webView == nil)
        try check("shared widgets default to focus-first clicks", widget.focusBeforeInteraction)
        widget.show()
        try await wait { self.widget.loaded }
        try await pause(0.7)
        try check("show creates one enabled browser and invokes shared hook", widget.isEnabled && widget.created == 1 && widget.wasOpen)
        try check("shared interaction helper identifies real page buttons and media", try await js("action.matches(__perchInteractive) && audio.matches(__perchInteractive) && video.matches(__perchInteractive) && !document.body.matches(__perchInteractive)") as? Bool == true)
        try check("page text and controls cannot be selected or dragged", try await js("[copy, action, link].every(node => getComputedStyle(node).webkitUserSelect === 'none' && getComputedStyle(node).webkitUserDrag === 'none')") as? Bool == true)
        try check("page selection and link drag gestures are cancelled", try await js("!copy.dispatchEvent(new Event('selectstart',{bubbles:true,cancelable:true})) && !link.dispatchEvent(new Event('dragstart',{bubbles:true,cancelable:true}))") as? Bool == true)
        try check("search fields retain text editing and selection", try await js("editor.focus(); editor.setSelectionRange(0,8); getComputedStyle(editor).webkitUserSelect === 'text' && editor.selectionStart === 0 && editor.selectionEnd === 8 && editor.dispatchEvent(new Event('selectstart',{bubbles:true,cancelable:true}))") as? Bool == true)
        _ = try await js("action.focus()")
        try check("web controls have no focus outline or native focus ring", try await js("getComputedStyle(action).outlineStyle === 'none'") as? Bool == true && widget.webView!.focusRingType == .none)
        _ = try await js("document.activeElement.blur()")
        try check("local audio is playing before disable", try await js("mediaPlaying && !audio.paused && audio.currentTime > 0") as? Bool == true)
        try check("local video is playing before disable", try await js("!video.paused && video.srcObject.active") as? Bool == true)
        widget.chrome.hide()
        widget.chrome.update()
        try check("keyboard focus alone does not add a widget selection box", !(widget.panel.childWindows ?? []).contains { $0 !== widget.chrome.accessory && $0.isVisible })
        let tracking = widget.panel.contentView!.subviews.compactMap { $0 as? WidgetChromeTrackingView }.first!
        tracking.updateTrackingAreas()
        try check("page has an active native hover tracking area", tracking.trackingAreas.contains { $0.options.contains(.activeAlways) && $0.options.contains(.inVisibleRect) })
        let entered = NSEvent.enterExitEvent(with: .mouseEntered, location: NSPoint(x: 40, y: 40), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: widget.panel.windowNumber,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        tracking.mouseEntered(with: entered)
        try check("hover reveals native controls outside page bounds", widget.chrome.accessory.isVisible && widget.chrome.accessory.frame.minY == widget.panel.frame.maxY)
        try check("strip stays inside visible screen", widget.screenFrame.contains(widget.chrome.accessory.frame))
        let pageBounds = widget.webView!.bounds
        try check("shared controls do not change page content size", abs(pageBounds.width - widget.panel.frame.width) < 1 && abs(pageBounds.height - widget.panel.frame.height) < 1)
        widget.resize(to: NSSize(width: 420, height: widget.screenFrame.height * 2))
        try check("maximum widget height reserves visible native controls", widget.panel.frame.maxY + WidgetChromeController.stripHeight <= widget.screenFrame.maxY && widget.panel.frame.minY >= widget.screenFrame.minY)
        widget.resize(to: NSSize(width: 420, height: 300))
        try await pause()
        let oldFrame = widget.panel.frame
        drag(widget.chrome.moveControl, delta: NSPoint(x: 24, y: -18))
        try check("real AppKit drag events move widget from native handle", abs(widget.panel.frame.minX - oldFrame.minX - 24) < 1 && abs(widget.panel.frame.minY - oldFrame.minY + 18) < 1)
        try check("native handle follows moved widget without gap", widget.chrome.accessory.frame.minY == widget.panel.frame.maxY)
        try await pause()
        let moved = widget.panel.frame
        drag(widget.chrome.resizeControl, delta: NSPoint(x: 30, y: -40))
        try check("real AppKit drag events resize widget from native handle", abs(widget.panel.frame.width - moved.width - 30) < 1 && abs(widget.panel.frame.height - moved.height - 40) < 1)
        try check("manual resize preserves top edge and follows handle", abs(widget.panel.frame.maxY - moved.maxY) < 1 && widget.chrome.accessory.frame.minY == widget.panel.frame.maxY)
        widget.chrome.beginManipulation(resizing: true)
        try check("shared resizing state remains true during paused native manipulation", widget.isUserResizing)
        widget.chrome.endManipulation(resizing: true)
        try check("shared resizing state clears before completion refit", !widget.isUserResizing)
        widget.resize(to: NSSize(width: 410, height: 260))
        try check("automatic content resize keeps handle attached", widget.chrome.accessory.frame.minY == widget.panel.frame.maxY)
        widget.chrome.moveControl.performClick(nil)
        try await pause()
        try check("accessible native Move action focuses its control", widget.chrome.accessory.isKeyWindow && widget.chrome.accessory.firstResponder === widget.chrome.moveControl)
        let beforeKeyboard = widget.panel.frame
        let right = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: widget.chrome.accessory.windowNumber, context: nil, characters: "\u{f703}",
            charactersIgnoringModifiers: "\u{f703}", isARepeat: false, keyCode: 124)!
        widget.chrome.accessory.sendEvent(right)
        try check("native Move control supports accessible activation and arrow keys", widget.panel.frame.minX == beforeKeyboard.minX + 10)
        widget.chrome.accessory.sendEvent(right)
        try check("native handle retains keyboard focus for repeated adjustments", widget.panel.frame.minX == beforeKeyboard.minX + 20)
        try check("native Move and Resize do not draw a focus ring or select labels", widget.chrome.moveControl.focusRingType == .none && widget.chrome.resizeControl.focusRingType == .none && widget.chrome.moveControl.cell?.isSelectable == false && widget.chrome.resizeControl.cell?.isSelectable == false)
        widget.focus()
        try await wait { NSApp.isActive && self.widget.panel.isKeyWindow }
        try await pause()
        let activeBeforeOther = widget.activated
        let inactiveBeforeOther = widget.deactivated
        let identityBeforeOther = WeakBrowser(widget.webView)
        _ = try await js("action.addEventListener('click',()=>{window.__activationCountAtAction=window.__nativeActivationCount},true)")
        other.show()
        try await wait { self.other.loaded }
        NSApp.activate(ignoringOtherApps: true)
        other.panel.makeKeyAndOrderFront(nil)
        try await pause()
        try check("other widget is key before activation click", other.panel.isKeyWindow && !widget.panel.isKeyWindow)
        try check("other-window focus sends exactly one browser deactivation", widget.deactivated == inactiveBeforeOther + 1 && widget.activated == activeBeforeOther)
        try check("activity transitions preserve the actual browser instance", widget.webView === identityBeforeOther.value && widget.created == 1)
        other.panel.makeKeyAndOrderFront(nil)
        try await pause()
        try check("repeated inactive state does not duplicate lifecycle hooks", widget.deactivated == inactiveBeforeOther + 1 && widget.activated == activeBeforeOther)
        let activationBeforeClick = widget.activated
        click(widget.panel)
        try await pause()
        try check("first click focuses an inactive widget", widget.panel.isKeyWindow)
        try check("consumed activation click activates the browser exactly once", widget.activated == activationBeforeClick + 1 && widget.webView === identityBeforeOther.value)
        try check("first click does not activate local page action", try await js("clicks") as? Int == 0)
        click(widget.panel)
        try await pause(0.5)
        try check("second click reaches local page action", try await js("clicks") as? Int == 1)
        try check("activation hook reaches the page before its next action", try await js("__activationCountAtAction") as? Int == widget.activated)
        let browserCount = widget.created
        widget.setFocusBeforeInteraction(false)
        try check("click policy changes immediately without reloading the page", !widget.focusBeforeInteraction && widget.webView!.acceptsFirstMouse(for: nil) && widget.created == browserCount)
        other.panel.makeKeyAndOrderFront(nil)
        try await pause()
        let directActivationBeforeClick = widget.activated
        click(widget.panel)
        try await pause(0.5)
        let directClicks = try await js("clicks") as? Int
        print("Direct click observation: appActive=\(NSApp.isActive), key=\(widget.panel.isKeyWindow), clicks=\(String(describing: directClicks))")
        try check("direct mode delivers the first inactive click exactly once", directClicks == 2)
        let directHookAtAction = try await js("__activationCountAtAction") as? Int
        try check("direct activation calls hook once before forwarding page action", widget.activated == directActivationBeforeClick + 1 && directHookAtAction == widget.activated)
        let externalDeactivationBefore = widget.deactivated
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: CommandLine.arguments[2])
        helper.arguments = ["--background-helper"]
        try helper.run()
        defer { if helper.isRunning { helper.terminate(); helper.waitUntilExit() } }
        try await wait { !NSApp.isActive }
        try check("Perch is inactive before testing a background-app click", !NSApp.isActive)
        try check("key and app loss coalesce into one browser deactivation", widget.deactivated == externalDeactivationBefore + 1)
        let externalActivationBefore = widget.activated
        click(widget.panel)
        try await pause(0.5)
        let backgroundClicks = try await js("clicks") as? Int
        print("Background click observation: appActive=\(NSApp.isActive), key=\(widget.panel.isKeyWindow), clicks=\(String(describing: backgroundClicks))")
        try check("direct mode delivers a background-app click exactly once", backgroundClicks == 3)
        try check("external activation coalesces into one browser activation", widget.activated == externalActivationBefore + 1)
        try check("background activation hook precedes the forwarded page action", try await js("__activationCountAtAction") as? Int == widget.activated)
        try check("background activation does not recreate the browser", widget.webView === identityBeforeOther.value && widget.created == 1)
        helper.terminate(); helper.waitUntilExit()
        NSApp.activate(ignoringOtherApps: true)
        widget.panel.makeKeyAndOrderFront(nil)
        try await pause()
        let point = NSPoint(x: 15, y: widget.panel.frame.height - 175)
        let end = NSPoint(x: 240, y: point.y)
        widget.panel.sendEvent(mouse(.leftMouseDown, window: widget.panel, point: point))
        widget.panel.sendEvent(mouse(.leftMouseDragged, window: widget.panel, point: end))
        widget.panel.sendEvent(mouse(.leftMouseUp, window: widget.panel, point: end))
        try await pause()
        try check("real page drag leaves no text selection", try await js("getSelection().isCollapsed") as? Bool == true)
        let clicksBeforeChrome = try await js("clicks") as? Int
        drag(widget.chrome.moveControl, delta: NSPoint(x: 10, y: -5))
        drag(widget.chrome.resizeControl, delta: NSPoint(x: 10, y: -5))
        let clicksAfterChrome = try await js("clicks") as? Int
        let noSelectionAfterChrome = try await js("getSelection().isCollapsed") as? Bool
        try check("Move and Resize leave page controls and selection untouched", clicksAfterChrome == clicksBeforeChrome && noSelectionAfterChrome == true)
        let savedPolicy = FixtureWidget(id: "policy", title: "Policy", home: url, prefix: "fixture", originKeys: ("px", "py"), script: "", defaults: prefs, dataStore: .nonPersistent())
        try check("a recreated widget retains direct clicks without creating a browser", !savedPolicy.focusBeforeInteraction && savedPolicy.webView == nil)
        widget.setFocusBeforeInteraction(true)
        other.panel.makeKeyAndOrderFront(nil)
        try await pause()
        click(widget.panel)
        try await pause()
        let focusedClicks = try await js("clicks") as? Int
        try check("turning focus-first back on consumes the activation gesture", widget.focusBeforeInteraction && !widget.webView!.acceptsFirstMouse(for: nil) && focusedClicks == 3)
        _ = try await js("document.cookie='perchFixture=retained; path=/'; window.fixturePopup=window.open('/popup','local-fixture'); true")
        try await wait { self.widget.hasPopup }
        try check("local target popup remains contained by widget", widget.panel.contentView!.subviews.contains { $0 is WKWebView && $0 !== widget.webView })
        do {
            let popupBrowser = widget.panel.contentView!.subviews.compactMap { $0 as? WKWebView }.first { $0 !== widget.webView }!
            let count = widget.processTerminations
            widget.webViewWebContentProcessDidTerminate(popupBrowser)
            try check("popup termination does not invoke the main-browser hook", widget.processTerminations == count)
            widget.webViewWebContentProcessDidTerminate(widget.webView!)
            try check("main-browser termination forwards the hook once without replacement", widget.processTerminations == count + 1 && widget.webView === identityBeforeOther.value && widget.created == 1)
        }
        let previousPopup = WeakBrowser(widget.panel.contentView!.subviews.compactMap { $0 as? WKWebView }.first { $0 !== widget.webView })
        let previous = WeakBrowser(widget.webView)
        widget.close()
        try check("off releases browser property and persists disabled state", widget.webView == nil && !widget.isEnabled && !widget.wasOpen && !widget.isVisible)
        try check("off dismisses external chrome", !widget.chrome.accessory.isVisible && widget.chrome.accessory.parent == nil)
        try check("close hook runs before releasing browser", widget.closed == 1)
        try await wait { previous.value == nil && previousPopup.value == nil }
        try check("previous playing browser is actually deallocated", previous.value == nil)
        try check("disable also releases popup and removes its overlay", previousPopup.value == nil && !widget.hasPopup)
        widget.focus()
        try await wait { self.widget.loaded }
        try check("focus recreates a distinct browser through shared hook", widget.created == 2 && previous.value == nil && widget.isEnabled)
        try check("recreated browser retains website store cookie", try await js("document.cookie.includes('perchFixture=retained')") as? Bool == true)
        widget.focus()
        try check("repeated focus never disables or recreates enabled widget", widget.created == 2 && widget.isEnabled && widget.panel.isKeyWindow)
        widget.close(); widget.close()
        try check("repeated disable is idempotent", widget.closed == 2 && widget.webView == nil)
    }
}

@main struct VerifyPerch {
    static func main() {
        let app = NSApplication.shared
        if CommandLine.arguments.contains("--background-helper") {
            app.setActivationPolicy(.regular)
            let delegate = BackgroundClickHelper()
            app.delegate = delegate
            app.run()
            return
        }
        app.setActivationPolicy(.accessory)
        let delegate = PerchVerification()
        app.delegate = delegate
        app.run()
    }
}

final class BackgroundClickHelper: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 8, y: 65, width: 180, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Local click test"
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
