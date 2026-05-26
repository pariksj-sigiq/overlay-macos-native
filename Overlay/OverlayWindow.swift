//
//  OverlayWindow.swift
//  Overlay
//
//  The invisible-to-capture window.
//
//  Key trick:
//    `sharingType = .none`
//  excludes the window from `CGWindowList` and ScreenCaptureKit, so Zoom,
//  Google Meet, QuickTime, `screencapture`, OBS, etc. never see it. The
//  pixels are still rendered to your physical display.
//
//  Additional HUD niceties: translucent, borderless, draggable anywhere on
//  the background, appears on all Spaces, survives full-screen transitions.
//

import AppKit
import SwiftUI
import Combine
import Carbon.HIToolbox

final class OverlayWindow: NSWindow {

    private var focusModeCancellable: AnyCancellable?
    private var currentFocusMode: FocusMode = .interactive

    // MARK: - Persisted frame

    private static let frameDefaultsKey = "overlay.frame"

    private static let defaultSize = NSSize(width: 420, height: 320)

    // MARK: - Init

    init() {
        let initialFrame = OverlayWindow.loadPersistedFrame()
            ?? OverlayWindow.defaultCenteredFrame()

        super.init(
            contentRect: initialFrame,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        // --- The core invisibility flag ---------------------------------
        // `.none` removes the window from all standard software capture
        // paths (CGWindowList + ScreenCaptureKit).
        self.sharingType = .none
        // ----------------------------------------------------------------

        // Floating by default (toggled via `setPinned(_:)`).
        self.level = .floating

        // Follow the user across Spaces and into full-screen apps.
        self.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary
        ]

        // Translucent chrome.
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true

        // Draggable from anywhere on the blurred background.
        self.isMovableByWindowBackground = true

        // Don't steal focus by default — users read, occasionally type.
        self.hidesOnDeactivate = false
        self.isReleasedWhenClosed = false

        // Accept keyboard events when clicked (for TextEditor editing).
        self.acceptsMouseMovedEvents = true

        // Title shows up nowhere (borderless) but keeps AX tooling happy.
        self.title = "Overlay"

        // Restore an SwiftUI hosted root.
        installHostingView()

        // Persist frame whenever it changes.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFrameChange),
            name: NSWindow.didMoveNotification,
            object: self
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFrameChange),
            name: NSWindow.didResizeNotification,
            object: self
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePrivacyStateChange),
            name: NSApplication.didBecomeActiveNotification,
            object: NSApp
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePrivacyStateChange),
            name: NSApplication.didResignActiveNotification,
            object: NSApp
        )

        // Apply + observe focus mode.
        focusModeCancellable = FocusModeStore.shared.$mode
            .receive(on: RunLoop.main)
            .sink { [weak self] mode in
                self?.applyFocusMode(mode)
            }

        applyPrivacyHardening()
        updateSecureInputState()
    }

    deinit {
        DispatchQueue.main.async { @MainActor in
            SecureInputManager.shared.disable()
        }
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - NSWindow overrides

    // Borderless windows refuse key/main status by default. We need them for
    // the embedded TextEditor to receive keystrokes — unless the user has
    // opted into a non-focus mode for presentations.
    override var canBecomeKey: Bool {
        switch currentFocusMode {
        case .interactive, .clickThroughBody: return true
        case .clickThroughAll, .neverFocus:   return false
        }
    }
    override var canBecomeMain: Bool { canBecomeKey }

    // Accessory apps don't auto-activate on window click. Force activation
    // + key status so TextEditor receives keystrokes.
    override func mouseDown(with event: NSEvent) {
        if canBecomeKey {
            NSApp.activate(ignoringOtherApps: true)
            if !isKeyWindow { makeKey() }
        }
        super.mouseDown(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, canBecomeKey, !isKeyWindow {
            NSApp.activate(ignoringOtherApps: true)
            makeKey()
        }
        if event.type == .keyDown, handleNotesScrollShortcut(event) {
            return
        }
        super.sendEvent(event)
    }

    override func becomeKey() {
        super.becomeKey()
        applyPrivacyHardening()
        updateSecureInputState()
    }

    override func resignKey() {
        super.resignKey()
        updateSecureInputState()
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        applyPrivacyHardening()
        updateSecureInputState()
    }

    override func orderOut(_ sender: Any?) {
        SecureInputManager.shared.disable()
        super.orderOut(sender)
    }

    override func close() {
        SecureInputManager.shared.disable()
        super.close()
    }

    private func handleNotesScrollShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), flags.contains(.option) else { return false }
        guard !flags.contains(.control), !flags.contains(.shift) else { return false }

        switch Int(event.keyCode) {
        case kVK_UpArrow:
            AppCommandStore.shared.scrollNotes(.up)
        case kVK_DownArrow:
            AppCommandStore.shared.scrollNotes(.down)
        case kVK_LeftArrow:
            AppCommandStore.shared.scrollNotes(.left)
        case kVK_RightArrow:
            AppCommandStore.shared.scrollNotes(.right)
        default:
            return false
        }
        return true
    }

    // MARK: - Focus mode

    private func applyFocusMode(_ mode: FocusMode) {
        currentFocusMode = mode
        switch mode {
        case .interactive:
            self.ignoresMouseEvents = false
            self.isMovableByWindowBackground = true
        case .clickThroughAll:
            self.ignoresMouseEvents = true
            self.isMovableByWindowBackground = false
            if isKeyWindow { resignKey() }
        case .clickThroughBody:
            // Per-view hit-testing handled by SwiftUI (.allowsHitTesting).
            self.ignoresMouseEvents = false
            self.isMovableByWindowBackground = true
        case .neverFocus:
            self.ignoresMouseEvents = false
            self.isMovableByWindowBackground = true
            if isKeyWindow { resignKey() }
        }
        updateSecureInputState()
    }

    // MARK: - Hosting

    private func installHostingView() {
        let root = RootTabView()
            .environmentObject(NotesStore.shared)
            .environmentObject(PinState.shared)

        let hosting = HardenedHostingView(rootView: root)
        hosting.translatesAutoresizingMaskIntoConstraints = false

        // A container view lets the visual-effect background sit underneath
        // the SwiftUI hosting view even though SwiftUI already composites
        // its own translucent background.
        let container = NSView(frame: self.contentRect(forFrameRect: self.frame))
        container.autoresizingMask = [.width, .height]
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true

        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        self.contentView = container
        applyPrivacyHardening()
    }

    private func applyPrivacyHardening() {
        PrivacyHardeningController.shared.apply(to: self)
    }

    func refreshPrivacyHardeningState() {
        applyPrivacyHardening()
        updateSecureInputState()
    }

    @objc private func handlePrivacyStateChange() {
        refreshPrivacyHardeningState()
    }

    private func updateSecureInputState() {
        let shouldEnable = isVisible && isKeyWindow && NSApp.isActive && currentFocusMode == .interactive
        SecureInputManager.shared.setEnabled(shouldEnable)
    }

    // MARK: - Public control

    /// Toggle the always-on-top behaviour. When unpinned the window sits at
    /// `.normal` level so other apps can cover it.
    func setPinned(_ pinned: Bool) {
        self.level = pinned ? .floating : .normal
    }

    /// Public flush hook used by `AppDelegate` at app-termination time.
    func persistFrame() {
        saveFrame()
    }

    // MARK: - Frame persistence

    @objc private func handleFrameChange() {
        saveFrame()
    }

    private func saveFrame() {
        let f = self.frame
        let dict: [String: CGFloat] = [
            "x": f.origin.x,
            "y": f.origin.y,
            "w": f.size.width,
            "h": f.size.height
        ]
        UserDefaults.standard.set(dict, forKey: OverlayWindow.frameDefaultsKey)
    }

    private static func loadPersistedFrame() -> NSRect? {
        guard let dict = UserDefaults.standard.dictionary(
                forKey: frameDefaultsKey) as? [String: CGFloat],
              let x = dict["x"], let y = dict["y"],
              let w = dict["w"], let h = dict["h"],
              w > 100, h > 80 else {
            return nil
        }
        let rect = NSRect(x: x, y: y, width: w, height: h)
        // Verify the saved rect still intersects a live screen, otherwise
        // fall back to the centered default (monitor may have been removed).
        let visible = NSScreen.screens.contains { $0.frame.intersects(rect) }
        return visible ? rect : nil
    }

    private static func defaultCenteredFrame() -> NSRect {
        let screen = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = defaultSize
        let origin = NSPoint(
            x: screen.midX - size.width / 2,
            y: screen.midY - size.height / 2
        )
        return NSRect(origin: origin, size: size)
    }
}

@MainActor
final class PrivacyHardeningController {
    static let shared = PrivacyHardeningController()

    private init() {}

    func apply(to window: NSWindow) {
        window.setAccessibilityElement(false)
        window.setAccessibilityHidden(true)
        window.setAccessibilityLabel("")
        window.setAccessibilityValue(nil)
        window.setAccessibilityHelp("")
        window.setAccessibilityChildren([])

        if let contentView = window.contentView {
            apply(to: contentView)
        }
    }

    func apply(to view: NSView) {
        view.setAccessibilityElement(false)
        view.setAccessibilityHidden(true)
        view.setAccessibilityLabel("")
        view.setAccessibilityValue(nil)
        view.setAccessibilityHelp("")
        view.setAccessibilityChildren([])
        view.subviews.forEach { apply(to: $0) }
    }
}

@MainActor
final class SecureInputManager {
    static let shared = SecureInputManager()

    private var enabledByOverlay = false

    private init() {}

    func setEnabled(_ enabled: Bool) {
        enabled ? enable() : disable()
    }

    func enable() {
        guard !enabledByOverlay else { return }
        EnableSecureEventInput()
        enabledByOverlay = true
    }

    func disable() {
        guard enabledByOverlay else { return }
        DisableSecureEventInput()
        enabledByOverlay = false
    }
}

@MainActor
final class HardenedHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        PrivacyHardeningController.shared.apply(to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        PrivacyHardeningController.shared.apply(to: self)
    }

    override func layout() {
        super.layout()
        PrivacyHardeningController.shared.apply(to: self)
    }

    override func accessibilityChildren() -> [Any]? {
        []
    }

    override func accessibilityLabel() -> String? {
        ""
    }

    override func accessibilityValue() -> Any? {
        nil
    }
}
