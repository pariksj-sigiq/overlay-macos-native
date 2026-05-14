//
//  AppDelegate.swift
//  Overlay
//
//  Owns the lifecycle of the overlay window, the global-hotkey manager and
//  the menu-bar (status bar) controller. The actual implementation of
//  `HotkeyManager` and `StatusBarController` lives in sibling files written
//  by other agents; this file only wires them together and holds strong
//  references for the app lifetime.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Owned objects

    /// The invisible-to-capture overlay window. Implementation in
    /// `OverlayWindow.swift`.
    var overlayWindow: OverlayWindow?

    /// Global hotkey dispatcher. Implementation lives in `HotkeyManager.swift`
    /// (owned by a sibling agent). Kept as a strong reference so Carbon event
    /// handlers stay alive for the app lifetime.
    var hotkeyManager: HotkeyManager?

    /// Menu-bar icon controller. Implementation lives in
    /// `StatusBarController.swift` (owned by a sibling agent).
    var statusBarController: StatusBarController?

    // MARK: - Combine

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // We are LSUIElement (no dock icon). Accessory activation policy gives
        // us menu-bar presence while still allowing the overlay window to
        // receive keyboard focus for the embedded TextEditor.
        NSApp.setActivationPolicy(.accessory)

        // 1. Build the overlay window.
        let window = OverlayWindow()
        self.overlayWindow = window
        CallSessionStore.shared.setExcludedWindowIDs([CGWindowID(window.windowNumber)])
        window.makeKeyAndOrderFront(nil)

        Task {
            try? await ProviderRegistry.shared.reload()
        }

        // 2. Global hotkeys (⌘⇧\ toggle, font size, opacity, etc.).
        //    HotkeyManager is implemented by another agent and requires a
        //    toggleVisibility closure in its initializer.
        self.hotkeyManager = HotkeyManager(
            toggleVisibility: { [weak self] in self?.toggleOverlayVisibility() },
            toggleRecording: { CallSessionStore.shared.toggleRecording() },
            manualAsk: { [weak self] in
                self?.showOverlay()
                AppCommandStore.shared.focusSuggestionPrompt()
            },
            regenerate: { CallSessionStore.shared.regenerateLast() },
            jumpSuggestions: { [weak self] in
                self?.showOverlay()
                AppCommandStore.shared.selectedTab = .suggestions
            },
            jumpBrief: { [weak self] in
                self?.showOverlay()
                AppCommandStore.shared.selectedTab = .brief
            }
        )

        // 3. Menu-bar icon (show/hide, pin, quit). Implemented by another
        //    agent; same toggle closure pattern as HotkeyManager.
        self.statusBarController = StatusBarController(
            toggleVisibility: { [weak self] in self?.toggleOverlayVisibility() },
            startStopCall: { CallSessionStore.shared.toggleRecording() }
        )

        // 4. Observe PinState changes from the menu / hotkey and reflect on
        //    the window level.
        PinState.shared.$isPinned
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pinned in
                self?.overlayWindow?.setPinned(pinned)
            }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        overlayWindow?.persistFrame()
        NotesStore.shared.flush()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Menu bar keeps us alive.
        return false
    }

    // MARK: - Visibility toggle

    /// Show / hide the overlay window. Called by both the global ⌘⇧\ hotkey
    /// and the menu-bar "Show/Hide Overlay" item.
    private func toggleOverlayVisibility() {
        guard let window = overlayWindow else { return }
        if window.isVisible {
            window.orderOut(nil)
        } else {
            showOverlay()
        }
    }

    private func showOverlay() {
        guard let window = overlayWindow else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
