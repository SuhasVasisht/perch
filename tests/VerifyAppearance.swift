import AppKit
import WebKit

private struct AppearanceFailure: Error { let message: String }

private final class AppearanceWidget: WidgetWindow {
    var loaded = false
    override var initialSize: NSSize { NSSize(width: 420, height: 260) }
    override func pageDidFinishLoading() { loaded = true }
}

private final class Checkerboard: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let colors: [NSColor] = [.systemRed, .systemBlue, .systemYellow, .systemGreen]
        for y in stride(from: 0, to: Int(bounds.height), by: 60) {
            for x in stride(from: 0, to: Int(bounds.width), by: 60) {
                colors[(x / 60 + y / 60) % colors.count].setFill()
                NSRect(x: x, y: y, width: 60, height: 60).fill()
            }
        }
    }
}

@MainActor
private final class AppearanceFocusTarget: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ note: Notification) {
        let screen = NSScreen.main!.visibleFrame
        window = NSWindow(contentRect: NSRect(x: screen.minX + 24, y: screen.minY + 24, width: 180, height: 90),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Local appearance focus target"
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

@MainActor
private final class AppearanceVerification: NSObject, NSApplicationDelegate {
    let suite = "local.perch.appearance-verification.\(UUID().uuidString)"
    var preferences: UserDefaults!
    var widget: AppearanceWidget!
    var backdrop: NSWindow!
    var other: NSWindow!
    var helper: Process?
    var checks = 0
    var states: [[String: Any]] = []
    var firstDOM: [String: Any]?
    let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)

    func applicationDidFinishLaunching(_ note: Notification) {
        preferences = UserDefaults(suiteName: suite)!
        Task {
            do {
                try await verify()
                try writeStates()
                print("Completed \(checks) production appearance state/layout checks. Composited pixel comparisons follow in Python.")
                cleanup()
                exit(0)
            } catch {
                print("FAIL \(error)")
                try? writeStates()
                cleanup()
                exit(1)
            }
        }
    }

    func cleanup() {
        if let helper, helper.isRunning { helper.terminate(); helper.waitUntilExit() }
        widget?.close()
        backdrop?.orderOut(nil)
        other?.orderOut(nil)
        preferences.removePersistentDomain(forName: suite)
    }

    func check(_ name: String, _ passed: Bool) throws {
        guard passed else { throw AppearanceFailure(message: name) }
        print("PASS \(name)"); fflush(stdout); checks += 1
    }

    func pause(_ seconds: Double = 0.35) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func wait(_ name: String, _ condition: () -> Bool) async throws {
        for _ in 0..<60 {
            if condition() { return }
            try await pause(0.1)
        }
        throw AppearanceFailure(message: "Timed out: \(name)")
    }

    func activate(_ window: NSWindow) async throws {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await wait("local window becomes genuinely key") { NSApp.isActive && window.isKeyWindow }
        try await pause()
    }

    func materialViews(_ view: NSView) -> [NSVisualEffectView] {
        (view as? NSVisualEffectView).map { [$0] } ?? view.subviews.flatMap { materialViews($0) }
    }

    func verify() async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let screen = NSScreen.main!.visibleFrame
        let frame = NSRect(x: screen.midX - 210, y: screen.midY - 130, width: 420, height: 260)
        backdrop = NSWindow(contentRect: frame.insetBy(dx: -30, dy: -30), styleMask: [.borderless], backing: .buffered, defer: false)
        backdrop.isReleasedWhenClosed = false
        backdrop.hidesOnDeactivate = false
        backdrop.level = .floating
        backdrop.contentView = Checkerboard(frame: backdrop.contentView!.bounds)
        backdrop.orderFront(nil)
        other = NSWindow(contentRect: NSRect(x: screen.minX + 24, y: screen.minY + 24, width: 180, height: 90),
                         styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.title = "Local appearance focus target"
        try await activate(other)
        preferences.set("glass", forKey: "appearanceTheme")
        preferences.set(0, forKey: "appearanceFrost")
        preferences.set(Double(frame.minX), forKey: "appearanceX")
        preferences.set(Double(frame.minY), forKey: "appearanceY")
        widget = AppearanceWidget(id: "appearance", title: "Appearance fixture", home: URL(string: CommandLine.arguments[1])!,
                                  prefix: "appearance", originKeys: ("appearanceX", "appearanceY"), script: "",
                                  defaults: preferences, dataStore: .nonPersistent())
        widget.show()
        // Match two enabled widgets at launch: the second becomes key before
        // the first browser's asynchronous page load and first content paint.
        other.makeKeyAndOrderFront(nil)
        widget.panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        try await wait("local production browser loads") { self.widget.loaded }
        widget.panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        try await wait("other local window owns initial focus") { NSApp.isActive && self.other.isKeyWindow && !self.widget.panel.isKeyWindow }
        try await pause(0.5)
        try await record("clear-initial-paint-inactive", expectedKey: false, expectedActive: true)

        for (name, frost) in [("clear", 0.0), ("frosted", 1.0)] {
            widget.setFrost(frost)
            widget.panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
            let material = materialViews(widget.panel.contentView!).first!
            try check("\(name) uses public always-active HUD material policy", material.state == .active && material.material == .hudWindow && material.blendingMode == .behindWindow)
            try check("\(name) material visibility matches preference", material.isHidden == (frost < 0.5))
            try await activate(other)
            try await record("\(name)-first-inactive", expectedKey: false, expectedActive: true)
            try await activate(widget.panel)
            widget.panel.makeFirstResponder(widget.webView)
            try await record("\(name)-focused", expectedKey: true, expectedActive: true)
            try await activate(other)
            try await record("\(name)-resigned", expectedKey: false, expectedActive: true)
            helper = Process()
            helper!.executableURL = URL(fileURLWithPath: CommandLine.arguments[3])
            helper!.arguments = ["--focus-target"]
            try helper!.run()
            try await wait("separate local helper owns foreground") { !NSApp.isActive && !self.widget.panel.isKeyWindow }
            try await pause(0.5)
            try await record("\(name)-app-inactive", expectedKey: false, expectedActive: false)
            helper!.terminate(); helper!.waitUntilExit(); helper = nil
        }
    }

    func record(_ name: String, expectedKey: Bool, expectedActive: Bool) async throws {
        try check("\(name) reports honest application/window focus", widget.panel.isKeyWindow == expectedKey && NSApp.isActive == expectedActive)
        let dom = try await widget.webView!.evaluateJavaScript("({width:innerWidth,height:innerHeight,text:document.getElementById('label').textContent,rect:(()=>{let r=document.getElementById('label').getBoundingClientRect();return [r.x,r.y,r.width,r.height]})()})") as! [String: Any]
        if let firstDOM {
            try check("\(name) preserves page text and exact DOM geometry", NSDictionary(dictionary: dom).isEqual(to: firstDOM))
        } else { firstDOM = dom }
        try check("\(name) keeps the browser filling its original page bounds", widget.webView!.bounds.size == NSSize(width: 420, height: 260))
        // The captured inset is fully inside our own opaque checkerboard window,
        // including while the fixture app is inactive. No desktop is captured.
        let frame = widget.panel.frame.insetBy(dx: 24, dy: 24)
        let primary = NSScreen.screens[0].frame
        let target = output.appendingPathComponent("appearance-\(name).png")
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-R", "\(Int(frame.minX)),\(Int(primary.maxY - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))", target.path]
        try capture.run(); capture.waitUntilExit()
        try check("\(name) captures the real composited local fixture", capture.terminationStatus == 0 && FileManager.default.fileExists(atPath: target.path))
        states.append(["name": name, "key": widget.panel.isKeyWindow, "active": NSApp.isActive,
                       "frame": NSStringFromRect(widget.panel.frame), "captureFrame": NSStringFromRect(frame),
                       "browserBounds": NSStringFromRect(widget.webView!.bounds), "dom": dom,
                       "material": "hudWindow", "state": "active", "frost": widget.frost,
                       "image": target.lastPathComponent])
    }

    func writeStates() throws {
        let data = try JSONSerialization.data(withJSONObject: states, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("appearance-states.json"))
    }
}

@main
private enum VerifyAppearance {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        if CommandLine.arguments.contains("--focus-target") {
            let delegate = AppearanceFocusTarget()
            app.delegate = delegate
            app.run()
        } else {
            let delegate = AppearanceVerification()
            app.delegate = delegate
            app.run()
        }
    }
}
