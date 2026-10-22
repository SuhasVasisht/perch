import AppKit
import WebKit

private let appDelegate = AppDelegate()

final class AppDelegate: NSObject, NSApplicationDelegate {
    let x = XWidget()
    let music = MusicWidget()
    var perch: PerchController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The composition root is the only place that registers app-specific
        // metadata and actions. Settings, shortcuts and the tray share this list.
        let registrations = [
            WidgetRegistration(
                widget: x, icon: WidgetIcon.x(),
                help: "Use ↑ and ↓ to browse posts, Enter for comments, and ← to return. Double-tap ↑ anywhere in Home to refresh to the latest post.",
                shortcut: "1",
                settings: [.action(WidgetAction(title: "Sign Out of X…", perform: { [x] in x.signOut() }))],
                navigationActions: [WidgetAction(title: "Resume Reading", isEnabled: { [x] in x.canResumeReading },
                                                 perform: { [x] in x.resumeReading() })]
            ),
            WidgetRegistration(
                widget: music, icon: WidgetIcon.music(),
                help: "Use YouTube Music's own controls. Its player arrow switches between mini and full size.",
                shortcut: "2",
                settings: [.toggle(title: "Mini Player", get: { [music] in !music.expanded },
                                   set: { [music] mini in music.setExpanded(!mini) })],
                menuActions: [WidgetAction(title: "Mini Player", key: "m", modifiers: [.command, .shift],
                                          isOn: { [music] in !music.expanded }, perform: { [music] in
                    music.focus()
                    music.toggleExpanded()
                })]
            ),
        ]
        let perch = PerchController(registrations: registrations)
        self.perch = perch
        perch.install()
        // Off widgets have no web view. Their account store and preferences stay.
        for registration in registrations where registration.widget.wasOpen { registration.widget.show() }
        if !registrations.contains(where: { $0.widget.isEnabled }) { perch.showWindow() }
        NSApp.activate()
        #if DEBUG
        DebugChannel.install(widgets: [x, music], perch: perch)
        #endif
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        perch?.showWindow()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard x.isEnabled else { return .terminateNow }
        var replied = false
        let finish = {
            guard !replied else { return }
            replied = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        let deadline = DispatchWorkItem(block: finish)
        x.saveSession {
            DispatchQueue.main.async {
                deadline.cancel()
                finish()
            }
        }
        // A stopped web process must not prevent Quit. Healthy checkpoints
        // complete immediately; this is only the unresponsive-process bound.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: deadline)
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
enum PerchMain {
    static func main() {
        if CommandLine.arguments.dropFirst().elementsEqual(["--version"]) {
            let info = Bundle.main.infoDictionary ?? [:]
            print("Perch \(info["CFBundleShortVersionString"] as? String ?? "unknown") (\(info["CFBundleVersion"] as? String ?? "unknown"))")
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = appDelegate
        app.run()
    }
}

#if DEBUG
/// Development-only remote control so changes can be checked without
/// clicking through the live accounts. Built only by `./build.sh debug`.
/// Post `local.perch.debug` with a string such as `js music document.title`.
/// Results go to /tmp/perch-debug.txt.
enum DebugChannel {
    static func install(widgets: [WidgetWindow], perch: PerchController) {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("local.perch.debug"),
            object: nil,
            queue: .main
        ) { note in
            guard let command = note.object as? String else { return }
            run(command, widgets: widgets, perch: perch)
        }
    }

    private static func write(_ text: String) {
        try? text.write(toFile: "/tmp/perch-debug.txt", atomically: true, encoding: .utf8)
    }

    private static func run(_ command: String, widgets: [WidgetWindow], perch: PerchController) {
        let parts = command.split(separator: " ", maxSplits: 2).map(String.init)
        guard let verb = parts.first else { return }
        let widget = parts.count > 1 ? widgets.first { $0.id == parts[1] } : nil
        let arg = parts.count > 2 ? parts[2] : ""
        switch verb {
        case "js":
            guard let browser = widget?.webView else { write("disabled"); return }
            browser.evaluateJavaScript(arg) { result, error in
                write(error.map { "ERROR \($0)" } ?? String(describing: result ?? "nil"))
            }
        case "theme": if let theme = Theme(rawValue: arg) { widget?.setTheme(theme) }; write("ok")
        case "frost": widget?.setFrost(Double(arg) ?? 0.9); write("ok")
        case "show": widget?.show(); write("ok")
        case "hide": widget?.close(); write("ok")
        case "load": if let url = URL(string: arg) { widget?.webView?.load(URLRequest(url: url)) }; write("ok")
        case "back": widget?.goBack(); write("ok")
        case "mini": (widget as? MusicWidget)?.setExpanded(arg != "on"); write("ok")
        case "settings": perch.showWindow(); write("ok")
        case "chrome":
            guard let widget, widget.isEnabled else { write("disabled"); return }
            widget.chrome.pointerEntered()
            if arg == "move" { widget.chrome.moveControl.performClick(nil) }
            if arg == "resize" { widget.chrome.resizeControl.performClick(nil) }
            write("ok")
        case "front": widget?.panel.orderFrontRegardless(); write("ok")
        case "focus":
            widget?.focus()
            NSApp.activate()
            write("ok")
        case "state":
            guard let widget else { write("missing widget"); return }
            let state: [String: Any] = [
                "visible": widget.isVisible, "enabled": widget.isEnabled, "key": widget.panel.isKeyWindow,
                "primaryScreenBounds": NSStringFromRect(NSScreen.screens.first?.frame ?? .zero),
                "screenFrame": NSStringFromRect(widget.screenFrame),
                "windowNumber": widget.panel.windowNumber,
                "chromeWindowNumber": widget.chrome.accessory.windowNumber,
                "chromeVisible": widget.chrome.accessory.isVisible,
                "chromeFrame": NSStringFromRect(widget.chrome.accessory.frame),
                "userResizing": widget.isUserResizing,
                "theme": widget.theme.rawValue, "front": widget.keepsInFront,
                "focusBeforeInteraction": widget.focusBeforeInteraction,
                "frame": NSStringFromRect(widget.panel.frame),
                "width": widget.panel.frame.width, "height": widget.panel.frame.height,
                "top": widget.panel.frame.maxY,
                "expanded": (widget as? MusicWidget)?.expanded ?? false,
                "url": widget.webView?.url?.absoluteString ?? "",
                "canGoBack": widget.webView?.canGoBack ?? false,
                "canGoForward": widget.webView?.canGoForward ?? false,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) { write(text) }
        default: write("unknown")
        }
    }
}
#endif
