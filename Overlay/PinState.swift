//
//  PinState.swift
//  Overlay
//
//  Shared pinned-state flag. When true, the overlay window sits above
//  other windows (handled by OverlayWindow in a sibling file).
//  The hotkey manager and the UI both mutate / observe this singleton.
//

import Foundation
import Combine

final class PinState: ObservableObject {

    // MARK: - Singleton

    static let shared = PinState()

    // MARK: - Published state

    /// `true` means the overlay window should float above other windows.
    /// Defaults to `true` so the overlay behaves like a HUD on first launch.
    @Published var isPinned: Bool = true

    // MARK: - Init

    private init() {}

    // MARK: - Helpers

    /// Convenience for hotkey handlers that want a simple toggle entry point.
    func toggle() {
        isPinned.toggle()
    }
}
