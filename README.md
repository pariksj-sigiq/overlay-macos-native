# Overlay-Opus — Invisible Meeting Notes

Translucent always-on-top macOS window for meeting notes. Screen share cannot see it.

## How it works

Sets `NSWindow.sharingType = .none`. Window excluded from `CGWindowList` + ScreenCaptureKit. Zoom, Google Meet, Microsoft Teams, QuickTime, `screencapture`, OBS all skip it. Still visible on physical display.

## Caveat

**Does NOT defeat:** phone camera at screen, hardware HDMI capture, accessibility-based screen readers.

**Defeats:** all standard software capture paths (Zoom, Meet, Teams, QuickTime, OBS, `screencapture`, any ScreenCaptureKit client).

## Build

Open `OverlayOpus.xcodeproj` in Xcode, press ⌘R. Or CLI:

```
./build.sh
```

## Hotkeys

| Shortcut | Action |
|---|---|
| ⌘⇧\ | Toggle overlay |
| ⌘⇧= / ⌘⇧- | Font size |
| ⌘⇧] / ⌘⇧[ | Opacity |

## UI controls

- **Transparency slider** in header. 0% = fully visible, higher % = more see-through.
- Font size stepper, pin toggle, close button in top toolbar.

## Menu bar

Icon with show/hide, pin, quit.

## First run

App is `LSUIElement` — no dock icon. Find it in menu bar.

## Permissions

None. Carbon hotkeys do not require Accessibility. No sandbox.

## Files

Notes autosave to `~/Library/Application Support/Overlay/notes.txt`.

## Test it works

Start QuickTime screen recording or Zoom/Meet share preview. Overlay does not appear in capture.
