<p align="center">
  <img src="Assets/AppIcon.png" width="128" alt="Perch icon">
</p>

<h1 align="center">Perch</h1>

<p align="center">
  Small, cropped web apps that float on your Mac desktop.<br>
  Ships with <b>X</b> and <b>YouTube Music</b>, and is built so more sites can be added.
</p>

<p align="center">
  <a href="docs/perch-x.mp4"><img src="docs/perch-x.gif" width="720" alt="Perch's X widget: pressing Down moves one post at a time while the window resizes to fit each post"></a>
</p>

<p align="center">
  <a href="docs/perch-music.mp4"><img src="docs/perch-music.gif" width="720" alt="Perch's YouTube Music widget: skipping songs in the mini player, expanding to the full app and collapsing back"></a>
</p>

## What it does

Perch keeps the part of a site you actually use in a small floating window. It uses the real site, signed in with your own account. Each widget is cropped to its useful part and given a light handle above it for moving and resizing.

**X**
- Crops the timeline down to the posts: no sidebars, tabs, composer or "new posts" banners.
- Up and Down move one post at a time. The window resizes to fit each post as you go.
- Scrolling with the mouse or trackpad snaps to the nearest post when you stop.
- Enter opens comments, Left goes back, and double-tapping Up refreshes to the newest post.
- Remembers where you were reading, across restarts.

**YouTube Music**
- A 420 × 72 mini player using YouTube Music's own artwork, title and Previous / Play / Next controls.
- The site's arrow expands it into the full browsing page and collapses it again.

**Every widget**
- Glass, Dark or Light appearance. Glass can be clear or frosted.
- Keep in Front, so it floats above other windows.
- A menu bar icon to focus, enable or configure each widget. ⌘1 focuses X and ⌘2 focuses Music.
- Turning a widget off closes its page and stops playback. Your sign-in and settings are kept for next time.

## Install

1. Download `Perch-<version>.dmg` from the [Releases](../../releases) page.
2. Open it and drag **Perch** into **Applications**.
3. The first time you open it, macOS will warn that it can't verify the developer, because the app isn't notarized. Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**. You only need to do this once.

Requires macOS 26 on Apple silicon.

## Build from source

You need the Xcode command line tools (`xcode-select --install`).

```sh
./build.sh      # builds Perch.app in this folder
./package.sh    # builds a release and wraps it in dist/Perch-<version>.dmg
```

`package.sh` makes an ad-hoc signed DMG by default. If you have an Apple Developer account, it can sign with your Developer ID and notarize the DMG so it opens without a warning on other Macs:

```sh
xcrun notarytool store-credentials perch-notary \
  --apple-id you@example.com --team-id TEAMID --password <app-specific-password>

SIGN_ID="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE=perch-notary ./package.sh
```

## Adding a widget

Perch is meant to be a base for more widgets. X and YouTube Music are just the first two. Everything they share lives in the base layer: the floating window, the handle, appearance, the settings window, the menu bar, shortcuts, and keeping you signed in. A new site only supplies its URL, a crop script, and its size.

A minimal widget is one subclass:

```swift
import AppKit

final class ExampleWidget: WidgetWindow {
    init() {
        super.init(
            id: "example", title: "Example",
            home: URL(string: "https://example.com/")!,
            prefix: "example", originKeys: (x: "exampleX", y: "exampleY"),
            script: "document.documentElement.style.overflowX = 'clip';"
        )
    }

    override var initialSize: NSSize { NSSize(width: 420, height: 500) }
    override var minimumHeight: CGFloat { 180 }
}
```

Then one entry in the registration list in `Sources/Perch/AppMain.swift`:

```swift
WidgetRegistration(
    widget: ExampleWidget(), icon: WidgetIcon.system("globe"),
    help: "Browse Example using its own page controls.", shortcut: "3"
)
```

That registration is all it takes for the widget to appear in settings, the menu bar and the shortcuts. Sites that need more can override the browser lifecycle hooks (`browserDidCreate`, `browserWillClose`, `browserDidActivate`, and so on), handle messages from their page script, or set their own resize rules. `XWidget.swift` and `MusicWidget.swift` are complete examples.

## Project layout

| Path | What's there |
| --- | --- |
| `Sources/Perch/WidgetWindow.swift` | The shared floating window and web view: lifetime, appearance, placement, saved state, first-click handling, and the page ↔ app message bridge |
| `Sources/Perch/WidgetChrome.swift` | The handle above each widget: moving, resizing, and the hover border |
| `Sources/Perch/WidgetRegistration.swift` | Widget metadata: settings, actions, shortcuts, and icons |
| `Sources/Perch/WidgetDesk.swift` | The settings window, main menu, and menu bar menu |
| `Sources/Perch/AppMain.swift` | App startup and the list of registered widgets |
| `Sources/Perch/XWidget.swift`, `CropScript.swift` | X: crop, post snapping, keyboard navigation, window fitting, and resume reading |
| `Sources/Perch/MusicWidget.swift` | YouTube Music: crop, mini and full modes |
| `Sources/Perch/PerchGlyph.swift`, `scripts/make-icon.swift` | The logo, drawn in code for both the app icon and the menu bar |
| `scripts/`, `tests/` | Verification harnesses. The X suites (`scripts/verify-x*.py`) run against local fixtures in hidden windows and never take focus |

## Notes

Perch is an independent project, not affiliated with X Corp. or Google. It loads the real sites in WebKit with your own sign-in and doesn't collect or send any data of its own.

## License

[MIT](LICENSE)
