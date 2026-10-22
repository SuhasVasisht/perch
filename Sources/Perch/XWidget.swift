import AppKit
import WebKit

/// A compact X browser with native scrolling and saved WebKit history.
final class XWidget: WidgetWindow, NSWindowDelegate {
    private var width: CGFloat
    private var height: CGFloat
    private var automaticResize = false
    private var resizeGeneration = 0
    private var mode = "wait"
    private var browserGeneration = 0
    private var initialLoadGeneration = 0
    private let sessionKey = "feedInteractionState"
    private let positionKey = "feedReadingPosition"
    private struct PageOwner: Equatable {
        let documentId: String
        let entryKey: String
        let intentRevision: Int
        let url: String
        init?(_ body: [String: Any]) {
            guard let documentId = body["documentId"] as? String, !documentId.isEmpty,
                  let entryKey = body["entryKey"] as? String, !entryKey.isEmpty,
                  let intentRevision = body["intentRevision"] as? Int, intentRevision >= 0,
                  let url = body["url"] as? String else { return nil }
            self.documentId = documentId; self.entryKey = entryKey
            self.intentRevision = intentRevision; self.url = url
        }
        var dictionary: [String: Any] {
            ["documentId": documentId, "entryKey": entryKey, "intentRevision": intentRevision, "url": url]
        }
    }
    private var owner: PageOwner?
    private var snapshotRevision = -1
    private var captureGeneration = 0
    private var navigationGeneration = 0
    private var readyGeneration = 0
    private var committed = false
    private var suspended = false
    private var pendingRestore: [String: Any]?
    private var restoreDestination: String?
    private var restoreRevision: Int?


    init(home: URL = URL(string: "https://x.com/home")!, defaults: UserDefaults = .standard,
         dataStore: WKWebsiteDataStore = .default()) {
        let stored = CGFloat(defaults.double(forKey: "width"))
        width = stored >= 340 ? min(stored, 560) : 420
        let storedHeight = CGFloat(defaults.double(forKey: "feedHeight"))
        height = storedHeight >= 320 ? storedHeight : 640
        super.init(
            id: "x",
            title: "X",
            home: home,
            prefix: "feed",
            originKeys: (x: "originX", y: "originY"),
            script: CropScript.source,
            defaults: defaults,
            dataStore: dataStore
        )
        panel.minSize = NSSize(width: 340, height: 88)
        panel.maxSize = NSSize(width: 560, height: screenFrame.height - 16)
        panel.delegate = self
    }

    override func browserDidCreate(_ browser: PerchWebView) {
        browserGeneration += 1
        mode = "wait"
        owner = nil
        committed = false
        suspended = false
        browser.allowsBackForwardNavigationGestures = true
    }

    override func browserDidDeactivate(_ browser: PerchWebView) {
        guard self.webView === browser, !suspended else { return }
        suspended = true
        cancelFit()
        checkpoint(suspend: true)
    }

    override func browserDidActivate(_ browser: PerchWebView) {
        guard self.webView === browser, suspended else { return }
        suspended = false
        let navigation = navigationGeneration
        browser.evaluateJavaScript("window.__tfActivate && window.__tfActivate()") { [weak self, weak browser] value, _ in
            guard let self, let browser, self.webView === browser, self.navigationGeneration == navigation,
                  let body = value as? [String: Any], let next = PageOwner(body), self.accept(next) else { return }
            if self.pendingRestore != nil { self.restorePendingPosition() }
        }
    }

    override func browserWillClose(_ browser: PerchWebView) {
        initialLoadGeneration += 1
        checkpoint(suspend: true)
        cancelFit()
    }

    override func browserContentProcessDidTerminate(_ browser: PerchWebView) {
        guard self.webView === browser else { return }
        let url = browser.url ?? defaults.dictionary(forKey: positionKey).flatMap { ($0["url"] as? String).flatMap(URL.init(string:)) } ?? home
        prepareNavigation()
        pendingRestore = defaults.dictionary(forKey: positionKey)
        restoreDestination = url.absoluteString
        beginDocumentNavigation()
        if browser.url == url { browser.reload() } else { browser.load(URLRequest(url: url)) }
    }

    func webView(_ browser: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard browser === webView else { return }
        navigationGeneration += 1
        captureGeneration += 1
        owner = nil
        committed = false
        cancelFit()
    }

    func webView(_ browser: WKWebView, didCommit navigation: WKNavigation!) {
        guard browser === webView else { return }
        navigationGeneration += 1
        owner = nil
        snapshotRevision = -1
        committed = true
    }

    override var initialSize: NSSize { NSSize(width: width, height: height) }
    override var minimumHeight: CGFloat { 88 }

    override func loadInitialPage() {
        guard let webView else { return }
        initialLoadGeneration += 1
        let generation = initialLoadGeneration
        syncNightMode { [weak self, weak webView] _ in
            guard let self, let webView, self.webView === webView, self.initialLoadGeneration == generation else { return }
            self.loadSavedPage(webView)
        }
    }

    private func loadSavedPage(_ webView: PerchWebView) {
        if let data = defaults.data(forKey: sessionKey) {
            pendingRestore = defaults.dictionary(forKey: positionKey)
            restoreDestination = pendingRestore?["url"] as? String
            webView.interactionState = data
            if webView.backForwardList.currentItem != nil { return }
            pendingRestore = nil
            restoreDestination = nil
        }
        super.loadInitialPage()
    }

    private var postHeightLimit: CGFloat {
        max(88, min(screenFrame.height - 16, panel.frame.maxY - screenFrame.minY - 8))
    }

    override func applyTheme() {
        super.applyTheme()
        let clear = theme == .glass && frost < 0.5
        evaluate("window.__tfTheme = '\(theme.rawValue)'; window.__tfClearGlass = \(clear); window.__tfPostHeightLimit = \(Double(postHeightLimit)); window.__tfPaint && window.__tfPaint();")
    }

    /// Glass and Dark use X's black theme. Light uses X's light theme. X reads
    /// its display setting from the `night_mode` cookie when the page loads.
    override func themeDidChange(from old: Theme) {
        reloadPreservingPosition(onlyIfThemeChanged: true)
    }

    private func syncNightMode(_ done: @escaping (Bool) -> Void) {
        guard let webView else { done(false); return }
        let store = webView.configuration.websiteDataStore.httpCookieStore
        store.getAllCookies { [weak self, weak webView] cookies in
            guard let self, let webView, self.webView === webView else { done(false); return }
            // Resolve the requested theme after the asynchronous read. Rapid
            // changes must not enqueue a stale cookie value.
            let wanted = self.theme == .light ? "0" : "2"
            let current = cookies.first { $0.name == "night_mode" && $0.domain.hasSuffix("x.com") }
            if current?.value == wanted {
                done(false)
                return
            }
            let properties: [HTTPCookiePropertyKey: Any] = [
                .name: "night_mode",
                .value: wanted,
                .domain: ".x.com",
                .path: "/",
                .secure: "TRUE",
                .expires: Date().addingTimeInterval(60 * 60 * 24 * 365 * 5),
            ]
            guard let cookie = HTTPCookie(properties: properties) else {
                done(false)
                return
            }
            store.setCookie(cookie) { [weak self] in
                guard let self else { done(true); return }
                if (self.theme == .light ? "0" : "2") != wanted {
                    self.syncNightMode { _ in done(true) }
                } else { done(true) }
            }
        }
    }

    override func pageDidFinishLoading() {
        adoptDocument()
    }

    private func json(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// A ready message is only a hint. Query the current document before
    /// adopting its identity so queued messages from a departed page cannot win.
    private func adoptDocument() {
        guard let browser = webView, committed else { return }
        readyGeneration += 1
        let probe = readyGeneration
        let navigation = navigationGeneration
        browser.evaluateJavaScript("({owner:window.__tfOwner && window.__tfOwner(),mode:window.__tfMode && window.__tfMode()})") { [weak self, weak browser] value, _ in
            guard let self, let browser, self.webView === browser,
                  self.readyGeneration == probe, self.navigationGeneration == navigation,
                  let result = value as? [String: Any], let body = result["owner"] as? [String: Any],
                  let next = PageOwner(body), next.url == browser.url?.absoluteString else { return }
            guard self.owner?.documentId != next.documentId else { return }
            self.owner = next
            self.snapshotRevision = -1
            if let mode = result["mode"] as? String { self.applyMode(mode) }
            let inactive = !(self.panel.isKeyWindow && NSApp.isActive)
            self.suspended = inactive
            if inactive {
                self.checkpoint(suspend: true) { [weak self] accepted in
                    self?.restorePendingPosition()
                }
            } else if body["suspended"] as? Bool == true {
                browser.evaluateJavaScript("window.__tfActivate && window.__tfActivate()") { [weak self, weak browser] value, _ in
                    guard let self, let browser, self.webView === browser, self.navigationGeneration == navigation,
                          let body = value as? [String: Any], let next = PageOwner(body), self.accept(next) else { return }
                    self.restorePendingPosition()
                }
            } else { self.restorePendingPosition() }
        }
    }

    private func restorePendingPosition() {
        guard let browser = webView, let current = owner else { return }
        let position = pendingRestore
        let destination = restoreDestination
        if let position, destination == current.url, position["url"] as? String == current.url,
           let saved = json(position), let expected = json(current.dictionary) {
            browser.evaluateJavaScript("window.__tfRestorePosition && window.__tfRestorePosition(\(saved), \(expected)); window.__tfRefit && window.__tfRefit()", completionHandler: nil)
        } else {
            pendingRestore = nil
            restoreDestination = nil
            restoreRevision = nil
            browser.evaluateJavaScript("window.__tfRefit && window.__tfRefit()", completionHandler: nil)
        }
    }

    override func goBack() { traverseHistory(backward: true) }
    override func goForward() { traverseHistory(backward: false) }

    private func traverseHistory(backward: Bool) {
        guard let browser = webView, backward || browser.canGoForward else { return }
        initialLoadGeneration += 1
        let generation = initialLoadGeneration
        checkpoint(suspend: false) { [weak self, weak browser] _ in
            guard let self, let browser, self.webView === browser, self.initialLoadGeneration == generation else { return }
            self.prepareNavigation()
            if backward {
                if browser.canGoBack { browser.goBack() }
                else { browser.load(URLRequest(url: self.home)) }
            } else { browser.goForward() }
        }
    }

    /// Public callers request a paired anchor/history checkpoint, not an opaque
    /// WebKit state with a potentially older reading anchor.
    func saveSession(completion: (() -> Void)? = nil) {
        checkpoint(suspend: suspended) { _ in completion?() }
    }

    @discardableResult private func accept(_ next: PageOwner) -> Bool {
        guard let current = owner, next.documentId == current.documentId,
              next.url == (webView?.url?.absoluteString ?? current.url),
              next.intentRevision >= current.intentRevision,
              next.intentRevision > current.intentRevision || next.entryKey == current.entryKey else { return false }
        if next != current {
            cancelFit()
            owner = next
        }
        return true
    }

    @discardableResult private func savePosition(_ position: [String: Any], browser: PerchWebView?, capturedState: Data? = nil) -> Bool {
        guard let next = PageOwner(position), accept(next),
              let revision = position["snapshotRevision"] as? Int, revision > snapshotRevision,
              URL(string: next.url)?.host == home.host,
              position["restoring"] as? Bool != true,
              pendingRestore == nil || restoreRevision.map({ next.intentRevision == $0 }) == true,
              JSONSerialization.isValidJSONObject(position) else { return false }
        snapshotRevision = revision
        pendingRestore = nil
        restoreDestination = nil
        restoreRevision = nil
        defaults.set(position, forKey: positionKey)
        if let state = browser?.interactionState as? Data ?? capturedState { defaults.set(state, forKey: sessionKey) }
        if let url = readingURL(position["url"] as? String) {
            defaults.set(url.absoluteString, forKey: "feedResumeURL")
            defaults.set(position, forKey: "feedResumePosition")
        } else if (position["userRead"] as? Bool == true || !canResumeReading),
                  let anchors = position["anchors"] as? [[String: Any]],
                  let url = anchors.compactMap({ readingURL($0["url"] as? String) }).first {
            defaults.set(url.absoluteString, forKey: "feedResumeURL")
            defaults.removeObject(forKey: "feedResumePosition")
        }
        return true
    }

    private func readingURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), url.host == home.host,
              url.path.range(of: "/status/[0-9]+", options: .regularExpression) != nil else { return nil }
        return url
    }

    var canResumeReading: Bool { readingURL(defaults.string(forKey: "feedResumeURL")) != nil }

    func resumeReading() {
        guard let url = readingURL(defaults.string(forKey: "feedResumeURL")) else { return }
        focus()
        prepareNavigation()
        pendingRestore = defaults.dictionary(forKey: "feedResumePosition")
        restoreDestination = url.absoluteString
        beginDocumentNavigation()
        webView?.load(URLRequest(url: url))
    }

    private func checkpoint(suspend: Bool, completion: ((Bool) -> Void)? = nil) {
        guard let browser = webView, mode != "login", !hasPopup else { completion?(false); return }
        captureGeneration += 1
        let request = captureGeneration
        let generation = browserGeneration
        let navigation = navigationGeneration
        let state = browser.interactionState as? Data
        browser.evaluateJavaScript("window.__tfCheckpoint && window.__tfCheckpoint({suspend:\(suspend)})") { [weak self, browser] value, _ in
            guard let self, self.browserGeneration == generation, self.navigationGeneration == navigation,
                  self.captureGeneration == request,
                  let position = value as? [String: Any] else { completion?(false); return }
            if position["restoring"] as? Bool == true, let current = PageOwner(position), self.accept(current) {
                self.pendingRestore = position
                self.restoreDestination = current.url
                self.restoreRevision = nil
                completion?(false)
                return
            }
            if self.pendingRestore != nil, let current = PageOwner(position), self.accept(current) {
                completion?(true)
                return
            }
            let accepted = self.savePosition(position, browser: browser, capturedState: state)
            completion?(accepted)
        }
    }

    private func beginDocumentNavigation() {
        readyGeneration += 1
        captureGeneration += 1
        owner = nil
        committed = false
    }

    private func prepareNavigation() {
        initialLoadGeneration += 1
        captureGeneration += 1
        pendingRestore = nil
        restoreDestination = nil
        restoreRevision = nil
        cancelFit()
    }

    private func cancelFit() {
        resizeGeneration += 1
        if automaticResize {
            // Supersede the running frame animation while its delegate still
            // knows this is automatic, then permit ordinary user resizing.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                panel.animator().setFrame(panel.frame, display: true)
            }
        }
        automaticResize = false
    }

    override func popupDidClose() {
        mode = ""
    }

    override func reload() { reloadPreservingPosition(onlyIfThemeChanged: false) }

    private func reloadPreservingPosition(onlyIfThemeChanged: Bool) {
        guard let browser = webView else { return }
        initialLoadGeneration += 1
        let generation = initialLoadGeneration
        checkpoint(suspend: suspended) { [weak self, weak browser] accepted in
            guard let self, let browser, self.webView === browser,
                  self.initialLoadGeneration == generation,
                  accepted || self.owner == nil || self.defaults.dictionary(forKey: self.positionKey)?["url"] as? String == browser.url?.absoluteString else { return }
            self.syncNightMode { [weak self, weak browser] changed in
                guard let self, let browser, self.webView === browser,
                      self.initialLoadGeneration == generation else { return }
                guard !onlyIfThemeChanged || changed else { return }
                self.pendingRestore = self.defaults.dictionary(forKey: self.positionKey)
                self.restoreDestination = browser.url?.absoluteString
                self.captureGeneration += 1
                self.cancelFit()
                self.beginDocumentNavigation()
                if browser.url != nil { browser.reload() } else { self.loadInitialPage() }
            }
        }
    }

    override func menuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if mode == "detail" || mode == "page" {
            let back = NSMenuItem(title: "Back", action: #selector(menuBack), keyEquivalent: "")
            back.target = self
            items.append(back)
        }
        if canResumeReading {
            let resume = NSMenuItem(title: "Resume Reading", action: #selector(menuResume), keyEquivalent: "")
            resume.target = self
            items.append(resume)
        }
        return items
    }

    @objc private func menuBack() { goBack() }
    @objc private func menuResume() { resumeReading() }

    override func handle(message type: String, _ body: [String: Any]) {
        if type == "ready" { adoptDocument(); return }
        guard let next = PageOwner(body), accept(next) else { return }
        switch type {
        case "activity":
            if body["visible"] as? Bool == true, panel.isKeyWindow, NSApp.isActive, let browser = webView {
                suspended = true
                browserDidActivate(browser)
            }
        case "intent":
            let reason = body["reason"] as? String
            if reason == "restore" { restoreRevision = next.intentRevision }
            if reason == "input" || reason == "navigation" || reason == "resize" {
                restoreRevision = nil
                pendingRestore = nil
                restoreDestination = nil
                captureGeneration += 1
                initialLoadGeneration += 1
            }
        case "saveSession":
            guard let position = body["position"] as? [String: Any], PageOwner(position) == next,
                  !suspended || position["suspended"] as? Bool == true else { return }
            savePosition(position, browser: webView)
        case "fitPost":
            let geometryOnly = body["geometryOnly"] as? Bool == true
            guard (!suspended || geometryOnly), let browser = webView, mode == "timeline", !hasPopup, !isUserResizing,
                  let measured = body["height"] as? Double, measured.isFinite, measured >= 40,
                  let measuredWidth = body["width"] as? Double,
                  abs(measuredWidth - browser.bounds.width) < 2,
                  let serial = body["serial"] as? Int else { return }
            var acknowledgement = next.dictionary
            acknowledgement["serial"] = serial
            acknowledgement["geometryOnly"] = geometryOnly
            guard let envelope = json(acknowledgement) else { return }
            fitWindow(to: min(max(CGFloat(measured), 88), postHeightLimit), completion: { [weak self, weak browser] in
                guard let self, let browser, self.webView === browser, self.owner == next, !self.suspended || geometryOnly else { return }
                browser.evaluateJavaScript("window.__tfDidFit && window.__tfDidFit(\(envelope), \(Double(self.panel.frame.height)))", completionHandler: nil)
            })
        case "refreshHome":
            guard mode == "timeline", let browser = webView else { return }
            prepareNavigation()
            beginDocumentNavigation()
            // Remove the pair together; a departed document may not publish it
            // again while this deliberate fresh Home request is in flight.
            defaults.removeObject(forKey: positionKey)
            defaults.removeObject(forKey: sessionKey)
            browser.load(URLRequest(url: home, cachePolicy: .reloadIgnoringLocalCacheData))
        case "back": goBack()
        case "mode":
            if let nextMode = body["mode"] as? String { applyMode(nextMode) }
        default: break
        }
    }

    private func applyMode(_ next: String) {
        guard next != mode else { return }
        mode = next
        guard !hasPopup else { return }
        if next == "login" {
            fitWindow(to: min(700, screenFrame.height - 24), width: max(width, 460))
        } else if next == "detail" || next == "page" { fitWindow(to: height) }
    }

    /// Wheel fits follow settled scrolling. Keyboard fits start with the scroll.
    private func fitWindow(to height: CGFloat, width requestedWidth: CGFloat? = nil,
                           completion: (() -> Void)? = nil) {
        guard !isUserResizing else { return }
        resizeGeneration += 1
        let generation = resizeGeneration
        var frame = panel.frame
        let top = frame.maxY
        frame.size = NSSize(width: requestedWidth ?? width, height: height)
        frame.origin.y = top - height
        frame = clamped(frame)
        guard abs(frame.height - panel.frame.height) > 1 || abs(frame.width - panel.frame.width) > 1 else {
            automaticResize = false
            completion?()
            return
        }
        automaticResize = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || !panel.isVisible ? 0 : 0.2
            panel.animator().setFrame(frame, display: true)
        } completionHandler: { [weak self] in
            guard let self, self.resizeGeneration == generation else { return }
            self.automaticResize = false
            self.saveOrigin()
            completion?()
        }
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        guard !automaticResize || isUserResizing else { return }
        if isUserResizing { evaluate("window.__tfBeginResize && window.__tfBeginResize()") }
        let wasAutomatic = automaticResize
        resizeGeneration += 1
        automaticResize = false
        if isUserResizing && wasAutomatic {
            // Replace the running frame animation at its current frame so its
            // final value cannot overwrite the user's next resize sample.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                panel.animator().setFrame(panel.frame, display: true)
            }
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard !automaticResize else { return }
        evaluate("window.__tfRefit && window.__tfRefit()")
    }

    func windowDidResize(_ notification: Notification) {
        guard !automaticResize, mode != "login", !hasPopup else { return }
        width = panel.frame.width
        defaults.set(Double(width), forKey: "width")
        if mode != "timeline" {
            height = max(panel.frame.height, 320)
            defaults.set(Double(height), forKey: "feedHeight")
        }
        saveOrigin()
    }

    func windowDidMove(_ notification: Notification) {
        saveOrigin()
        if !automaticResize { evaluate("window.__tfPostHeightLimit = \(Double(postHeightLimit))") }
    }

    func signOut() {
        let alert = NSAlert()
        alert.messageText = "Sign out of X?"
        alert.informativeText = "YouTube Music stays signed in."
        alert.addButton(withTitle: "Sign Out")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        prepareNavigation()
        owner = nil
        defaults.removeObject(forKey: sessionKey)
        defaults.removeObject(forKey: positionKey)
        defaults.removeObject(forKey: "feedResumeURL")
        defaults.removeObject(forKey: "feedResumePosition")
        mode = "login"
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { records in
            // Only X's records. A full wipe would sign YouTube Music out too.
            let xRecords = records.filter { record in
                let name = record.displayName.lowercased()
                return name.contains("x.com") || name.contains("twitter")
            }
            store.removeData(ofTypes: types, for: xRecords) { [weak self] in
                DispatchQueue.main.async { self?.reload() }
            }
        }
    }
}
