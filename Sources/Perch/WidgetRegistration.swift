import AppKit

struct WidgetAction {
    let title: String
    let key: String
    let modifiers: NSEvent.ModifierFlags
    let isEnabled: () -> Bool
    let isOn: (() -> Bool)?
    let perform: () -> Void

    init(title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [.command],
         isEnabled: @escaping () -> Bool = { true }, isOn: (() -> Bool)? = nil,
         perform: @escaping () -> Void) {
        self.title = title
        self.key = key
        self.modifiers = modifiers
        self.isEnabled = isEnabled
        self.isOn = isOn
        self.perform = perform
    }
}

enum WidgetSetting {
    case toggle(title: String, get: () -> Bool, set: (Bool) -> Void)
    case action(WidgetAction)
    case note(String)
}

struct WidgetRegistration {
    let widget: WidgetWindow
    let icon: NSImage
    let help: String
    let shortcut: String
    let settings: [WidgetSetting]
    let menuActions: [WidgetAction]
    let navigationActions: [WidgetAction]

    init(widget: WidgetWindow, icon: NSImage = WidgetIcon.system("app"), help: String,
         shortcut: String, settings: [WidgetSetting] = [], menuActions: [WidgetAction] = [],
         navigationActions: [WidgetAction] = []) {
        self.widget = widget
        self.icon = icon
        self.help = help
        self.shortcut = shortcut
        self.settings = settings
        self.menuActions = menuActions
        self.navigationActions = navigationActions
    }
}

enum WidgetIcon {
    static func system(_ name: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!
    }

    static func x() -> NSImage {
        let image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { _ in
            NSColor.labelColor.setFill()
            let shape = NSBezierPath()
            shape.move(to: NSPoint(x: 5, y: 27)); shape.line(to: NSPoint(x: 11, y: 27))
            shape.line(to: NSPoint(x: 27, y: 5)); shape.line(to: NSPoint(x: 21, y: 5)); shape.close()
            shape.fill()
            let stroke = NSBezierPath()
            stroke.move(to: NSPoint(x: 26, y: 27)); stroke.line(to: NSPoint(x: 6, y: 5))
            stroke.lineWidth = 2; stroke.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    static func music() -> NSImage {
        NSImage(size: NSSize(width: 32, height: 32), flipped: false) { _ in
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 30, height: 30)).fill()
            NSColor.white.setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: 6, y: 6, width: 20, height: 20))
            ring.lineWidth = 1.5; ring.stroke()
            NSColor.white.setFill()
            let play = NSBezierPath()
            play.move(to: NSPoint(x: 13, y: 10)); play.line(to: NSPoint(x: 23, y: 16))
            play.line(to: NSPoint(x: 13, y: 22)); play.close(); play.fill()
            return true
        }
    }
}
