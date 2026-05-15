//
//  SettingsTab.swift
//  OverlayOpus
//

import SwiftUI

struct SettingsTab: View {
    @ObservedObject private var focusStore = FocusModeStore.shared
    @ObservedObject private var providerRegistry = ProviderRegistry.shared
    @ObservedObject private var whisperModels = WhisperModelManager.shared

    @State private var whisperModel = WhisperModelManager.ModelChoice.baseEN
    @State private var editingConfig: ProviderConfigRecord?
    @State private var providerMessage: String?

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
                    if !providerRegistry.configs.isEmpty {
                        Picker("Active", selection: activeProviderBinding) {
                            ForEach(providerRegistry.configs) { config in
                                Text(config.name).tag(Optional(config.id))
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    HStack {
                        Spacer()
                        Button {
                            editingConfig = nil
                        } label: {
                            Label("New", systemImage: "plus")
                        }
                        .disabled(editingConfig == nil)
                    }

                    ProviderEditorView(editingConfig: editingConfig) { saved in
                        editingConfig = saved
                    }

                    if providerRegistry.configs.isEmpty {
                        Text("No providers saved yet.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(providerRegistry.configs) { config in
                            HStack {
                                if providerRegistry.activeProviderID == config.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                                Text(config.name)
                                    .font(.system(size: 12, weight: .medium))
                                Text(config.kind.label)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                if let model = ProviderRegistry.defaultModelID(for: config) {
                                    Text(model)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Button {
                                    editingConfig = config
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .buttonStyle(.borderless)
                                .help("Edit provider")
                                Button(role: .destructive) {
                                    Task {
                                        await deleteProvider(config)
                                    }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }

                    if let providerMessage {
                        Text(providerMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                section("Speech") {
                    Picker("Whisper model", selection: $whisperModel) {
                        ForEach(WhisperModelManager.ModelChoice.allCases) { model in
                            Text(model.rawValue).tag(model)
                        }
                    }

                    ProgressView(value: whisperModels.downloadProgress)
                    Button("Download Model") {
                        Task {
                            try? await whisperModels.downloadIfNeeded(whisperModel)
                        }
                    }
                    .disabled(whisperModels.isDownloading)
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
                        Text("Grant Screen Recording when prompted so macOS allows system-audio capture.")
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

    private var activeProviderBinding: Binding<String?> {
        Binding(
            get: { providerRegistry.activeProviderID },
            set: { providerRegistry.setActiveProviderID($0) }
        )
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

    @MainActor
    private func deleteProvider(_ config: ProviderConfigRecord) async {
        do {
            try await providerRegistry.deleteProviderConfig(id: config.id)
            if editingConfig?.id == config.id {
                editingConfig = nil
            }
            providerMessage = "Deleted \(config.name)"
        } catch {
            providerMessage = error.localizedDescription
        }
    }
}
