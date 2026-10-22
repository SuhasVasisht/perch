import AppKit

final class WidgetAccessoryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Native controls live above the page, so page layout and hit targets stay intact.
final class WidgetChromeController: NSObject {
    static let stripHeight: CGFloat = 28
    weak var owner: WidgetWindow?
    let accessory = WidgetAccessoryPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let outline = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private var observations: [NSObjectProtocol] = []
    private var pendingHide: DispatchWorkItem?
    private var hovering = false
    private var manipulating = false
    private(set) var isResizing = false
    let moveControl = WidgetChromeControl()
    let resizeControl = WidgetChromeControl()
    private let tracking = WidgetChromeTrackingView()

    init(owner: WidgetWindow) {
        self.owner = owner
        super.init()
        for window in [accessory, outline] {
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }
        outline.ignoresMouseEvents = true
        let border = NSView()
        border.wantsLayer = true
        border.layer?.borderWidth = 0.75
        border.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        border.layer?.cornerRadius = owner.cornerRadius
        border.layer?.cornerCurve = .continuous
        outline.contentView = border

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 9
        effect.layer?.masksToBounds = true
        accessory.contentView = effect
        accessory.appearance = NSAppearance(named: .aqua)
        accessory.setAccessibilityLabel("\(owner.title) window controls")
        let stripTracking = WidgetChromeTrackingView()
        stripTracking.controller = self
        stripTracking.frame = NSRect(x: 0, y: 0, width: 164, height: Self.stripHeight)
        stripTracking.autoresizingMask = [.width, .height]
        effect.addSubview(stripTracking)
        configure(moveControl, image: "hand.draw", title: "Move \(owner.title)", resizing: false)
        configure(resizeControl, image: "arrow.up.left.and.arrow.down.right", title: "Resize \(owner.title)", resizing: true)
        resizeControl.title = ""
        resizeControl.imagePosition = .imageOnly
        moveControl.frame = NSRect(x: 4, y: 2, width: 104, height: 24)
        moveControl.title = "Move"
        resizeControl.frame = NSRect(x: 112, y: 2, width: 48, height: 24)
        effect.addSubview(moveControl)
        effect.addSubview(resizeControl)
        tracking.controller = self
        tracking.frame = owner.panel.contentView?.bounds ?? .zero
        tracking.autoresizingMask = [.width, .height]
        owner.panel.contentView?.addSubview(tracking)
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: owner.panel, queue: .main) { [weak self] _ in
                self?.update()
            })
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: accessory, queue: .main) { [weak self] _ in
                self?.update()
            })
        }
    }

    deinit {
        pendingHide?.cancel()
        for observation in observations { NotificationCenter.default.removeObserver(observation) }
    }

    private func configure(_ control: WidgetChromeControl, image: String, title: String, resizing: Bool) {
        control.target = self
        control.action = #selector(focusControl(_:))
        control.controller = self
        control.resizing = resizing
        control.bezelStyle = .accessoryBarAction
        control.isBordered = false
        control.focusRingType = .none
        control.cell?.isSelectable = false
        control.image = NSImage(systemSymbolName: image, accessibilityDescription: title)
        control.imagePosition = .imageLeading
        control.controlSize = .small
        control.font = .systemFont(ofSize: 11)
        control.toolTip = "\(title). Drag, or use arrow keys. Option adjusts one point."
        control.setAccessibilityLabel(title)
    }

    @objc private func focusControl(_ sender: WidgetChromeControl) {
        pendingHide?.cancel()
        owner?.focus()
        update()
        accessory.makeKeyAndOrderFront(nil)
        accessory.makeFirstResponder(sender)
    }

    func pointerEntered() {
        pendingHide?.cancel()
        hovering = true
        update()
    }

    func pointerExited() {
        pendingHide?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, let owner = self.owner else { return }
            let mouse = NSEvent.mouseLocation
            self.hovering = owner.panel.frame.contains(mouse) || self.accessory.frame.contains(mouse)
            self.update()
        }
        pendingHide = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: item)
    }

    func update() {
        guard let owner, owner.isEnabled, owner.isVisible else { hide(); return }
        let frame = owner.panel.frame
        outline.setFrame(frame, display: true)
        let width: CGFloat = 164
        let screen = owner.screenFrame
        let x = min(max(frame.midX - width / 2, screen.minX), screen.maxX - width)
        // clamped() reserves this strip above every widget, including automatic fits.
        accessory.setFrame(NSRect(x: x, y: frame.maxY, width: width, height: Self.stripHeight), display: true)
        outline.level = owner.panel.level
        accessory.level = owner.panel.level
        if hovering {
            if outline.parent == nil { owner.panel.addChildWindow(outline, ordered: .above) }
            outline.orderFront(nil)
        } else { outline.orderOut(nil) }
        if hovering || accessory.isKeyWindow || manipulating {
            if accessory.parent == nil { owner.panel.addChildWindow(accessory, ordered: .above) }
            accessory.orderFront(nil)
        } else { accessory.orderOut(nil) }
    }

    func hide() {
        pendingHide?.cancel()
        hovering = false
        manipulating = false
        isResizing = false
        for window in [accessory, outline] {
            window.parent?.removeChildWindow(window)
            window.orderOut(nil)
        }
    }

    func beginManipulation(resizing: Bool) {
        manipulating = true
        isResizing = resizing
        if !accessory.isKeyWindow { owner?.focus() }
        if resizing, let panel = owner?.panel {
            panel.delegate?.windowWillStartLiveResize?(Notification(name: NSWindow.willStartLiveResizeNotification, object: panel))
        }
        update()
    }

    func apply(delta: NSPoint, startingFrame: NSRect, resizing: Bool) {
        guard let owner else { return }
        var frame = startingFrame
        if resizing {
            frame.size.width += delta.x
            frame.size.height -= delta.y
            frame.origin.y += delta.y
        } else {
            frame.origin.x += delta.x
            frame.origin.y += delta.y
        }
        owner.panel.setFrame(resizing ? owner.frameForUserResize(frame) : owner.clamped(frame), display: true)
        owner.saveOrigin()
        update()
    }

    func endManipulation(resizing: Bool) {
        isResizing = false
        if resizing, let panel = owner?.panel {
            panel.delegate?.windowDidEndLiveResize?(Notification(name: NSWindow.didEndLiveResizeNotification, object: panel))
        }
        manipulating = false
        update()
        pointerExited()
    }
}

final class WidgetChromeTrackingView: NSView {
    weak var controller: WidgetChromeController?
    private var area: NSTrackingArea?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        if let area { addTrackingArea(area) }
    }
    override func mouseEntered(with event: NSEvent) { controller?.pointerEntered() }
    override func mouseExited(with event: NSEvent) { controller?.pointerExited() }
}

final class WidgetChromeControl: NSButton {
    weak var controller: WidgetChromeController?
    var resizing = false
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let controller, let owner = controller.owner else { return }
        let start = window?.convertPoint(toScreen: event.locationInWindow) ?? .zero
        let frame = owner.panel.frame
        controller.beginManipulation(resizing: resizing)
        var didDrag = false
        while let next = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            if next.type == .leftMouseUp { break }
            didDrag = true
            let point = next.window?.convertPoint(toScreen: next.locationInWindow) ?? start
            controller.apply(delta: NSPoint(x: point.x - start.x, y: point.y - start.y), startingFrame: frame, resizing: resizing)
        }
        controller.endManipulation(resizing: resizing)
        if !didDrag { performClick(nil) }
    }

    override func keyDown(with event: NSEvent) {
        guard let controller, let owner = controller.owner else { return }
        let step: CGFloat = event.modifierFlags.contains(.option) ? 1 : 10
        let delta: NSPoint
        switch event.keyCode {
        case 123: delta = NSPoint(x: -step, y: 0)
        case 124: delta = NSPoint(x: step, y: 0)
        case 125: delta = NSPoint(x: 0, y: -step)
        case 126: delta = NSPoint(x: 0, y: step)
        default: super.keyDown(with: event); return
        }
        controller.beginManipulation(resizing: resizing)
        controller.apply(delta: delta, startingFrame: owner.panel.frame, resizing: resizing)
        controller.endManipulation(resizing: resizing)
    }
}
