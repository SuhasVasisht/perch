import AppKit
import WebKit

struct MusicFailure: Error { let message: String }

@MainActor
final class MusicVerification: NSObject, NSApplicationDelegate {
    private let suiteName = "local.perch.music-verification.\(UUID().uuidString)"
    private var preferences: UserDefaults!
    private var widget: MusicWidget!
    private var checks = 0
    private var publications = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        preferences = UserDefaults(suiteName: suiteName)!
        preferences.set("dark", forKey: "musicTheme")
        Task {
            do {
                try await verify()
                widget.close()
                preferences.removePersistentDomain(forName: suiteName)
                print("Completed \(checks) isolated Music WebKit/window checks. No account requests.")
                exit(0)
            } catch {
                print("FAIL \(error)")
                widget?.close()
                preferences.removePersistentDomain(forName: suiteName)
                exit(1)
            }
        }
    }

    private func check(_ name: String, _ passed: Bool) throws {
        guard passed else { throw MusicFailure(message: name) }
        checks += 1
        print("PASS \(name)")
        fflush(stdout)
    }
    @discardableResult private func js(_ expression: String) async throws -> Any? {
        guard let browser = widget.webView else { throw MusicFailure(message: "Browser is off") }
        return try await browser.evaluateJavaScript(expression)
    }
    private func yes(_ expression: String) async throws -> Bool { try await js(expression) as? Bool == true }
    private func pause(_ seconds: Double = 0.1) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    private func wait(_ expression: String) async throws {
        for _ in 0..<200 {
            if (try? await yes(expression)) == true { return }
            try await pause(0.05)
        }
        throw MusicFailure(message: "Timed out: \(expression)")
    }
    private func click(_ selector: String) async throws {
        try await js("(()=>{const e=document.querySelector('\(selector)');const r=e.getBoundingClientRect();document.elementFromPoint(r.x+r.width/2,r.y+r.height/2).click()})()")
        try await pause()
    }

    private func nativeClickNext() async throws {
        let center = try await js("(()=>{const r=document.querySelector('ytmusic-player-bar #next-button button').getBoundingClientRect();return [r.x+r.width/2,r.y+r.height/2]})()") as! [NSNumber]
        let browser = widget.webView!
        let local = NSPoint(x: center[0].doubleValue, y: browser.isFlipped ? center[1].doubleValue : browser.bounds.height-center[1].doubleValue)
        let point = browser.convert(local, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: widget.panel.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            widget.panel.sendEvent(event)
        }
    }

    private func verify() async throws {
        widget = MusicWidget(home: URL(string: CommandLine.arguments[1])!, defaults: preferences, dataStore: .nonPersistent())
        try check("Fresh Music defaults to interacting without focus first", !widget.focusBeforeInteraction)
        try check("Disabled widget has no browser", widget.webView == nil)
        widget.show()
        try await wait("document.readyState==='complete' && !!window.fixture && !!window.__musicframe")
        try await pause()
        let proposedMini = NSRect(x: 50, y: 50, width: 600, height: 200)
        let fittedMini = widget.frameForUserResize(proposedMini)
        try check("Mini manual resizing fixes height and limits width", fittedMini.width == 560 && fittedMini.height == 72 && fittedMini.maxY == proposedMini.maxY)
        try check("Mini manual resizing enforces minimum width", widget.frameForUserResize(NSRect(x: 50, y: 50, width: 100, height: 100)).width == 340)
        try check("Fresh browser enables native back swipe", widget.webView?.allowsBackForwardNavigationGestures == true)
        WidgetWindow.onChange = { [weak self] in self?.publications += 1 }
        for theme in Theme.allCases {
            widget.setTheme(theme)
            try await pause()
            for expanded in [false, true] {
                widget.setExpanded(expanded)
                try await pause()
                try check("\(theme.rawValue) \(expanded ? "full" : "mini") native playback button has no focus outline", try await yes("(()=>{const button=document.querySelector('ytmusic-player-bar #play-pause-button button');button.focus();const style=getComputedStyle(button);return style.outlineStyle==='none'||parseFloat(style.outlineWidth)===0})()"))
                let frame = widget.panel.frame
                let count = publications
                try await js("window.baseline=JSON.stringify(fixtureSnapshot());window.styleWrites=0;window.styleObserver=new MutationObserver(r=>styleWrites+=r.length);styleObserver.observe(document.querySelector('#__music'),{childList:true,subtree:true,characterData:true});window.initialClicks=fixture.clicks;window.motion=[];window.loadingSamples=[];window.recordMotion=true;function sample(){if(!recordMotion)return;motion.push(JSON.stringify(fixtureSnapshot()));const p=document.querySelector('ytmusic-player-bar #play-pause-button');if(p.hidden){const a=p.getBoundingClientRect(),b=p.nextElementSibling.getBoundingClientRect();loadingSamples.push(Math.abs(a.x+a.width/2-b.x-b.width/2)<0.1&&Math.abs(a.y+a.height/2-b.y-b.height/2)<0.1&&getComputedStyle(p).visibility==='hidden'&&getComputedStyle(p.nextElementSibling).display!=='none')}requestAnimationFrame(sample)}requestAnimationFrame(sample)")
                for _ in 0..<12 {
                    try await click("ytmusic-player-bar #play-pause-button button")
                    try check("\(theme.rawValue) \(expanded ? "full" : "mini") playback keeps native frame", widget.panel.frame == frame)
                    try check("\(theme.rawValue) \(expanded ? "full" : "mini") playback keeps strip, artwork and control rectangles", try await yes("JSON.stringify(fixtureSnapshot())===baseline"))
                }
                try await js("window.recordMotion=false")
                try check("\(theme.rawValue) \(expanded ? "full" : "mini") loading keeps native control slots on every frame", try await yes("motion.length>0 && motion.every(r=>r===baseline)"))
                try check("\(theme.rawValue) \(expanded ? "full" : "mini") native loader stays centered in reserved play slot", try await yes("loadingSamples.length>0 && loadingSamples.every(Boolean)"))
                try check("\(theme.rawValue) \(expanded ? "full" : "mini") playback keeps native click handlers", try await yes("fixture.clicks-initialClicks===12"))
                try check("\(theme.rawValue) \(expanded ? "full" : "mini") playback makes no native size publication", publications == count)
                try check("\(theme.rawValue) \(expanded ? "full" : "mini") playback makes no stylesheet writes", try await yes("styleWrites===0"))
                try check("\(theme.rawValue) \(expanded ? "full" : "mini") button targets and icon centers stay fixed", try await yes("fixtureSnapshot().filter(e=>e.button).every(e=>e.button[2]>=36&&e.button[3]===40&&Math.abs(e.button[0]+e.button[2]/2-e.icon[0]-e.icon[2]/2)<0.1&&Math.abs(e.button[1]+e.button[3]/2-e.icon[1]-e.icon[3]/2)<0.1)"))
                try check("\(theme.rawValue) \(expanded ? "full" : "mini") native controls retain hit targets", try await yes("[...document.querySelectorAll('ytmusic-player-bar yt-icon-button:not([hidden]) button')].every(b=>{const r=b.getBoundingClientRect();return [[10,10],[r.width-10,10],[10,r.height-10],[r.width-10,r.height-10],[r.width/2,3],[r.width/2,r.height-3],[3,r.height/2],[r.width-3,r.height/2]].every(([x,y])=>b.contains(document.elementFromPoint(r.x+x,r.y+y)))})"))
                try await js("styleObserver.disconnect()")
            }
        }
        try await click("ytmusic-player-bar #previous-button button")
        try await click("ytmusic-player-bar #next-button button")
        try check("Native Previous and Next handlers survive", try await yes("fixture.previous===1 && fixture.next===1"))
        // Exercise AppKit delivery to the actual fixture Next button. JavaScript
        // clicks above deliberately test layout and do not cross this boundary.
        let otherWindow = NSWindow(contentRect: NSRect(x: 30, y: 30, width: 160, height: 100),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        otherWindow.isReleasedWhenClosed = false
        defer { otherWindow.close() }
        NSApp.activate(ignoringOtherApps: true)
        otherWindow.makeKeyAndOrderFront(nil)
        try await pause(0.3)
        try check("Music is inactive before native Next click", otherWindow.isKeyWindow && !widget.panel.isKeyWindow)
        try await nativeClickNext()
        try await pause(0.5)
        try check("Fresh Music delivers inactive native Next click exactly once", try await yes("fixture.next===2"))
        otherWindow.close()
        widget.setExpanded(false)
        try await pause()
        try await click(".thumbnail-image-wrapper")
        try await wait("window.__musicMini===false && document.querySelector('ytmusic-app-layout').hasAttribute('player-page-open')")
        try check("Artwork opens the native now playing page", widget.expanded)
        try check("Full native playback button has no focus outline", try await yes("(()=>{const button=document.querySelector('ytmusic-player-controls #play-pause-button button');button.focus();const style=getComputedStyle(button);return style.outlineStyle==='none'||parseFloat(style.outlineWidth)===0})()"))
        try check("Full now playing hides the duplicate strip", try await yes("getComputedStyle(document.querySelector('ytmusic-player-bar')).display==='none'"))
        try await js("window.baseline=JSON.stringify(fixtureSnapshot());window.initialClicks=fixture.clicks")
        let fullFrame = widget.panel.frame
        for _ in 0..<12 { try await click("ytmusic-player-controls #play-pause-button button") }
        let largeStable = try await yes("JSON.stringify(fixtureSnapshot())===baseline && fixture.clicks-initialClicks===12")
        try check("Native large play/pause keeps frame and controls", widget.panel.frame == fullFrame && largeStable)
        try await click("ytmusic-player-page #collapse-button button")
        try await wait("window.__musicMini===true")
        try check("Native collapse returns to mini", !widget.expanded)
        try await click("ytmusic-player-bar .toggle-player-page-button button")
        try await wait("window.__musicMini===false")
        try check("Native strip arrow expands", widget.expanded)
        try await js("document.querySelector('#native-search').dispatchEvent(new MouseEvent('dblclick',{bubbles:true}))")
        try await pause()
        try check("Double-clicking native header control keeps full mode", widget.expanded)
        try await js("document.querySelector('ytmusic-nav-bar').dispatchEvent(new MouseEvent('dblclick',{bubbles:true}))")
        try await pause()
        try check("Double-clicking empty header returns to mini", !widget.expanded)
        widget.setExpanded(true)
        try await pause()
        let fittedFull = widget.frameForUserResize(NSRect(x: 50, y: 50, width: 100, height: 100))
        try check("Full manual resizing preserves minimum readable size", fittedFull.width == 340 && fittedFull.height == 360)
        try await js("history.pushState({},'', '?search=1')")
        try check("Native browsing search input remains", try await yes("getComputedStyle(document.querySelector('input')).display!=='none'"))
        widget.goBack()
        try await wait("location.search===''")
        try check("Native history Back remains", true)
        widget.resize(to: NSSize(width: 600, height: 610))
        let resizedFrame = widget.panel.frame
        widget.focus()
        try await pause()
        try check("Focusing full player preserves user size and position", widget.panel.frame == resizedFrame)
        weak var oldBrowser = widget.webView
        widget.close()
        try await pause(0.3)
        try check("Off releases the browser", widget.webView == nil && oldBrowser == nil)
        widget.show()
        try await wait("document.readyState==='complete' && !!window.fixture")
        try check("On creates a fresh stopped player", try await yes("fixture.clicks===0 && fixture.playing===false"))
        try check("Recreated browser restores back swipe", widget.webView?.allowsBackForwardNavigationGestures == true)
        widget.close()
        widget.setFocusBeforeInteraction(true)
        widget = MusicWidget(home: URL(string: CommandLine.arguments[1])!, defaults: preferences, dataStore: .nonPersistent())
        try check("Stored focus-first preference overrides fresh Music default", widget.focusBeforeInteraction && widget.webView == nil)
        widget.show()
        try await wait("document.readyState==='complete' && !!window.fixture")
        widget.close()
        widget.show()
        try await wait("document.readyState==='complete' && !!window.fixture")
        try check("Music keeps stored focus-first preference after off/on", widget.focusBeforeInteraction)
        WidgetWindow.onChange = nil
    }
}

@main struct VerifyMusic {
    static func main() {
        let app = NSApplication.shared
        let delegate = MusicVerification()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
