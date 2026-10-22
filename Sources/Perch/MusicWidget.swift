import AppKit
import WebKit

/// The YouTube Music widget. One window, two sizes:
/// - Mini: only YouTube Music's own player bar (album art, title, and its
///   own previous / play-pause / next).
/// - Full: the real YouTube Music page for searching and browsing.
/// YouTube's own player-page arrow switches window sizes. Art and title
/// also open the full player. No native controls cover the page.
final class MusicWidget: WidgetWindow {
    private(set) var expanded: Bool
    static let miniSize = NSSize(width: 420, height: 72)
    static let fullSize = NSSize(width: 560, height: 720)

    init(home: URL = URL(string: "https://music.youtube.com/")!,
         defaults: UserDefaults = .standard, dataStore: WKWebsiteDataStore = .default()) {
        expanded = defaults.object(forKey: "musicExpanded") as? Bool ?? false
        super.init(
            id: "music",
            title: "YouTube Music",
            home: home,
            prefix: "music",
            originKeys: (x: "musicX", y: "musicY"),
            script: MusicScript.source,
            focusBeforeInteraction: false,
            defaults: defaults, dataStore: dataStore
        )
    }

    override func browserDidCreate(_ browser: PerchWebView) {
        browser.allowsBackForwardNavigationGestures = true
    }

    override var initialSize: NSSize { expanded ? Self.fullSize : Self.miniSize }
    override var minimumHeight: CGFloat { expanded ? 360 : Self.miniSize.height }

    override func frameForUserResize(_ frame: NSRect) -> NSRect {
        if expanded {
            var full = frame
            full.size.width = max(340, frame.width)
            return clamped(full)
        }
        var mini = frame
        mini.size.width = min(560, max(340, frame.width))
        mini.size.height = Self.miniSize.height
        mini.origin.y = frame.maxY - mini.height
        return clamped(mini)
    }

    func setExpanded(_ on: Bool) {
        guard expanded != on else { return }
        expanded = on
        defaults.set(on, forKey: "musicExpanded")
        resize(to: on ? Self.fullSize : Self.miniSize, animate: false)
        applyMode()
        WidgetWindow.onChange?()
    }

    func toggleExpanded() { setExpanded(!expanded) }

    override func applyTheme() {
        super.applyTheme()
        applyMode()
    }

    private func applyMode() {
        evaluate("window.__musicTheme = '\(theme.rawValue)'; window.__musicMini = \(!expanded); window.__musicPaint && window.__musicPaint();")
    }

    override func goBack() {
        guard let browser = webView else { return }
        if browser.canGoBack {
            browser.goBack()
        } else {
            browser.load(URLRequest(url: home))
        }
    }

    override func menuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if expanded {
            let back = NSMenuItem(title: "Back", action: #selector(menuBack), keyEquivalent: "")
            back.target = self
            back.isEnabled = webView?.canGoBack == true
            items.append(back)
        }
        let size = NSMenuItem(title: expanded ? "Mini Player" : "Full Player", action: #selector(menuToggle), keyEquivalent: "")
        size.target = self
        items.append(size)
        return items
    }

    @objc private func menuBack() { goBack() }
    @objc private func menuToggle() { toggleExpanded() }

    override func popupDidClose() {
        resize(to: expanded ? Self.fullSize : Self.miniSize)
    }

    override func handle(message type: String, _ body: [String: Any]) {
        switch type {
        case "toggleSize": toggleExpanded()
        case "expand": setExpanded(true)
        case "collapse": setExpanded(false)
        default: break
        }
    }
}

enum MusicScript {
    static let source = #"""
    (() => {
      if (window.__musicframe) return;
      window.__musicframe = true;
      const post = window.__perchPost;

      // Clear surface tokens, not the black palette token. The full player's
      // Play glyph uses that token against its white button.
      const glassVars = [
        'html, ytmusic-app {',
        '  --ytmusic-brand-background-solid: transparent;',
        '  --ytmusic-general-background-a: transparent; --ytmusic-general-background-c: transparent;',
        '  --ytmusic-player-bar-background: transparent; --ytmusic-nav-bar-background: transparent;',
        '  --yt-spec-base-background: transparent; --yt-spec-raised-background: transparent;',
        '  --yt-spec-general-background-a: transparent;',
        '}',
        'html, body, ytmusic-app, ytmusic-app-layout, #layout, ytmusic-player-bar, #player-bar-background,',
        'ytmusic-browse-response, ytmusic-section-list-renderer, ytmusic-tab-renderer, ytmusic-search-page,',
        '#nav-bar-background, ytmusic-nav-bar, #guide-wrapper, #mini-guide-background, #guide-content, #mini-guide,',
        'ytmusic-player-page, #player-page, #tab-renderer, #background, .background-gradient {',
        '  background: transparent !important; background-color: transparent !important;',
        '}',
        '#nav-bar-divider, #guide-spacer, #nav-bar-background.opened { opacity: 0 !important; }'
      ].join('\n');
      // Keep the desktop bar at both widths. YouTube's mobile breakpoint
      // swaps in a second set of controls and leaves the desktop icon button
      // padding larger than its content box. Normalize the real buttons, not
      // their icons alone, so hover and click use the entire visible target.
      const bar = 'ytmusic-app-layout > ytmusic-player-bar';
      const barCSS = `
        ${bar} {
          position: fixed !important; left: 0 !important; right: 0 !important; bottom: 0 !important;
          top: auto !important; width: 100% !important; height: 72px !important; min-height: 72px !important;
          display: flex !important; flex-direction: row !important; align-items: center !important;
          padding: 0 8px 0 12px !important; box-sizing: border-box !important;
          transform: none !important; visibility: visible !important; border: 0 !important;
          --ytmusic-player-bar-height: 72px;
        }
        ytmusic-app-layout { --ytmusic-player-bar-height: 72px; }
        ${bar} > .middle-controls {
          order: 1 !important; flex: 1 1 0% !important; min-width: 0 !important; max-width: none !important;
          width: auto !important; height: 100% !important; margin: 0 !important; padding: 0 !important;
          display: flex !important; align-items: center !important; justify-content: flex-start !important;
        }
        ${bar} > #left-controls {
          order: 2 !important; display: flex !important; flex: 0 0 120px !important;
          width: 120px !important; height: 100% !important; margin: 0 0 0 6px !important; padding: 0 !important;
        }
        ${bar} .left-controls-buttons {
          position: relative !important; width: 120px !important;
          display: flex !important; align-items: center !important; gap: 0 !important; height: 100% !important;
        }
        ${bar} > #right-controls {
          order: 3 !important; display: flex !important; flex: 0 0 36px !important;
          width: 36px !important; min-width: 0 !important; height: 100% !important;
          margin: 0 0 0 2px !important; padding: 0 !important; align-items: center !important;
        }
        ${bar} > #right-controls-mweb, ${bar} .rewind-button, ${bar} .fast-forward-button,
        ${bar} .time-info, ${bar} .mweb-thumbnail-image-wrapper, ${bar} .middle-controls-buttons,
        ${bar} > #right-controls > :not(.toggle-player-page-button), ${bar} #hover-time-info {
          display: none !important;
        }
        ${bar} .left-controls-buttons > #play-pause-button,
        ${bar} .left-controls-buttons > yt-icon-button:not([hidden]),
        ${bar} .toggle-player-page-button {
          display: inline-flex !important; flex: 0 0 40px !important; align-items: center !important;
          justify-content: center !important; width: 40px !important; height: 40px !important;
          padding: 0 !important; margin: 0 !important; border: 0 !important;
          box-sizing: border-box !important; border-radius: 50% !important; transform: none !important;
        }
        ${bar} .toggle-player-page-button { flex-basis: 36px !important; width: 36px !important; }
        ${bar} yt-icon-button > button {
          display: flex !important; align-items: center !important; justify-content: center !important;
          width: 100% !important; height: 100% !important; padding: 0 !important; margin: 0 !important;
          border-radius: 50% !important; touch-action: manipulation;
        }
        ${bar} yt-icon-button > button > yt-icon {
          position: static !important; flex: 0 0 24px !important;
          width: 24px !important; height: 24px !important; margin: 0 !important; pointer-events: none;
        }
        ${bar} #play-pause-button > button > yt-icon {
          flex-basis: 32px !important; width: 32px !important; height: 32px !important;
        }
        ${bar} yt-icon-button > yt-interaction { pointer-events: none !important; }
        ${bar} yt-icon-button > button:hover { background-color: rgba(255,255,255,.12) !important; }
        ${bar} yt-icon-button > button:active { background-color: rgba(255,255,255,.2) !important; }
        /* YouTube hides the native button while its sibling spinner loads.
           Keep that button's slot so Next never slides into it. */
        ${bar} .left-controls-buttons > #play-pause-button[hidden] {
          visibility: hidden !important; pointer-events: none !important;
        }
        ${bar} .left-controls-buttons > .spinner-container {
          position: absolute !important; left: 40px !important; right: auto !important;
          top: 50% !important; bottom: auto !important; width: 40px !important; height: 40px !important;
          margin: 0 !important; padding: 0 !important; transform: translateY(-50%) !important;
          align-items: center !important; justify-content: center !important; pointer-events: none !important;
        }
        ${bar} .left-controls-buttons > .spinner-container:not([hidden]) { display: flex !important; }
        ${bar} .thumbnail-image-wrapper {
          display: block !important; flex: 0 0 48px !important; width: 48px !important; height: 48px !important;
          margin: 0 10px 0 0 !important;
        }
        ${bar} .thumbnail-image-wrapper img.image {
          display: block !important; width: 48px !important; height: 48px !important;
          border-radius: 8px !important; object-fit: cover !important;
        }
        ${bar} .content-info-wrapper { min-width: 0 !important; flex: 1 1 auto !important; }
        ${bar} .title, ${bar} .byline { max-width: 100% !important; }
        ${bar} #progress-bar {
          position: absolute !important; left: 18px !important; right: 18px !important; width: auto !important;
          top: auto !important; bottom: -13px !important; height: 31px !important; margin: 0 !important;
          padding: 0 !important; transform: none !important;
        }
        ${bar} #progress-bar #sliderContainer { margin: 0 !important; }
        ${bar} #progress-bar .bar-container {
          left: 0 !important; right: 0 !important; width: 100% !important; margin: 0 !important;
        }
        ${bar} .toggle-player-page-button yt-icon { transform: none !important; }
      `;
      const fullCSS = `
        ytmusic-app-layout[player-page-open] > ytmusic-player-bar { display: none !important; }
        ytmusic-player-controls yt-icon-button, ytmusic-player-page #collapse-button {
          padding: 0 !important;
          align-items: center !important; justify-content: center !important;
        }
        ytmusic-player-controls yt-icon-button > button, ytmusic-player-page #collapse-button > button {
          display: flex !important; align-items: center !important; justify-content: center !important;
          width: 100% !important; height: 100% !important; padding: 0 !important; margin: 0 !important;
          border-radius: 50% !important; touch-action: manipulation;
        }
        ytmusic-player-controls yt-icon-button > button > yt-icon { pointer-events: none; }
        ytmusic-player-controls #play-pause-button {
          width: 72px !important; height: 72px !important;
        }
        ytmusic-player-controls #play-pause-button > button > yt-icon {
          flex: 0 0 40px !important; width: 40px !important; height: 40px !important;
          margin: 0 !important;
        }
        ytmusic-player-page #collapse-button > button > yt-icon {
          width: 24px !important; height: 24px !important; pointer-events: none;
        }
      `;
      const miniCSS = `
        ytmusic-nav-bar, #nav-bar-background, #nav-bar-divider, #guide-wrapper, #mini-guide, #mini-guide-background,
        ytmusic-guide-renderer, #guide, #guide-spacer, #content, ytmusic-player-page, #player-page,
        #floating-player, ytmusic-mealbar-promo-renderer, #player-bar-background { display: none !important; }
        html, body { overflow: hidden !important; }
        ${bar} { height: 100vh !important; min-height: 0 !important; z-index: 10 !important; background: transparent !important; }
        ${bar} .toggle-player-page-button yt-icon { transform: rotate(180deg) !important; }
        ${bar} > .middle-controls { cursor: pointer !important; }
      `;

      // Full player on glass: the page scrolls under YouTube Music's own
      // header and player bar, so those two get a frosted backing.
      const glassBarsCSS = [
        'ytmusic-nav-bar, ' + bar + ' { background-color: rgba(20, 20, 24, 0.42) !important;',
        '  -webkit-backdrop-filter: blur(28px) saturate(1.5) !important; backdrop-filter: blur(28px) saturate(1.5) !important; }',
        'ytmusic-browse-response > #background, ytmusic-fullbleed-thumbnail-renderer.background { opacity: 0 !important; }'
      ].join('\n');

      const lightCSS = [
        // YouTube Music has no light theme. Invert the page and re-invert media
        // so art and video keep their real colours.
        'html { filter: invert(1) hue-rotate(180deg) !important; background: #000 !important; }',
        'img, video, canvas { filter: invert(1) hue-rotate(180deg) !important; }',
        // The wordmark is drawn for a dark page, so it inverts with the page.
        'ytmusic-logo img.logo { filter: none !important; }'
      ].join('\n');

      const paint = () => {
        const theme = window.__musicTheme || 'glass';
        const mini = window.__musicMini === true;
        let tag = document.getElementById('__music');
        if (!tag) {
          tag = document.createElement('style');
          tag.id = '__music';
          document.documentElement.appendChild(tag);
        }
        const css = [
          // Widgets scroll with the trackpad; YouTube's own 12px scrollbar
          // gutter would leave a strip beside the header and player bar.
          '::-webkit-scrollbar { width: 0 !important; height: 0 !important; }',
          'html { scrollbar-width: none !important; }',
          'ytmusic-nav-bar { width: 100% !important; left: 0 !important; right: 0 !important; }',
          barCSS
        ];
        if (theme === 'glass') css.push(glassVars);
        if (theme === 'glass' && !mini) css.push(glassBarsCSS);
        if (theme === 'light') css.push(lightCSS);
        css.push(mini ? miniCSS : fullCSS);
        // Dark and Light minis match the window (black, or white once inverted)
        // instead of YouTube's grey body colour.
        if (mini && theme !== 'glass') css.push('html, body { background-color: #000 !important; }');
        const text = css.join('\n');
        if (tag.textContent !== text) tag.textContent = text;
        configureControls();
      };
      // Only observe the bar, and only changes relevant to accessibility.
      // No whole-page scans or timer-driven restyling on the playback path.
      let observedBar = null;
      let observedPage = null;
      const updateAttribute = (node, name, value) => {
        if (node && node.getAttribute(name) !== value) node.setAttribute(name, value);
      };
      const configureControls = () => {
        const playerBar = observedBar?.isConnected ? observedBar : document.querySelector(bar);
        if (!playerBar) return;
        const playerPage = observedPage?.isConnected ? observedPage : document.querySelector('ytmusic-player-page');
        if (playerPage) {
          appObserver.disconnect();
          if (observedPage !== playerPage) {
            pageObserver.disconnect();
            observedPage = playerPage;
            pageObserver.observe(playerPage, { childList: true, subtree: true, attributes: true, attributeFilter: ['aria-label'] });
          }
          const collapse = playerPage.querySelector('#collapse-button');
          updateAttribute(collapse, 'title', 'Switch to mini player');
          updateAttribute(collapse?.querySelector('button'), 'aria-label', 'Switch to mini player');
        }
        if (observedBar !== playerBar) {
          barObserver.disconnect();
          observedBar = playerBar;
          barObserver.observe(playerBar, { subtree: true, childList: true, attributes: true, attributeFilter: ['title', 'aria-label'] });
        }
        const mini = window.__musicMini === true;
        const toggle = playerBar.querySelector('#right-controls .toggle-player-page-button');
        const label = mini ? 'Open full player' : 'Switch to mini player';
        updateAttribute(toggle, 'title', label);
        updateAttribute(toggle?.querySelector('button'), 'aria-label', label);
        const artwork = playerBar.querySelector('.thumbnail-image-wrapper');
        updateAttribute(artwork, 'title', mini ? 'Open full player' : 'Open now playing');
        updateAttribute(artwork, 'role', 'button');
        updateAttribute(artwork, 'tabindex', '0');
        updateAttribute(artwork, 'aria-label', mini ? 'Open full player' : 'Open now playing');
      };
      const barObserver = new MutationObserver(configureControls);
      const pageObserver = new MutationObserver(configureControls);
      const appObserver = new MutationObserver(() => configureControls());
      appObserver.observe(document.documentElement, { childList: true, subtree: true });
      window.__musicPaint = paint;
      paint();

      // Double-click an empty spot in the full player's header to shrink it
      // to the mini player, like double-clicking a title bar.
      document.addEventListener('dblclick', (event) => {
        if (window.__musicMini === true) return;
        const path = event.composedPath ? event.composedPath() : [event.target];
        if (!path.some((node) => node && node.matches && node.matches('ytmusic-nav-bar'))) return;
        for (const node of path) {
          if (node && node.matches && node.matches('a, button, input, textarea, select, [role="button"], [role="tab"], [role="slider"], [contenteditable="true"], yt-icon-button, ytmusic-search-box')) return;
        }
        event.preventDefault();
        post({ type: 'toggleSize' });
      }, true);

      const mainBarTarget = (event, selector) => {
        const path = event.composedPath ? event.composedPath() : [event.target];
        return path.find((node) => node?.matches?.(selector) && node.closest(bar));
      };
      document.addEventListener('click', (event) => {
        // Reuse YouTube's existing arrow, with one action in either size.
        // Stop its separate page-state toggle so size and page cannot diverge.
        const pageCollapse = event.target.closest?.('ytmusic-player-page #collapse-button');
        if (pageCollapse) {
          post({ type: 'collapse' });
          return; // Let YouTube return to browsing as the window shrinks.
        }
        if (mainBarTarget(event, '.toggle-player-page-button')) {
          event.preventDefault();
          event.stopImmediatePropagation();
          post({ type: 'toggleSize' });
          return;
        }
        if (window.__musicMini === true && mainBarTarget(event, '.middle-controls')) {
          post({ type: 'expand' });
        }
      }, true);
      document.addEventListener('contextmenu', (event) => {
        if (!mainBarTarget(event, 'ytmusic-player-bar')) return;
        event.preventDefault();
        event.stopImmediatePropagation();
        post({ type: 'contextMenu', x: event.clientX, y: event.clientY });
      }, true);
      document.addEventListener('keydown', (event) => {
        if (!['Enter', ' '].includes(event.key) || !mainBarTarget(event, '.thumbnail-image-wrapper')) return;
        event.preventDefault();
        event.target.click();
      });
    })();
    """#
}
