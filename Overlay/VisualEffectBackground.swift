//
//  VisualEffectBackground.swift
//  Overlay
//
//  A SwiftUI wrapper around `NSVisualEffectView` that gives the overlay its
//  frosted-HUD look. Drop it behind your content with `.background(...)`
//  or as a `ZStack` layer.
//

import SwiftUI
import AppKit

struct VisualEffectBackground: NSViewRepresentable {

    // MARK: - Inputs

    /// Overall opacity applied via `alphaValue`. `1.0` = full blur,
    /// `0.0` = invisible. Controlled by the user via hotkeys.
    var opacity: Double = 1.0

    /// Allow callers to override material / blending if they want, but the
    /// defaults match the spec: HUD material, active, behind-window blend.
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active

    // MARK: - NSViewRepresentable

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.isEmphasized = false
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        view.layer?.masksToBounds = true
        view.alphaValue = CGFloat(opacity)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        if nsView.material != material { nsView.material = material }
        if nsView.blendingMode != blendingMode { nsView.blendingMode = blendingMode }
        if nsView.state != state { nsView.state = state }
        let target = CGFloat(max(0.0, min(1.0, opacity)))
        if nsView.alphaValue != target { nsView.alphaValue = target }
    }
}
