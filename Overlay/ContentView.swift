//
//  ContentView.swift
//  OverlayOpus
//

import SwiftUI
import AppKit

struct ContentView: View {

    @EnvironmentObject private var notesStore: NotesStore
    @ObservedObject private var pinState = PinState.shared
    @ObservedObject private var focusStore = FocusModeStore.shared

    @AppStorage("overlay.fontSize")        private var fontSize: Double = 14
    @AppStorage("overlay.opacity")         private var opacity: Double   = 0.85
    @AppStorage("overlay.markdownRender")  private var markdownRender: Bool = false

    @State private var showingSettings = false

    private let minFontSize: Double = 10
    private let maxFontSize: Double = 28
    private let minOpacity: Double  = 0.15
    private let maxOpacity: Double  = 1.0

    private var bodyHitTestable: Bool {
        focusStore.mode == FocusMode.interactive || focusStore.mode == FocusMode.neverFocus
    }

    var body: some View {
        ZStack(alignment: .top) {
            VisualEffectBackground(opacity: opacity)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                dragHandle
                toolbar
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                Divider().opacity(0.4)
                transparencyBar
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                Divider().opacity(0.25)
                Group {
                    if markdownRender {
                        MarkdownView(text: notesStore.text, fontSize: fontSize)
                    } else {
                        editor
                    }
                }
                .allowsHitTesting(bodyHitTestable)
            }
        }
        .frame(minWidth: 340, minHeight: 240)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(modeBorderColor, lineWidth: modeBorderWidth)
        )
        .background(
            Group {
                Button(action: increaseFont) { EmptyView() }
                    .keyboardShortcut("=", modifiers: [.command, .shift])
                    .hidden()
                Button(action: decreaseFont) { EmptyView() }
                    .keyboardShortcut("-", modifiers: [.command, .shift])
                    .hidden()
            }
        )
    }

    private var dragHandle: some View {
        Color.clear
            .frame(height: 22)
            .contentShape(Rectangle())
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("Overlay-Opus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)

            modeBadge

            Spacer()

            HStack(spacing: 2) {
                Button(action: decreaseFont) {
                    Image(systemName: "textformat.size.smaller")
                }
                .buttonStyle(.borderless)
                .help("Decrease font (⌘⇧-)")

                Text("\(Int(fontSize))")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 20)

                Button(action: increaseFont) {
                    Image(systemName: "textformat.size.larger")
                }
                .buttonStyle(.borderless)
                .help("Increase font (⌘⇧=)")
            }

            Button(action: { markdownRender.toggle() }) {
                Image(systemName: markdownRender ? "doc.richtext.fill" : "doc.plaintext")
                    .foregroundStyle(markdownRender ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(markdownRender ? "Switch to raw text (⌘⇧M)" : "Render markdown (⌘⇧M)")

            Button(action: togglePin) {
                Image(systemName: pinState.isPinned ? "pin.fill" : "pin")
                    .foregroundStyle(pinState.isPinned ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(pinState.isPinned ? "Unpin from top" : "Pin to top")

            Button(action: { showingSettings.toggle() }) {
                Image(systemName: "gearshape")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Settings (⌘⇧L cycles focus mode)")
            .popover(isPresented: $showingSettings, arrowEdge: .bottom) {
                SettingsPopover()
            }

            Button(action: closeWindow) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Close overlay")
        }
        .font(.system(size: 12))
    }

    private var modeBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: focusStore.mode.icon)
                .font(.system(size: 10))
            Text(focusStore.mode.shortLabel)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(modeBadgeColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(modeBadgeColor.opacity(0.15))
        )
        .help(focusStore.mode.description)
    }

    private var modeBadgeColor: Color {
        switch focusStore.mode {
        case .interactive:      return .secondary
        case .clickThroughAll:  return .red
        case .clickThroughBody: return .orange
        case .neverFocus:       return .yellow
        }
    }

    private var modeBorderColor: Color {
        focusStore.mode == FocusMode.interactive
            ? Color.white.opacity(0.08)
            : modeBadgeColor.opacity(0.45)
    }

    private var modeBorderWidth: CGFloat {
        focusStore.mode == FocusMode.interactive ? 0.5 : 1.5
    }

    private var transparencyBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.on.square.dashed")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("Transparency")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Slider(value: $opacity, in: minOpacity...maxOpacity)
                .controlSize(.small)
            Text("\(Int((1.0 - opacity) * 100))%")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
        .help("Lower = more see-through. ⌘⇧] / ⌘⇧[")
    }

    private var editor: some View {
        TextEditor(text: $notesStore.text)
            .font(.system(size: fontSize, weight: .regular, design: .monospaced))
            .foregroundColor(.primary)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 10)
    }

    private func increaseFont() {
        fontSize = min(maxFontSize, (fontSize + 1).rounded())
    }

    private func decreaseFont() {
        fontSize = max(minFontSize, (fontSize - 1).rounded())
    }

    private func togglePin() {
        pinState.isPinned.toggle()
    }

    private func closeWindow() {
        NotesStore.shared.flush()
        NSApp.keyWindow?.performClose(nil)
        if NSApp.keyWindow == nil {
            NSApp.mainWindow?.performClose(nil)
        }
    }
}

// MARK: - Settings popover

struct SettingsPopover: View {
    @ObservedObject private var focusStore = FocusModeStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Focus Mode")
                .font(.system(size: 12, weight: .semibold))
                .padding(.bottom, 2)

            ForEach(FocusMode.allCases) { mode in
                Button(action: { focusStore.mode = mode }) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: mode.icon)
                            .font(.system(size: 14))
                            .frame(width: 18)
                            .foregroundStyle(mode == focusStore.mode ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(mode.label)
                                    .font(.system(size: 12, weight: .medium))
                                if mode == focusStore.mode {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            Text(mode.description)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(mode == focusStore.mode
                                  ? Color.accentColor.opacity(0.12)
                                  : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Divider().padding(.vertical, 2)

            Text("Cycle with ⌘⇧L")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(width: 320)
    }
}

#if DEBUG
#Preview {
    ContentView()
        .environmentObject(NotesStore.shared)
        .frame(width: 420, height: 340)
}
#endif
