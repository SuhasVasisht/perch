import AppKit
import WebKit

private struct SessionFailure: Error { let message: String }

@MainActor private final class XSessionVerification: NSObject, NSApplicationDelegate {
    let suite = "local.perch.x-session-verification.\(UUID().uuidString)"
    var preferences: UserDefaults!
    var widget: XWidget!
    var checks = 0
    let home = URL(string: CommandLine.arguments[1] + "/home")!

    func applicationDidFinishLaunching(_ notification: Notification) {
        preferences = UserDefaults(suiteName: suite)!
        Task {
            do {
                try await verify()
                finish()
                print("Completed \(checks) offscreen X session/checkpoint checks. Lifecycle and process-loss events are controlled; no OS focus or account requests.")
                exit(0)
            } catch {
                print("FAIL \(error)")
                print("Offscreen activity=\(OffscreenHost.isActive) OSactive=\(NSApp.isActive) key=\(widget?.panel.isKeyWindow ?? false) savedY=\(String(describing: preferences.dictionary(forKey: "feedReadingPosition")?["y"]))")
                if widget?.webView != nil { print("JS failure state \(String(describing: try? await js("JSON.stringify({owner:__tfOwner(),y:scrollY,trace:window.sessionTrace})")))") }
                finish()
                exit(1)
            }
        }
    }
    func finish() {
        widget?.close()
        preferences.removePersistentDomain(forName: suite)
    }
    func pause(_ seconds: Double = 0.1) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    @discardableResult func js(_ code: String) async throws -> Any? { try await widget.webView!.evaluateJavaScript(code) }
    func number(_ code: String) async throws -> Double { (try await js(code) as! NSNumber).doubleValue }
    func yes(_ code: String) async throws -> Bool { try await js(code) as? Bool == true }
    func wait(_ code: String) async throws {
        for _ in 0..<160 { if (try? await yes(code)) == true { return }; try await pause() }
        throw SessionFailure(message: "Timed out: \(code)")
    }
    func until(_ condition: () -> Bool) async throws {
        for _ in 0..<100 { if condition() { return }; try await pause() }
        throw SessionFailure(message: "Timed out waiting for native condition")
    }
    func check(_ name: String, _ condition: Bool) throws {
        guard condition else { throw SessionFailure(message: name) }
        guard OffscreenHost.safetyFailures().isEmpty else { throw SessionFailure(message: OffscreenHost.safetyFailures().joined(separator: ", ")) }
        checks += 1; print("PASS \(name)"); fflush(stdout)
    }
    func read(_ y: Double) async throws {
        try await js("if(__tfOwner().suspended)throw new Error('Cannot read while inactive');window.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true}));window.scrollTo(0,\(y))")
    }
    func verify() async throws {
        OffscreenHost.isActive = false
        widget = XWidget(home: home, defaults: preferences, dataStore: .nonPersistent())
        OffscreenHost.show(widget)
        try await wait("!!window.__tfOwner && !!document.querySelector('article[data-testid=tweet]')")
        try await until { abs(self.widget.panel.frame.height - 300) < 1 }
        try check("Initially inactive Home fits one post without OS activation", !widget.panel.isKeyWindow && widget.panel.frame.height == 300)
        OffscreenHost.setActivity(widget, true)
        try await wait("__tfOwner().suspended===false")
        try await pause(0.3)
        try await js("""
        window.sessionTrace=[];
        const trace=(kind,detail)=>sessionTrace.push({t:performance.now(),kind,detail,y:scrollY,h:innerHeight,owner:__tfOwner()});
        for(const name of ['scrollTo','scrollBy','__tfDidFit','__tfActivate','__tfCheckpoint']){
          const original=window[name];window[name]=function(...args){trace(name,args);const result=original.apply(this,args);trace(name+' done',result);return result};
        }
        for(const type of ['scroll','resize','wheel','keydown','pointerdown','focus','blur'])window.addEventListener(type,e=>trace(type,{trusted:e.isTrusted,key:e.key===' '?'Space':['ArrowUp','ArrowDown','ArrowLeft','ArrowRight'].includes(e.key)?e.key:'other',deltaY:e.deltaY}),true);
        """)
        try await read(412)
        try await pause(0.8)
        let oldBrowser = ObjectIdentifier(widget.webView!)
        let oldURL = widget.webView!.url
        let oldLoads = try await number("Number(sessionStorage.getItem('loadCount'))")
        let oldDocument = try await js("__tfOwner().documentId") as! String
        try check("Controlled reading activity is enabled while OS remains inactive", OffscreenHost.isActive && !NSApp.isActive)
        try await read(449)
        OffscreenHost.setActivity(widget, false)
        try await until {
            let saved = self.preferences.dictionary(forKey: "feedReadingPosition")
            return abs((saved?["y"] as? Double ?? -1) - 449) < 1 && saved?["suspended"] as? Bool == true
        }
        try check("Controlled deactivation saves a suspended checkpoint of latest progress", abs((preferences.dictionary(forKey: "feedReadingPosition")?["y"] as? Double ?? -1)-449) < 1)
        try await pause(0.8)
        try check("Inactive page stays at latest offset without old motion", abs(try await number("scrollY")-449) < 1)
        OffscreenHost.setActivity(widget, true)
        try await wait("__tfOwner().suspended===false")
        try await pause(1.0)
        try check("Controlled resume retains the exact live browser", ObjectIdentifier(widget.webView!) == oldBrowser)
        let returnLoads = try await number("Number(sessionStorage.getItem('loadCount'))")
        try check("Controlled resume keeps URL and document load count", widget.webView!.url == oldURL && returnLoads == oldLoads)
        try check("Controlled resume keeps newest post offset", abs(try await number("scrollY")-449) < 1)
        if let trace = try await js("JSON.stringify(sessionTrace)") as? String {
            try trace.write(toFile: "verification/x-session-offscreen-return-trace.json", atomically: true, encoding: .utf8)
        }
        let obsolete = preferences.dictionary(forKey: "feedReadingPosition")!
        widget.reload()
        try await wait("__tfOwner().documentId !== '\(oldDocument)' && Math.abs(scrollY-449)<1")
        try await pause(0.5)
        var latePosition = obsolete
        latePosition["y"] = 10
        latePosition["snapshotRevision"] = 999999
        var late = obsolete
        late["position"] = latePosition
        let priorPair = preferences.dictionary(forKey: "feedReadingPosition")!
        widget.handle(message: "saveSession", late)
        let stored = preferences.dictionary(forKey: "feedReadingPosition")
        try check("Old document callback cannot overwrite a same-URL reload", NSDictionary(dictionary: priorPair).isEqual(to: stored ?? [:]) && abs((stored?["y"] as? Double ?? -1)-449) < 1)
        let frame = widget.panel.frame
        late["height"] = 88.0; late["width"] = frame.width; late["serial"] = 1
        widget.handle(message: "fitPost", late)
        try await pause(0.3)
        try check("Old document fit cannot resize a replacement document", widget.panel.frame == frame)
        try await js("sessionStorage.setItem('renderDelay','1500')")
        let beforeHydration = try await js("__tfOwner().documentId") as! String
        widget.reload()
        try await wait("!!window.__tfOwner && __tfOwner().documentId!=='\(beforeHydration)' && !document.querySelector('article[data-testid=tweet]')")
        OffscreenHost.setActivity(widget, false)
        try await pause(0.3)
        try check("Leaving before hydration does not overwrite saved target with temporary zero", abs((preferences.dictionary(forKey: "feedReadingPosition")?["y"] as? Double ?? -1)-449) < 1)
        OffscreenHost.setActivity(widget, true)
        try await wait("!!document.querySelector('article[data-testid=tweet]') && Math.abs(scrollY-449)<1")
        try check("Returning after interrupted startup restores the original target", true)
        try await js("navigate('/reader/status/10002')")
        try await wait("location.pathname==='/reader/status/10002' && innerHeight===640")
        try await read(436)
        widget.saveSession()
        try await until { self.preferences.dictionary(forKey: "feedReadingPosition")?["url"] as? String == self.widget.webView!.url!.absoluteString && abs((self.preferences.dictionary(forKey: "feedReadingPosition")?["y"] as? Double ?? -1)-436) < 1 }
        let detailLoads = try await number("Number(sessionStorage.getItem('loadCount'))")
        widget.browserContentProcessDidTerminate(widget.webView!)
        try await wait("location.pathname==='/reader/status/10002' && Number(sessionStorage.getItem('loadCount'))>\(detailLoads) && Math.abs(scrollY-436)<1")
        try check("Simulated process-loss event recovers current comments URL and anchor", true)
        widget.goBack()
        try await wait("location.pathname==='/home'")
        try await read(700)
        try await js("for(let i=0;i<2;i++)document.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowUp',bubbles:true,cancelable:true}))")
        try await wait("location.pathname==='/home' && scrollY<1")
        try await pause(0.8)
        try check("Explicit double-Up refresh from Home middle stays at newest top", try await yes("scrollY<1"))
    }
}

@main private struct VerifyXSession {
    static func main() {
        let app = NSApplication.shared
        let delegate = XSessionVerification()
        app.delegate = delegate
        app.setActivationPolicy(.prohibited)
        app.run()
    }
}
