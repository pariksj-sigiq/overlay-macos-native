//
//  SuggestionsTab.swift
//  OverlayOpus
//

import SwiftUI

struct SuggestionsTab: View {
    @ObservedObject var commandStore: AppCommandStore
    @ObservedObject private var sessionStore = CallSessionStore.shared

    @FocusState private var promptFocused: Bool
    @State private var prompt = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 10) {
                    if sessionStore.suggestions.isEmpty {
                        Text("Suggestions will stream here when questions are detected or you ask manually.")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .padding(12)
                    }

                    ForEach(sessionStore.suggestions) { suggestion in
                        suggestionCard(suggestion)
                    }
                }
                .padding(12)
            }

            Divider().opacity(0.25)

            HStack(spacing: 8) {
                TextField("Ask for a suggestion...", text: $prompt)
                    .textFieldStyle(.roundedBorder)
                    .focused($promptFocused)
                    .onSubmit(sendPrompt)
                Button("Send", action: sendPrompt)
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
        }
        .onReceive(commandStore.$focusSuggestionPromptToken) { _ in
            promptFocused = true
        }
    }

    private func suggestionCard(_ suggestion: SuggestionUpdate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(Date(timeIntervalSince1970: TimeInterval(suggestion.ts) / 1000), style: .time)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text(suggestion.kind.rawValue)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.13)))
                if !suggestion.isFinal {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button(action: { copy(suggestion.text) }) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy")
                Button(action: sessionStore.regenerateLast) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Regenerate")
            }

            if let error = suggestion.errorMessage {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }

            Text(suggestion.text.isEmpty ? suggestion.prompt : suggestion.text)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.08)))
    }

    private func sendPrompt() {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sessionStore.manualAsk(trimmed)
        prompt = ""
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
