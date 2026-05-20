//
//  SettingsTab.swift
//  OverlayOpus
//

import SwiftUI

struct SettingsTab: View {
    @ObservedObject private var focusStore = FocusModeStore.shared
    @ObservedObject private var providerRegistry = ProviderRegistry.shared
    @ObservedObject private var whisperModels = WhisperModelManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
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
                }
            }
            .padding(14)
        }
        .task {
            try? await providerRegistry.reload()
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
