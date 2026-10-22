import AppKit
import WebKit

private struct StartupFailure: Error { let message: String }

@MainActor private final class XStartupVerification: NSObject, NSApplicationDelegate {
    let suite = "local.perch.x-startup-verification.\(UUID().uuidString)"
    var preferences: UserDefaults!
    let store = WKWebsiteDataStore.nonPersistent()
    var widget: XWidget!
    var checks = 0
    var failures = 0
    var home = URL(string: CommandLine.arguments[1] + "/home?startupScrollShift=54")!

    func applicationDidFinishLaunching(_ notification: Notification) {
        preferences = UserDefaults(suiteName: suite)!
        Task {
            do {
                try await verify()
                print("Completed \(checks) nonactivating startup checks; \(failures) failures.")
                finish()
                exit(failures == 0 ? 0 : 1)
            } catch {
                print("FAIL startup setup: \(error)")
                finish()
                exit(1)
            }
        }
    }
    func finish() { widget?.close(); preferences.removePersistentDomain(forName: suite) }
    func pause(_ seconds: Double) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    @discardableResult func js(_ code: String) async throws -> Any? { try await widget.webView!.evaluateJavaScript(code) }
    func yes(_ code: String) async throws -> Bool { try await js(code) as? Bool == true }
    func wait(_ code: String) async throws {
        for _ in 0..<120 { if (try? await yes(code)) == true { return }; try await pause(0.05) }
        throw StartupFailure(message: "Timed out: \(code)")
    }
    func check(_ name: String, _ condition: Bool) throws {
        guard OffscreenHost.safetyFailures().isEmpty else { throw StartupFailure(message: OffscreenHost.safetyFailures().joined(separator: ", ")) }
        checks += 1
        if !condition { failures += 1 }
        print("\(condition ? "PASS" : "FAIL") \(name)"); fflush(stdout)
    }
    func fresh(_ active: Bool) async throws {
        OffscreenHost.isActive = active
        widget = XWidget(home: home, defaults: preferences, dataStore: store)
        OffscreenHost.show(widget)
        try await wait("!!window.__tfOwner && !!document.querySelector('article[data-testid=tweet]')")
    }
    func save(_ y: Double) async throws {
        OffscreenHost.setActivity(widget, true)
        try await wait("!__tfOwner().suspended")
        try await js("window.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true}));window.scrollTo(0,\(y))")
        try await pause(0.8)
        widget.saveSession()
        for _ in 0..<100 {
            if abs((preferences.dictionary(forKey: "feedReadingPosition")?["y"] as? Double ?? -1) - y) < 1 { return }
            try await pause(0.05)
        }
        throw StartupFailure(message: "Checkpoint did not save \(y)")
    }
    func verify() async throws {
        preferences.set("dark", forKey: "feedTheme")
        preferences.set(640, forKey: "feedHeight")
        try await fresh(false)
        try await pause(0.9)
        try check("New inactive Home settles at a whole post after initial router scrolling", try await yes("scrollY===0 && innerHeight===300"))
        try await save(380)
        widget.close()
        try await pause(0.15)
        var missing = preferences.dictionary(forKey: "feedReadingPosition")!
        missing["anchors"] = [["id": "999999999", "top": -80, "box": "cell"]]
        preferences.set(missing, forKey: "feedReadingPosition")
        try await fresh(false)
        try await pause(2.4)
        try check("Inactive cold start with replaced feed opens a whole available post", try await yes("Math.abs(scrollY-300)<1 && Math.abs(document.querySelectorAll('[data-testid=cellInnerDiv]')[1].getBoundingClientRect().top)<1"))
        try check("Inactive cold start fits the selected post without OS focus", widget.panel.frame.height > 600 && !widget.panel.isKeyWindow && !NSApp.isActive)
        print("STATE missing-anchor \(String(describing: try await js("JSON.stringify({y:scrollY,h:innerHeight,owner:__tfOwner()})")))")
        OffscreenHost.setActivity(widget, true)
        try await wait("!__tfOwner().suspended")
        try await pause(0.5)
        try check("First activation retains the completed missing-anchor fallback without replay", try await yes("scrollY===300 && __tfReadingPosition().y===300"))

        try await save(449)
        widget.close()
        try await pause(0.15)
        try await fresh(false)
        try await pause(0.9)
        try check("Inactive cold start preserves saved progress within a tall post", try await yes("Math.abs(scrollY-449)<1 && document.querySelectorAll('[data-testid=cellInnerDiv]')[1].getBoundingClientRect().top===-149"))
        OffscreenHost.setActivity(widget, true)
        try await wait("!__tfOwner().suspended")
        try await pause(0.5)
        try check("Activation preserves the restored partial tall-post checkpoint", try await yes("scrollY===449"))

        try await save(1400)
        widget.close()
        try await pause(0.15)
        try await fresh(false)
        try await pause(1.0)
        try check("Cold start settles saved post after delayed hydration and router scrolling", try await yes("Math.abs(scrollY-1400)<1 && Math.abs(document.querySelectorAll('[data-testid=cellInnerDiv]')[2].getBoundingClientRect().top)<1 && innerHeight===300"))
        print("STATE delayed-router \(String(describing: try await js("JSON.stringify({y:scrollY,h:innerHeight,owner:__tfOwner()})")))")
        OffscreenHost.setActivity(widget, true)
        try await wait("!__tfOwner().suspended")
        try await js("window.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true}));window.scrollTo(0,1450)")
        try await pause(0.8)
        try check("Completed startup restoration leaves later deliberate reading unpinned", try await yes("scrollY===1450"))
        try await js("window.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowDown',bubbles:true,cancelable:true}))")
        try await pause(0.6)
        try check("Keyboard navigation works immediately after inactive startup", try await yes("scrollY===1700 && innerHeight===300"))
        widget.close()
        try await pause(0.15)
        preferences.removeObject(forKey: "feedInteractionState")
        preferences.removeObject(forKey: "feedReadingPosition")
        home = URL(string: CommandLine.arguments[1] + "/home?initiallyHydrated=1")!
        try await fresh(false)
        try await pause(0.9)
        try check("Prehydrated inactive startup replaces its provisional checkpoint after alignment", try await yes("scrollY===0 && __tfCheckpoint({suspend:true}).y===0"))
        OffscreenHost.setActivity(widget, true)
        try await wait("!__tfOwner().suspended")
        try await pause(0.5)
        try check("First activation cannot rewind the initial aligned post to its provisional offset", try await yes("scrollY===0 && innerHeight===300"))
    }
}

@main private struct VerifyXStartup {
    static func main() {
        let app = NSApplication.shared
        let delegate = XStartupVerification()
        app.delegate = delegate
        app.setActivationPolicy(.prohibited)
        app.run()
    }
}
