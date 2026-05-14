//
//  FocusMode.swift
//  OverlayOpus
//
//  Read-mode behavior for presentations. Controls how the overlay
//  interacts (or doesn't) with mouse + keyboard focus.
//

import Foundation
import Combine

enum FocusMode: String, CaseIterable, Identifiable {
    /// Full interactive: click, drag, type. Default when editing.
    case interactive
    /// Entire window click-through. Cannot drag/click/edit. Pure read.
    case clickThroughAll
    /// Body (text) click-through, toolbar still clickable for controls.
    case clickThroughBody
    /// Clickable + draggable, but window never steals key focus.
    /// Typing always goes to the app below.
    case neverFocus

    var id: String { rawValue }

    var label: String {
        switch self {
        case .interactive:      return "Interactive"
        case .clickThroughAll:  return "Click-through (full)"
        case .clickThroughBody: return "Click-through (body only)"
        case .neverFocus:       return "No focus steal"
        }
    }

    var shortLabel: String {
        switch self {
        case .interactive:      return "Edit"
        case .clickThroughAll:  return "Locked"
        case .clickThroughBody: return "Read"
        case .neverFocus:       return "No-focus"
        }
    }

    var description: String {
        switch self {
        case .interactive:
            return "Normal. Click, drag, type. Takes keyboard focus."
        case .clickThroughAll:
            return "Mouse passes through entire window. Cannot drag or click. Presentation-safe."
        case .clickThroughBody:
            return "Text area passes mouse through. Toolbar stays usable for quick adjustments."
        case .neverFocus:
            return "Clickable + draggable, but never steals keyboard focus. Typing goes to app below."
        }
    }

    var icon: String {
        switch self {
        case .interactive:      return "pencil.circle"
        case .clickThroughAll:  return "lock.circle.fill"
        case .clickThroughBody: return "eye.circle.fill"
        case .neverFocus:       return "keyboard.chevron.compact.down"
        }
    }
}

final class FocusModeStore: ObservableObject {
    static let shared = FocusModeStore()

    @Published var mode: FocusMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.key)
        }
    }

    private static let key = "overlay.focusMode"

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.key) ?? ""
        self.mode = FocusMode(rawValue: raw) ?? .interactive
    }

    func cycle() {
        let all = FocusMode.allCases
        if let idx = all.firstIndex(of: mode) {
            mode = all[(idx + 1) % all.count]
        }
    }
}
