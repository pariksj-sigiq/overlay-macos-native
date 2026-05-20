//
//  BriefTab.swift
//  OverlayOpus
//

import SwiftUI

struct BriefTab: View {
    @ObservedObject private var providerRegistry = ProviderRegistry.shared
    @ObservedObject private var sessionStore = CallSessionStore.shared

    @State private var title = ""
    @State private var hasScheduledDate = false
    @State private var scheduledDate = Date()
    @State private var brief = ""
    @State private var documentURLs: [URL] = []
    @State private var providerID = ""
    @State private var modelID = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                TextField("Call title", text: $title)
                    .textFieldStyle(.roundedBorder)

                Toggle("Scheduled", isOn: $hasScheduledDate)
                    .toggleStyle(.checkbox)

                if hasScheduledDate {
                    DatePicker("Date", selection: $scheduledDate)
                        .datePickerStyle(.compact)
                }

                TextEditor(text: $brief)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.08)))

                DropZoneView { urls in
                    let accepted = urls.filter(isAcceptedDocument)
                    documentURLs.append(contentsOf: accepted)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Documents")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)

                    if documentURLs.isEmpty {
                        Text("Drop PDFs, DOCX, Markdown, or text files to attach them to this call.")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(Array(documentURLs.enumerated()), id: \.offset) { _, url in
                            HStack {
                                Image(systemName: "doc.text")
                                    .foregroundStyle(.secondary)
                                Text(url.lastPathComponent)
                                    .lineLimit(1)
                                Spacer()
                                Text(url.pathExtension.uppercased())
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                            .font(.system(size: 12))
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
                        }
                    }
                }

                HStack {
                    Picker("Provider", selection: $providerID) {
                        Text("Provider").tag("")
                        ForEach(providerRegistry.providers, id: \.id) { provider in
                            Text(provider.displayName).tag(provider.id)
                        }
                    }
                    .frame(maxWidth: 220)

                    TextField("Model", text: $modelID)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)

                    Spacer()
                    Button {
                        sessionStore.generatePrep()
                    } label: {
                        Label("Generate Prep", systemImage: "sparkles")
                    }
                    .buttonStyle(.bordered)
                    .disabled(sessionStore.activeSession == nil)

                    Button {
                        sessionStore.startCall(title: title,
                                               brief: brief,
                                               providerID: providerID,
                                               modelID: modelID,
                                               documents: documentURLs)
                    } label: {
                        Label("Start Call", systemImage: "phone.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              providerID.isEmpty ||
                              modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if !sessionStore.prepArtifacts.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Prep")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)

                        ForEach(sessionStore.prepArtifacts) { artifact in
                            artifactCard(artifact)
                        }
                    }
                }
            }
            .padding(14)
        }
        .task {
            try? await providerRegistry.reload()
            if providerID.isEmpty {
                providerID = providerRegistry.providers.first?.id ?? ""
            }
        }
    }

    private func isAcceptedDocument(_ url: URL) -> Bool {
        ["pdf", "docx", "md", "txt"].contains(url.pathExtension.lowercased())
    }

    private func artifactCard(_ artifact: SessionArtifactRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(artifact.title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(Date(timeIntervalSince1970: TimeInterval(artifact.ts) / 1000).formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Text(artifact.content)
                .font(.system(size: 12))
                .textSelection(.enabled)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.08)))
    }
}
