//
//  RootTabView.swift
//  OverlayOpus
//

import AppKit
import SwiftUI

final class AppCommandStore: ObservableObject {
    static let shared = AppCommandStore()

    @Published var focusSuggestionPromptToken = UUID()
    @Published var selectedTab: OverlayTab = .notes

    private init() {}

    func focusSuggestionPrompt() {
        selectedTab = .suggestions
        focusSuggestionPromptToken = UUID()
    }
}

enum OverlayTab: String, CaseIterable, Identifiable {
    case notes
    case brief
    case live
    case suggestions
    case history
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notes: return "Notes"
        case .brief: return "Brief"
        case .live: return "Live"
        case .suggestions: return "Suggestions"
        case .history: return "History"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .notes: return "note.text"
        case .brief: return "doc.text.magnifyingglass"
        case .live: return "waveform"
        case .suggestions: return "sparkles"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}

struct RootTabView: View {
    @ObservedObject private var notesStore = NotesStore.shared
    @ObservedObject private var pinState = PinState.shared
    @ObservedObject private var focusStore = FocusModeStore.shared
    @ObservedObject private var commandStore = AppCommandStore.shared

    @AppStorage("overlay.selectedTab") private var selectedTabRaw: String = OverlayTab.notes.rawValue
    @AppStorage("overlay.opacity") private var opacity: Double = 0.85
    @AppStorage("overlay.fontSize") private var fontSize: Double = 14
    @AppStorage("overlay.markdownRender") private var markdownRender: Bool = false

    @State private var showingSettings = false

    private let minFontSize: Double = 10
    private let maxFontSize: Double = 28
    private let minOpacity: Double = 0.15
    private let maxOpacity: Double = 1.0

    private var selectedTab: Binding<OverlayTab> {
        Binding(
            get: { OverlayTab(rawValue: selectedTabRaw) ?? .notes },
            set: {
                selectedTabRaw = $0.rawValue
                commandStore.selectedTab = $0
            }
        )
    }

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
                tabStrip
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                Divider().opacity(0.25)
                transparencyBar
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                Divider().opacity(0.25)
                tabContent
                    .allowsHitTesting(bodyHitTestable)
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(modeBorderColor, lineWidth: modeBorderWidth)
        )
        .onReceive(commandStore.$selectedTab) { tab in
            if selectedTabRaw != tab.rawValue {
                selectedTabRaw = tab.rawValue
            }
        }
        .background(keyboardShortcuts)
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

            if selectedTab.wrappedValue == .notes {
                fontControls
                markdownButton
            }

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
            .help("Focus settings")
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

    private var tabStrip: some View {
        HStack(spacing: 4) {
            ForEach(OverlayTab.allCases) { tab in
                Button(action: { selectedTab.wrappedValue = tab }) {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 12, weight: .medium))
                        Text(tab.title)
                            .font(.system(size: 9, weight: .medium))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(selectedTab.wrappedValue == tab ? Color.accentColor : Color.secondary)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(selectedTab.wrappedValue == tab ? Color.accentColor.opacity(0.13) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .help(tab.title)
            }
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab.wrappedValue {
        case .notes:
            NotesTab(notesStore: notesStore)
        case .brief:
            BriefTab()
        case .live:
            LiveTab()
        case .suggestions:
            SuggestionsTab(commandStore: commandStore)
        case .history:
            HistoryTab()
        case .settings:
            SettingsTab()
        }
    }

    private var fontControls: some View {
        HStack(spacing: 2) {
            Button(action: decreaseFont) {
                Image(systemName: "textformat.size.smaller")
            }
            .buttonStyle(.borderless)
            .help("Decrease font")

            Text("\(Int(fontSize))")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 20)

            Button(action: increaseFont) {
                Image(systemName: "textformat.size.larger")
            }
            .buttonStyle(.borderless)
            .help("Increase font")
        }
    }

    private var markdownButton: some View {
        Button(action: { markdownRender.toggle() }) {
            Image(systemName: markdownRender ? "doc.richtext.fill" : "doc.plaintext")
                .foregroundStyle(markdownRender ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.borderless)
        .help(markdownRender ? "Switch to raw text" : "Render markdown")
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
        .background(Capsule().fill(modeBadgeColor.opacity(0.15)))
        .help(focusStore.mode.description)
    }

    private var modeBadgeColor: Color {
        switch focusStore.mode {
        case .interactive: return .secondary
        case .clickThroughAll: return .red
        case .clickThroughBody: return .orange
        case .neverFocus: return .yellow
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
    }

    private var keyboardShortcuts: some View {
        Group {
            Button(action: increaseFont) { EmptyView() }
                .keyboardShortcut("=", modifiers: [.command, .shift])
                .hidden()
            Button(action: decreaseFont) { EmptyView() }
                .keyboardShortcut("-", modifiers: [.command, .shift])
                .hidden()
            Button(action: { markdownRender.toggle() }) { EmptyView() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .hidden()
        }
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

#if DEBUG
#Preview {
    RootTabView()
        .frame(width: 720, height: 520)
}
#endif
