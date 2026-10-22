import AppKit

/// Test-only presentation and lifecycle boundary. Never participates in OS focus.
enum OffscreenHost {
    static var isActive = true
    static func present(_ panel: NSPanel) {
        panel.styleMask.insert(.nonactivatingPanel)
        panel.alphaValue = 0.001
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.orderFrontRegardless()
    }
    static func show(_ widget: WidgetWindow) { widget.show() }
    static func setActivity(_ widget: WidgetWindow, _ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        widget.updateBrowserActivity()
    }
    static func safetyFailures() -> [String] {
        var failures: [String] = []
        if NSApp.isActive { failures.append("host app became active") }
        if NSApp.keyWindow != nil { failures.append("host acquired key window") }
        for window in NSApp.windows {
            // AppKit may lazily allocate an invisible text-input window. Keep
            // even that framework-owned window inert before it can be shown.
            if !window.isVisible { window.alphaValue = 0.001; window.ignoresMouseEvents = true }
            if window.alphaValue > 0.001 { failures.append("window \(type(of: window)) title=\(window.title) alpha=\(window.alphaValue) visible=\(window.isVisible) exceeds .001") }
            if !window.ignoresMouseEvents { failures.append("window \(type(of: window)) title=\(window.title) accepts mouse input visible=\(window.isVisible)") }
        }
        return failures
    }
}
