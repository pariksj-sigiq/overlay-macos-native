//
//  OverlayApp.swift
//  Overlay
//
//  SwiftUI app entry point.
//  The window is created manually by `AppDelegate` (see `AppDelegate.swift`)
//  so we don't declare a `WindowGroup` here. A `Settings` scene is provided
//  purely to satisfy the `App` protocol — it stays empty.
//

import SwiftUI

@main
struct OverlayApp: App {

    // Bridge AppKit lifecycle: AppDelegate owns the OverlayWindow,
    // the HotkeyManager and the StatusBarController.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No default window — OverlayWindow is built in code.
        // A Settings scene keeps SwiftUI's scene requirements happy while
        // exposing nothing visible by default (the user never opens it).
        Settings {
            EmptyView()
        }
    }
}
