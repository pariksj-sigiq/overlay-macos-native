//
//  SettingsTab.swift
//  OverlayOpus
//

import Carbon.HIToolbox
import SwiftUI

struct SettingsTab: View {
    @ObservedObject private var focusStore = FocusModeStore.shared
    @ObservedObject private var providerRegistry = ProviderRegistry.shared
    @ObservedObject private var whisperModels = WhisperModelManager.shared
    @AppStorage("overlay.answerMode") private var answerModeRaw = AnswerMode.concise.rawValue
    @AppStorage("overlay.answerTone") private var answerToneRaw = AnswerTone.direct.rawValue
    @AppStorage("overlay.privacyMode") private var privacyModeRaw = PrivacyMode.providerAssisted.rawValue
    @State private var privacyHealth = PrivacyHealthSnapshot.current()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Privacy Health") {
                    PrivacyHealthPanel(snapshot: privacyHealth) {
                        privacyHealth = PrivacyHealthSnapshot.current()
                    }
                }

                section("Intelligence") {
                    Picker("Answer mode", selection: $answerModeRaw) {
                        ForEach(AnswerMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode.rawValue)
                        }
                    }

                    Picker("Tone", selection: $answerToneRaw) {
                        ForEach(AnswerTone.allCases) { tone in
                            Text(tone.rawValue).tag(tone.rawValue)
                        }
                    }

                    Picker("Privacy", selection: $privacyModeRaw) {
                        ForEach(PrivacyMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode.rawValue)
                        }
                    }
                    .onChange(of: privacyModeRaw) { _, value in
                        CallSessionStore.shared.recordPrivacyModeChange(value)
                    }
                }

                section("Focus Mode") {
                    Picker("Mode", selection: $focusStore.mode) {
                        ForEach(FocusMode.allCases) { mode in
                            Label(mode.label, systemImage: mode.icon).tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)
                }

                section("Providers") {
                    ProviderEditorView()

                    if providerRegistry.configs.isEmpty {
                        Text("No providers saved yet.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(providerRegistry.configs) { config in
                            HStack {
                                Text(config.name)
                                    .font(.system(size: 12, weight: .medium))
                                Text(config.kind.label)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                Spacer()
                                Button(role: .destructive) {
                                    Task {
                                        try? await AppDatabase.shared.deleteProviderConfig(id: config.id)
                                        try? await providerRegistry.reload()
                                    }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }

                section("Speech") {
                    Picker("WhisperKit model", selection: $whisperModels.selectedModel) {
                        ForEach(WhisperModelManager.ModelChoice.allCases) { model in
                            Text(model.label).tag(model)
                        }
                    }

                    ProgressView(value: whisperModels.downloadProgress)
                    Button("Download Model") {
                        Task {
                            try? await whisperModels.downloadIfNeeded(whisperModels.selectedModel)
                        }
                    }
                    .disabled(whisperModels.isDownloading)

                    Text(whisperModels.isInstalled(whisperModels.selectedModel) ? "Model installed locally." : "Model downloads locally on first use.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    if let error = whisperModels.errorMessage {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    }
                }

                section("Hotkeys") {
                    hotkey("⌘⇧\\", "Show or hide overlay")
                    hotkey("⌘⇧=", "Increase notes font")
                    hotkey("⌘⇧-", "Decrease notes font")
                    hotkey("⌘⇧]", "Increase opacity")
                    hotkey("⌘⇧[", "Decrease opacity")
                    hotkey("⌘⇧L", "Cycle focus mode")
                    hotkey("⌘⇧M", "Toggle markdown")
                    hotkey("⌘⇧R", "Start or stop call recording")
                    hotkey("⌘⇧A", "Focus manual ask")
                    hotkey("⌘⇧Q", "Regenerate last suggestion")
                    hotkey("⌘⇧T", "Jump to Suggestions")
                    hotkey("⌘⇧B", "Jump to Brief")
                    hotkey("⌘⌥↑", "Scroll notes up")
                    hotkey("⌘⌥↓", "Scroll notes down")
                    hotkey("⌘⌥←", "Scroll notes left")
                    hotkey("⌘⌥→", "Scroll notes right")
                }

                section("Permissions") {
                    HStack {
                        Button("Open Privacy Settings") {
                            openPrivacySettings()
                        }
                        Text("Grant microphone and screen recording permissions when live capture is wired.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Text("Privacy hardening is always on; hardware/root-level capture cannot be blocked.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Text("Local notes and session data are encrypted at rest with a Keychain-held key.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
        }
        .task {
            try? await providerRegistry.reload()
            privacyHealth = PrivacyHealthSnapshot.current()
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.08)))
    }

    private func hotkey(_ keys: String, _ description: String) -> some View {
        HStack {
            Text(keys)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .frame(width: 54, alignment: .leading)
            Text(description)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct PrivacyHealthSnapshot {
    var items: [PrivacyHealthItem]

    static func current() -> PrivacyHealthSnapshot {
        PrivacyHealthSnapshot(items: [
            PrivacyHealthItem(level: .protected,
                              title: "Screen capture hiding",
                              detail: "`sharingType = .none` is enforced on the overlay window."),
            PrivacyHealthItem(level: .protected,
                              title: "Accessibility exposure",
                              detail: "Overlay, notes, and markdown views are hidden from standard AX traversal."),
            PrivacyHealthItem(level: IsSecureEventInputEnabled() ? .protected : .idle,
                              title: "Secure keyboard input",
                              detail: IsSecureEventInputEnabled()
                                ? "Secure Event Input is active now."
                                : "Turns on while the overlay is active/editable and turns off on hide/quit."),
            PrivacyHealthItem(level: LocalDataProtector.shared.hasStoredKey() ? .protected : .warning,
                              title: "Local encryption key",
                              detail: LocalDataProtector.shared.hasStoredKey()
                                ? "Keychain key is present for encrypted local data."
                                : "Keychain key has not been created yet."),
            PrivacyHealthItem(level: notesHealthLevel,
                              title: "Notes file",
                              detail: notesHealthDetail),
            PrivacyHealthItem(level: .protected,
                              title: "Session database",
                              detail: "Sensitive session fields encrypt on write and decrypt only in app memory."),
            PrivacyHealthItem(level: .warning,
                              title: "Exports",
                              detail: "Session exports are plaintext JSON in Downloads until export encryption is added."),
            PrivacyHealthItem(level: .warning,
                              title: "Clipboard",
                              detail: "Copy buttons use the global pasteboard; clipboard managers may retain copied text."),
            PrivacyHealthItem(level: distributionHealthLevel,
                              title: "Distribution signing",
                              detail: distributionHealthDetail)
        ])
    }

    private static var notesURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Overlay", isDirectory: true)
            .appendingPathComponent("notes.txt", isDirectory: false)
    }

    private static var notesHealthLevel: PrivacyHealthLevel {
        guard let data = try? Data(contentsOf: notesURL), !data.isEmpty else {
            return .idle
        }
        return data.starts(with: Data("enc:v1:".utf8)) ? .protected : .warning
    }

    private static var notesHealthDetail: String {
        switch notesHealthLevel {
        case .protected:
            return "Stored notes are encrypted at rest."
        case .idle:
            return "No local notes file yet."
        case .warning:
            return "Notes file is not encrypted yet; open/save notes to migrate it."
        }
    }

    private static var distributionHealthLevel: PrivacyHealthLevel {
        Bundle.main.bundlePath.contains("/Build/Products/") ? .warning : .idle
    }

    private static var distributionHealthDetail: String {
        if Bundle.main.bundlePath.contains("/Build/Products/") {
            return "Running a development build; product builds should be Developer ID signed and notarized."
        }
        return "Use a stable signed/notarized build to avoid repeated Keychain trust prompts."
    }
}

private struct PrivacyHealthItem: Identifiable {
    let id = UUID()
    var level: PrivacyHealthLevel
    var title: String
    var detail: String
}

private enum PrivacyHealthLevel {
    case protected
    case idle
    case warning

    var label: String {
        switch self {
        case .protected: return "Protected"
        case .idle: return "Idle"
        case .warning: return "Action"
        }
    }

    var systemImage: String {
        switch self {
        case .protected: return "checkmark.shield"
        case .idle: return "pause.circle"
        case .warning: return "exclamationmark.triangle"
        }
    }

    var color: Color {
        switch self {
        case .protected: return .green
        case .idle: return .secondary
        case .warning: return .orange
        }
    }
}

private struct PrivacyHealthPanel: View {
    var snapshot: PrivacyHealthSnapshot
    var refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(summary)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh privacy health")
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(snapshot.items) { item in
                    PrivacyHealthRow(item: item)
                }
            }
        }
    }

    private var summary: String {
        let protectedCount = snapshot.items.filter { $0.level == .protected }.count
        let actionCount = snapshot.items.filter { $0.level == .warning }.count
        return "\(protectedCount) protected, \(actionCount) need attention"
    }
}

private struct PrivacyHealthRow: View {
    var item: PrivacyHealthItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: item.level.systemImage)
                .foregroundStyle(item.level.color)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 12, weight: .medium))
                    Text(item.level.label)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(item.level.color)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(item.level.color.opacity(0.14)))
                }
                Text(item.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}
