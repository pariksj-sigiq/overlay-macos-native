import AppKit
import Carbon.HIToolbox
import Foundation

extension Notification.Name {
    /// Posted when the overlay font size changes via global hotkey.
    /// Observers can read the new value from `UserDefaults.standard.integer(forKey: "overlay.fontSize")`.
    static let overlayFontChanged = Notification.Name("overlayFontChanged")

    /// Posted when the overlay opacity changes via global hotkey.
    /// Observers can read the new value from `UserDefaults.standard.double(forKey: "overlay.opacity")`.
    static let overlayOpacityChanged = Notification.Name("overlayOpacityChanged")
}

/// Registers process-wide global hotkeys using the Carbon Event Manager.
///
/// Carbon's `RegisterEventHotKey` is used instead of `NSEvent.addGlobalMonitorForEvents`
/// because the Carbon API works while the app is in the background without requiring
/// the user to grant Accessibility permissions for modifier-based shortcuts.
final class HotkeyManager {

    // MARK: - Config keys / bounds

    /// UserDefaults key for the overlay font size (Int, pt).
    static let fontSizeKey = "overlay.fontSize"
    /// UserDefaults key for the overlay opacity (Double, 0...1).
    static let opacityKey = "overlay.opacity"

    static let minFontSize: Int = 10
    static let maxFontSize: Int = 28
    static let defaultFontSize: Int = 14

    static let minOpacity: Double = 0.3
    static let maxOpacity: Double = 1.0
    static let defaultOpacity: Double = 0.9
    static let opacityStep: Double = 0.05

    // MARK: - Hotkey identifiers

    /// Unique per-hotkey identifiers used as `EventHotKeyID.id`.
    private enum HotkeyID: UInt32 {
        case toggleVisibility = 1
        case fontSizeUp       = 2
        case fontSizeDown     = 3
        case opacityUp        = 4
        case opacityDown      = 5
        case cycleFocusMode   = 6
        case toggleMarkdown   = 7
        case toggleRecording  = 8
        case manualAsk        = 9
        case regenerate       = 10
        case jumpSuggestions  = 11
        case jumpBrief        = 12
    }

    /// Four-char code used as `EventHotKeyID.signature`. Carbon convention: a stable
    /// OSType value identifying the owning subsystem. We use 'OVRL' = Overlay.
    private static let signature: OSType = {
        let chars: [UInt8] = [0x4F, 0x56, 0x52, 0x4C] // "OVRL"
        return (OSType(chars[0]) << 24)
             | (OSType(chars[1]) << 16)
             | (OSType(chars[2]) <<  8)
             |  OSType(chars[3])
    }()

    // MARK: - Carbon state

    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var eventHandlerRef: EventHandlerRef?

    // MARK: - Callbacks

    private let toggleVisibility: () -> Void
    private let toggleRecording: () -> Void
    private let manualAsk: () -> Void
    private let regenerate: () -> Void
    private let jumpSuggestions: () -> Void
    private let jumpBrief: () -> Void

    // MARK: - Init / deinit

    /// - Parameter toggleVisibility: Invoked on the main thread when the user presses
    ///   the toggle-visibility hotkey (⌘⇧\).
    init(toggleVisibility: @escaping () -> Void,
         toggleRecording: @escaping () -> Void = {},
         manualAsk: @escaping () -> Void = {},
         regenerate: @escaping () -> Void = {},
         jumpSuggestions: @escaping () -> Void = {},
         jumpBrief: @escaping () -> Void = {}) {
        self.toggleVisibility = toggleVisibility
        self.toggleRecording = toggleRecording
        self.manualAsk = manualAsk
        self.regenerate = regenerate
        self.jumpSuggestions = jumpSuggestions
        self.jumpBrief = jumpBrief
        _ = FocusModeStore.shared  // prime singleton
        _ = NotesStore.shared
        seedDefaultsIfNeeded()
        installEventHandler()
        registerAllHotkeys()
    }

    deinit {
        for ref in hotKeyRefs {
            if let ref = ref {
                UnregisterEventHotKey(ref)
            }
        }
        hotKeyRefs.removeAll()

        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
    }

    // MARK: - Setup

    private func seedDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.fontSizeKey) == nil {
            defaults.set(Self.defaultFontSize, forKey: Self.fontSizeKey)
        }
        if defaults.object(forKey: Self.opacityKey) == nil {
            defaults.set(Self.defaultOpacity, forKey: Self.opacityKey)
        }
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind:  OSType(kEventHotKeyPressed)
        )

        // Pass `self` as user data (unretained — we own the handler lifetime via deinit).
        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        let handler: EventHandlerUPP = { _, eventRef, userData in
            guard let eventRef = eventRef, let userData = userData else {
                return OSStatus(eventNotHandledErr)
            }

            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                eventRef,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }

            let manager = Unmanaged<HotkeyManager>
                .fromOpaque(userData)
                .takeUnretainedValue()
            manager.handleHotkey(id: hotKeyID.id)
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            userData,
            &eventHandlerRef
        )
    }

    private func registerAllHotkeys() {
        let shiftCmd: UInt32 = UInt32(cmdKey | shiftKey)

        // ⌘⇧\  — toggle visibility
        register(keyCode: UInt32(kVK_ANSI_Backslash),   modifiers: shiftCmd, id: .toggleVisibility)
        // ⌘⇧=  — font size +1
        register(keyCode: UInt32(kVK_ANSI_Equal),       modifiers: shiftCmd, id: .fontSizeUp)
        // ⌘⇧-  — font size -1
        register(keyCode: UInt32(kVK_ANSI_Minus),       modifiers: shiftCmd, id: .fontSizeDown)
        // ⌘⇧]  — opacity +0.05
        register(keyCode: UInt32(kVK_ANSI_RightBracket), modifiers: shiftCmd, id: .opacityUp)
        // ⌘⇧[  — opacity -0.05
        register(keyCode: UInt32(kVK_ANSI_LeftBracket),  modifiers: shiftCmd, id: .opacityDown)
        // ⌘⇧L  — cycle focus mode (edit / locked / read / no-focus)
        register(keyCode: UInt32(kVK_ANSI_L),             modifiers: shiftCmd, id: .cycleFocusMode)
        // ⌘⇧M  — toggle markdown rendering
        register(keyCode: UInt32(kVK_ANSI_M),             modifiers: shiftCmd, id: .toggleMarkdown)
        // ⌘⇧R  — start/stop call recording
        register(keyCode: UInt32(kVK_ANSI_R),             modifiers: shiftCmd, id: .toggleRecording)
        // ⌘⇧A  — focus manual ask prompt
        register(keyCode: UInt32(kVK_ANSI_A),             modifiers: shiftCmd, id: .manualAsk)
        // ⌘⇧Q  — regenerate last suggestion
        register(keyCode: UInt32(kVK_ANSI_Q),             modifiers: shiftCmd, id: .regenerate)
        // ⌘⇧T  — jump to Suggestions tab
        register(keyCode: UInt32(kVK_ANSI_T),             modifiers: shiftCmd, id: .jumpSuggestions)
        // ⌘⇧B  — jump to Brief tab
        register(keyCode: UInt32(kVK_ANSI_B),             modifiers: shiftCmd, id: .jumpBrief)
    }

    private func register(keyCode: UInt32, modifiers: UInt32, id: HotkeyID) {
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id.rawValue)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr {
            hotKeyRefs.append(ref)
        } else {
            NSLog("HotkeyManager: RegisterEventHotKey failed for id=\(id.rawValue) status=\(status)")
        }
    }

    // MARK: - Dispatch

    private func handleHotkey(id: UInt32) {
        guard let hk = HotkeyID(rawValue: id) else { return }

        // Carbon delivers hotkey events on the main thread, but dispatch defensively
        // so callers can rely on main-thread UI state mutation.
        let work: () -> Void
        switch hk {
        case .toggleVisibility:
            work = { [weak self] in self?.toggleVisibility() }
        case .fontSizeUp:
            work = { [weak self] in self?.bumpFontSize(by: +1) }
        case .fontSizeDown:
            work = { [weak self] in self?.bumpFontSize(by: -1) }
        case .opacityUp:
            work = { [weak self] in self?.bumpOpacity(by: +Self.opacityStep) }
        case .opacityDown:
            work = { [weak self] in self?.bumpOpacity(by: -Self.opacityStep) }
        case .cycleFocusMode:
            work = { FocusModeStore.shared.cycle() }
        case .toggleMarkdown:
            work = {
                let defaults = UserDefaults.standard
                let current = defaults.bool(forKey: "overlay.markdownRender")
                defaults.set(!current, forKey: "overlay.markdownRender")
            }
        case .toggleRecording:
            work = { [weak self] in self?.toggleRecording() }
        case .manualAsk:
            work = { [weak self] in self?.manualAsk() }
        case .regenerate:
            work = { [weak self] in self?.regenerate() }
        case .jumpSuggestions:
            work = { [weak self] in self?.jumpSuggestions() }
        case .jumpBrief:
            work = { [weak self] in self?.jumpBrief() }
        }

        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    // MARK: - UserDefaults mutation

    private func bumpFontSize(by delta: Int) {
        let defaults = UserDefaults.standard
        let current = defaults.object(forKey: Self.fontSizeKey) as? Int ?? Self.defaultFontSize
        let next = min(Self.maxFontSize, max(Self.minFontSize, current + delta))
        guard next != current else { return }
        defaults.set(next, forKey: Self.fontSizeKey)
        NotificationCenter.default.post(name: .overlayFontChanged, object: next)
    }

    private func bumpOpacity(by delta: Double) {
        let defaults = UserDefaults.standard
        let current = (defaults.object(forKey: Self.opacityKey) as? Double) ?? Self.defaultOpacity
        let raw = current + delta
        let next = min(Self.maxOpacity, max(Self.minOpacity, raw))
        // Round to 2dp to avoid fp drift across many presses.
        let rounded = (next * 100).rounded() / 100
        guard rounded != current else { return }
        defaults.set(rounded, forKey: Self.opacityKey)
        NotificationCenter.default.post(name: .overlayOpacityChanged, object: rounded)
    }
}
