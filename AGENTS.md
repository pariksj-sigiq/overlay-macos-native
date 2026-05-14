# AGENTS.md — Handoff for next agent

Working dir: `/Users/pariksj/Desktop/overlay-opus/`
Built app: `/Applications/OverlayOpus.app` + `/tmp/overlay-opus-build/Build/Products/Debug/OverlayOpus.app`
Source dir: `Overlay/` (kept this name inside pbxproj; product name is `OverlayOpus`)

## What this is

macOS SwiftUI menu-bar app. Translucent floating notes window **invisible to screen capture** (Zoom, Meet, Teams, QuickTime, OBS, ScreenCaptureKit, `screencapture`). User reads notes during meetings without viewers seeing them. Built from a sibling `overlay/` project via 4 parallel subagents, then branched to `overlay-opus/` with rename + feature additions.

## How invisibility works

Single flag: `NSWindow.sharingType = .none` in `OverlayWindow.swift:44`. Excludes window from `CGWindowList` and ScreenCaptureKit — every standard software capture path skips it. Physical display still shows it.

**Does NOT defeat:** phone camera at screen, HDMI hardware capture, a11y-based screen readers.

## Target / toolchain

- Swift 5.9, SwiftUI + AppKit, macOS 13+ deployment
- Xcode 15, `objectVersion = 56`, ad-hoc codesign, **no sandbox** (global hotkeys need non-sandbox)
- Bundle id `com.pariksj.overlay-opus`, display name `Overlay-Opus`, `LSUIElement = true` (menu bar only, no Dock)

## Project layout

```
overlay-opus/
├── OverlayOpus.xcodeproj/
│   ├── project.pbxproj                     # target = OverlayOpus, source dir path still "Overlay"
│   └── xcshareddata/xcschemes/OverlayOpus.xcscheme
├── Overlay/                                # source dir (kept Overlay/ to avoid pbxproj path edits)
│   ├── OverlayApp.swift                    # @main App, NSApplicationDelegateAdaptor, Settings scene only
│   ├── AppDelegate.swift                   # owns OverlayWindow + HotkeyManager + StatusBarController
│   ├── OverlayWindow.swift                 # NSWindow subclass. sharingType=.none, focus-mode application
│   ├── VisualEffectBackground.swift        # NSViewRepresentable, NSVisualEffectView .hudWindow
│   ├── ContentView.swift                   # toolbar + transparency bar + editor / markdown view
│   ├── HotkeyManager.swift                 # Carbon RegisterEventHotKey (no a11y permission needed)
│   ├── StatusBarController.swift           # NSStatusItem menu: Show/Hide, Pin, Quit
│   ├── NotesStore.swift                    # ObservableObject, debounced autosave
│   ├── PinState.swift                      # ObservableObject isPinned
│   ├── FocusMode.swift                     # 4-mode enum + FocusModeStore singleton
│   ├── MarkdownView.swift                  # line-by-line markdown renderer (no deps)
│   ├── AppIcon.icns                        # glass-card + eye-slash icon, 10 sizes
│   └── Info.plist                          # LSUIElement=true, CFBundleIconFile=AppIcon
├── build.sh                                # xcodebuild Release wrapper
├── README.md                               # user-facing docs
└── AGENTS.md                               # this file
```

## Singletons / cross-file API (DO NOT RENAME)

- `NotesStore.shared` — `@Published var text: String`, `func flush()`. Autosaves to `~/Library/Application Support/Overlay/notes.txt`, 0.5s debounce.
- `PinState.shared` — `@Published var isPinned: Bool`, `.toggle()`. Observed by `OverlayWindow` → sets `.level = .floating | .normal`.
- `FocusModeStore.shared` — `@Published var mode: FocusMode`, `.cycle()`. Persisted to `UserDefaults["overlay.focusMode"]`. Observed by `OverlayWindow` → applies `ignoresMouseEvents` + `canBecomeKey` gating.

## UserDefaults keys

| Key | Type | Default | Source of truth |
|---|---|---|---|
| `overlay.fontSize`       | Double | 14   | `@AppStorage` in ContentView, hotkeys bump via `UserDefaults` |
| `overlay.opacity`        | Double | 0.85 | `@AppStorage`, hotkeys bump |
| `overlay.frame`          | [String: CGFloat] dict (x/y/w/h) | centered | `OverlayWindow` auto-persists |
| `overlay.focusMode`      | String (FocusMode.rawValue) | `interactive` | `FocusModeStore` |
| `overlay.markdownRender` | Bool | false | `@AppStorage` in ContentView, toggled via ⌘⇧M |

## Hotkeys (Carbon, global, no a11y permission)

Registered in `HotkeyManager.swift:148-162`. Modifier = `cmdKey | shiftKey`.

| Shortcut | ID | Effect |
|---|---|---|
| ⌘⇧\ | toggleVisibility | show/hide via AppDelegate callback |
| ⌘⇧= | fontSizeUp       | bump `overlay.fontSize` (clamp 10–28) |
| ⌘⇧- | fontSizeDown     | decrement |
| ⌘⇧] | opacityUp        | bump `overlay.opacity` (clamp 0.3–1.0, step 0.05) |
| ⌘⇧[ | opacityDown      | decrement |
| ⌘⇧L | cycleFocusMode   | `FocusModeStore.shared.cycle()` |
| ⌘⇧M | toggleMarkdown   | flip `overlay.markdownRender` bool |

Notifications posted (for non-`@AppStorage` observers): `.overlayFontChanged`, `.overlayOpacityChanged`.

## Focus modes

`FocusMode` enum in `FocusMode.swift`:

| Case | Window behavior | Use case |
|---|---|---|
| `.interactive`      | normal — click, drag, type | editing notes before meeting |
| `.clickThroughAll`  | `ignoresMouseEvents = true`, `canBecomeKey = false` | full lockout during presentation |
| `.clickThroughBody` | SwiftUI `.allowsHitTesting(false)` on editor/markdown only, toolbar live | read with quick controls |
| `.neverFocus`       | clickable/draggable, `canBecomeKey = false` | drag allowed but typing goes to meeting app |

Applied in `OverlayWindow.applyFocusMode(_:)`. Visual: badge in toolbar (`ContentView.modeBadge`) shows icon+shortLabel; window border tints to `modeBorderColor` (red/orange/yellow/gray).

Settings popover: gear icon in toolbar opens `SettingsPopover` in `ContentView.swift` with radio-list of all 4 modes + descriptions.

## Markdown rendering

`MarkdownView.swift` — **no third-party deps**. Line-by-line block parser (`blocks` computed property) handles:
- ATX headings `#`..`######`
- Unordered list `- ` / `* ` / `+ ` with indent tracking
- Ordered list `\d+\. `
- Blockquote `> `
- Fenced code `` ``` ``
- HR `---` / `***` / `___`
- Blank line as spacer

Inline parsing delegated to `AttributedString(markdown:)` with `.inlineOnlyPreservingWhitespace` — gets bold/italic/code/links/strike for free.

Toggled by `overlay.markdownRender` bool. When `true`, `ContentView` shows `MarkdownView(text:fontSize:)` instead of `TextEditor`.

## Icon

`AppIcon.icns`. Generated by `/tmp/gen_icon.swift` via Core Graphics:
- Gradient indigo→teal squircle background
- Semi-translucent glass card with gloss band
- 4 white note lines (last one short)
- Bottom-right dark circle badge with eye + diagonal slash (hints at "invisible")

10 PNGs emitted to `/tmp/OverlayOpus.iconset/`, then `iconutil -c icns` → `.icns`. Wired via `CFBundleIconFile` + `CFBundleIconName = "AppIcon"` in Info.plist and PBXBuildFile/PBXFileReference entries in pbxproj.

**To regenerate:** `swift /tmp/gen_icon.swift && iconutil -c icns /tmp/OverlayOpus.iconset -o Overlay/AppIcon.icns`

## Build / run

```bash
# Xcode
open OverlayOpus.xcodeproj    # then ⌘R

# CLI
./build.sh                    # Release build
xcodebuild -project OverlayOpus.xcodeproj -scheme OverlayOpus \
  -configuration Debug -derivedDataPath /tmp/overlay-opus-build \
  clean build

# Install + launch
rm -rf /Applications/OverlayOpus.app
cp -R /tmp/overlay-opus-build/Build/Products/Debug/OverlayOpus.app /Applications/
open /Applications/OverlayOpus.app

# Kill
pkill -f OverlayOpus
```

After replacing in `/Applications`, Finder/Launchpad may show stale icon — `killall Finder` or `touch /Applications/OverlayOpus.app` + `lsregister -f`.

## Gotchas / lessons learned

1. **SourceKit phantom errors.** Editing Swift files without an indexed Xcode build produces dozens of "Cannot find type 'X' in scope" errors across files that actually DO see each other at build time. These are IDE-only noise. **Always verify with `xcodebuild`, not SourceKit diagnostics.** Build reliably succeeds with the phantom errors present.

2. **`.interactive` name collision.** macOS 26 SwiftUI added a `Glass.interactive` symbol. When `FocusMode.swift` isn't yet in the index, `.interactive` resolved to `Glass.interactive` and gave `"Member 'interactive' expects argument of type 'Glass'"`. **Fix:** use fully qualified `FocusMode.interactive` in comparisons (see `ContentView.swift:27,169,175`).

3. **Borderless window needs `canBecomeKey` override.** `NSWindow(styleMask: [.borderless])` refuses key/main status by default. Without `override var canBecomeKey: Bool { true }` the TextEditor never receives keystrokes. But — we conditionally return `false` for `.clickThroughAll` and `.neverFocus` modes so typing goes to the app below.

4. **Carbon user-data lifetime.** `InstallEventHandler` receives `UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())`. Cast back with `Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()`. Manager must outlive the handler — AppDelegate retains it for app lifetime.

5. **`isMovableByWindowBackground = true`** on the window means any empty drag space (the 22pt top strip in ContentView) lets user drag. Disable when `.clickThroughAll` is active.

6. **`scrollContentBackground(.hidden)`** on TextEditor is required for the HUD material to show through. macOS 13+ API, matches deployment target.

7. **LaunchServices caching.** After rebuild+reinstall, sometimes you need `lsregister -f -R -trusted /Applications/OverlayOpus.app` or `killall Finder` to pick up changes.

8. **Renaming the project.** `overlay-opus/` was copied from sibling `overlay/`. Renamed `Overlay.xcodeproj` → `OverlayOpus.xcodeproj`, target `Overlay` → `OverlayOpus`, scheme `Overlay.xcscheme` → `OverlayOpus.xcscheme`, bundle `com.pariksj.overlay` → `com.pariksj.overlay-opus`, `Overlay.app` → `OverlayOpus.app`, Info.plist `CFBundleDisplayName = "Overlay-Opus"`. **Kept source dir `Overlay/` as-is** — pbxproj `path = Overlay;` on the source group wasn't changed, avoiding cascading path edits. Any new Swift files should land in `Overlay/`.

9. **Build-dir drift.** The `cd` command doesn't persist between Bash tool calls; always use absolute paths for `xcodebuild -project` etc.

10. **`@main` + top-level code.** `OverlayApp.swift` can't contain any top-level statements if using `@main`. Keep it to struct-only.

## Known limitations

- App is unsigned (`Sign to Run Locally`, ad-hoc). First launch may require right-click → Open if downloaded, fine for local use.
- No customizable hotkey bindings yet — all fixed strings.
- Markdown renderer is custom; doesn't handle tables, footnotes, or nested code fences. Inline markdown (bold/italic/code/links) via `AttributedString` is the only thing we outsource.
- No iCloud sync, no multi-document. Single notes.txt.

## Good next steps (if user asks)

- **Tables** in MarkdownView (pipe-parse `| a | b |`).
- **Search** in notes (⌘F overlay with highlight).
- **Multiple notes** — tab/slash commands to switch files in `~/Library/Application Support/Overlay/`.
- **Custom hotkey rebinding** — swap Carbon constants for a preferences sheet.
- **Real code signing** if user wants to share the app.
- **Dock icon option** — flip `LSUIElement = false` behind a hidden flag so it can be toggled without a rebuild.
- **Restore focus mode on show** — currently toggling visibility doesn't re-apply focus mode; check if needed.
- **Accessibility polish** — the window title is "Overlay" (stale), update to "Overlay-Opus" for VoiceOver.

## Test meet-invisibility

```
# Start QuickTime screen recording preview:
open -a "QuickTime Player"   # File → New Screen Recording
# or Meet share-screen preview in browser.
# OverlayOpus window must NOT appear in the capture.
```

## Files the user has touched by name

- Prompt for codex (initial scaffolding request) — not in repo
- `overlay/` — original build from 4 parallel agents
- `overlay-opus/` — this project, branched + renamed + focus-mode + markdown + custom icon
