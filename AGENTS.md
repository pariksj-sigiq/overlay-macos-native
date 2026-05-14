# AGENTS.md — Overlay-Opus Handoff

Working dir: `/Users/pariksj/Desktop/overlay-opus/`
Built app: `/tmp/overlay-opus-build/Build/Products/Debug/OverlayOpus.app`
Project: `OverlayOpus.xcodeproj`
Scheme/target: `OverlayOpus`
Source dir: `Overlay/`

## What This Is

macOS SwiftUI/AppKit menu-bar app. The overlay window stays invisible to standard software capture while adding a scaffolded AI call assistant: brief/docs in, system audio capture in, local whisper path planned, question detection, provider-agnostic suggestions, and local SQLite history.

## Core Invisibility Rule

Do not remove or weaken this line in `OverlayWindow.swift`:

```swift
self.sharingType = .none
```

It is the product. It excludes the window from standard capture paths. It does not defeat cameras, hardware capture, or accessibility readers.

`SystemAudioCapturer` also uses `excludesCurrentProcessAudio = true`, and `AppDelegate` passes the overlay window id to the capturer.

## Target / Toolchain

- Swift 5.9
- SwiftUI + AppKit hybrid
- macOS 14.0+
- Bundle id `com.pariksj.overlay-opus`
- `LSUIElement = true`
- Sandbox off
- Hardened runtime on
- Ad-hoc codesign

## Modules

```text
Overlay/
├── AppDelegate.swift
├── OverlayWindow.swift
├── HotkeyManager.swift
├── StatusBarController.swift
├── NotesStore.swift
├── FocusMode.swift
├── Database/
│   ├── AppDatabase.swift
│   ├── Migrations.swift
│   └── Models.swift
├── Storage/
│   └── KeychainStore.swift
├── Providers/
│   ├── LLMProvider.swift
│   ├── ProviderRegistry.swift
│   ├── AzureOpenAIProvider.swift
│   ├── BedrockProvider.swift
│   ├── OllamaProvider.swift
│   ├── OpenAIProvider.swift
│   ├── SigV4.swift
│   └── SSEParser.swift
├── Audio/
│   ├── AudioRingBuffer.swift
│   └── SystemAudioCapturer.swift
├── Speech/
│   ├── WhisperEngine.swift
│   └── WhisperModelManager.swift
├── Intelligence/
│   ├── QuestionDetector.swift
│   ├── SuggestionEngine.swift
│   └── PromptBuilder.swift
├── Ingest/
│   ├── DocumentIngestor.swift
│   ├── DocxParser.swift
│   └── PdfParser.swift
├── Session/
│   └── CallSessionStore.swift
└── UI/
    ├── RootTabView.swift
    ├── NotesTab.swift
    ├── BriefTab.swift
    ├── LiveTab.swift
    ├── SuggestionsTab.swift
    ├── HistoryTab.swift
    ├── SettingsTab.swift
    ├── ProviderEditorView.swift
    └── DropZoneView.swift
```

## Ownership Map

- Window lifecycle/invisibility: `OverlayWindow.swift`, `AppDelegate.swift`
- Hotkeys/menu: `HotkeyManager.swift`, `StatusBarController.swift`
- Notes persistence: `NotesStore.swift`
- DB schema and records: `Database/*`
- Secrets: `Storage/KeychainStore.swift`
- LLM API layer: `Providers/*`
- ScreenCaptureKit audio: `Audio/*`
- Local STT path: `Speech/*`
- Questions/prompts/suggestions: `Intelligence/*`
- File extraction: `Ingest/*`
- Session orchestration: `Session/CallSessionStore.swift`
- App shell: `UI/*`

## DB Schema

`AppDatabase` opens:

`~/Library/Application Support/Overlay/db.sqlite`

Tables:

- `call_session`
- `context_doc`
- `transcript_chunk`
- `suggestion`
- `provider_config`
- `transcript_fts`
- `doc_fts`

FTS triggers are in `Migrations.swift`.

## Provider Notes

Provider configs live in SQLite; secrets live in Keychain service `OverlayOpus`.

Supported provider classes:

- `AzureOpenAIProvider`
- `BedrockProvider`
- `OllamaProvider`
- `OpenAIProvider`

No Anthropic SDK. Bedrock uses local SigV4 and currently has a minimal response-stream placeholder.

## Whisper Status

`WhisperModelManager` downloads ggml models locally. `WhisperEngine` is a compile-safe local scaffold. Xcode could not consume `https://github.com/ggerganov/whisper.cpp` as SPM because the repo did not expose a root `Package.swift` to the resolver. Next real implementation step is to vendor/build a whisper.cpp xcframework and wire C symbols into `WhisperEngine`.

Do not add cloud STT.

## Hotkeys

Registered in `HotkeyManager.swift` with `cmdKey | shiftKey`.

| Shortcut | Effect |
|---|---|
| `⌘⇧\` | show/hide overlay |
| `⌘⇧=` | font size up |
| `⌘⇧-` | font size down |
| `⌘⇧]` | opacity up |
| `⌘⇧[` | opacity down |
| `⌘⇧L` | cycle focus mode |
| `⌘⇧M` | toggle markdown |
| `⌘⇧R` | start/stop recording |
| `⌘⇧A` | focus Suggestions prompt |
| `⌘⇧Q` | regenerate last suggestion |
| `⌘⇧T` | jump to Suggestions |
| `⌘⇧B` | jump to Brief |

## UserDefaults Keys

| Key | Type | Purpose |
|---|---|---|
| `overlay.fontSize` | Double | notes font size |
| `overlay.opacity` | Double | HUD opacity |
| `overlay.frame` | `[String: CGFloat]` | persisted window frame |
| `overlay.focusMode` | String | focus/click-through mode |
| `overlay.markdownRender` | Bool | notes markdown render toggle |
| `overlay.selectedTab` | String | root tab selection |

## Build / Run

```bash
xcodebuild -project OverlayOpus.xcodeproj -scheme OverlayOpus \
  -configuration Debug -derivedDataPath /tmp/overlay-opus-build build

open /tmp/overlay-opus-build/Build/Products/Debug/OverlayOpus.app
pkill -f OverlayOpus
```

The user prompt mentioned a scheme named `Overlay`, but the actual project currently has only `OverlayOpus`.

## Gotchas

1. `sharingType = .none` can make visual screenshot-based smoke tests misleading because the overlay intentionally disappears from screenshots.
2. ScreenCaptureKit permission is Screen/System Audio Recording. The Info.plist key is not what drives the prompt.
3. Keep disk I/O off main where possible. `NotesStore` still uses its existing path and behavior.
4. Do not reintroduce `NotificationCenter` for new app data flow. Existing font/opacity notifications are legacy hotkey glue.
5. The root shell is `RootTabView`; `ContentView` remains for legacy/reference but `OverlayWindow` now hosts `RootTabView`.
6. GRDB and ZIPFoundation are Xcode SPM dependencies. whisper.cpp is not wired as SPM because upstream resolution failed.
