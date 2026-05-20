//
//  HistoryTab.swift
//  OverlayOpus
//

import AppKit
import SwiftUI

struct HistoryTab: View {
    @ObservedObject private var sessionStore = CallSessionStore.shared

    @State private var query = ""
    @State private var selectedResult: SearchHistoryResult?
    @State private var results: [SearchHistoryResult] = []
    @State private var reviewArtifacts: [SessionArtifactRecord] = []
    @State private var isGeneratingReview = false
    @State private var isExporting = false
    @State private var confirmingDelete = false
    @State private var exportedURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        HSplitView {
            VStack(spacing: 10) {
                TextField("Search sessions", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await search() } }

                List {
                    ForEach(results) { result in
                        Button {
                            selectedResult = result
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(result.title)
                                    .font(.system(size: 12, weight: .semibold))
                                Text(result.kind.rawValue)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(selectedResult?.sessionID == result.sessionID ? Color.accentColor.opacity(0.16) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 210)
            .padding(12)

            VStack(alignment: .leading, spacing: 10) {
                if let selectedResult {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(selectedResult.title)
                                .font(.system(size: 16, weight: .semibold))
                            Text(Date(timeIntervalSince1970: TimeInterval(selectedResult.createdAt)).formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        HStack(spacing: 8) {
                            Button {
                                Task { await generateReview() }
                            } label: {
                                Label(isGeneratingReview ? "Reviewing" : "Generate Review",
                                      systemImage: "doc.text.magnifyingglass")
                            }
                            .buttonStyle(.bordered)
                            .disabled(isGeneratingReview)

                            Button {
                                Task { await exportSelected() }
                            } label: {
                                Label(isExporting ? "Exporting" : "Export",
                                      systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.bordered)
                            .disabled(isExporting)

                            Button(role: .destructive) {
                                confirmingDelete = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    Divider().opacity(0.25)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if let exportedURL {
                                Text("Exported to \(exportedURL.lastPathComponent)")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }

                            Text(selectedResult.snippet)
                                .font(.system(size: 13))
                                .textSelection(.enabled)

                            if !reviewArtifacts.isEmpty {
                                Text("Reviews")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)

                                ForEach(reviewArtifacts) { artifact in
                                    artifactCard(artifact)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Spacer()
                } else if let errorMessage {
                    Spacer()
                    Text(errorMessage)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    Spacer()
                    Text("Search or select a session")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                    Spacer()
                }
            }
            .padding(14)
            .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task {
            await search()
        }
        .onChange(of: selectedResult) { _, _ in
            exportedURL = nil
            Task { await loadReviewArtifacts() }
        }
        .confirmationDialog("Delete this session permanently?",
                            isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete Session", role: .destructive) {
                Task { await deleteSelected() }
            }
        }
    }

    private func search() async {
        do {
            results = try await AppDatabase.shared.searchHistory(query: query)
            if selectedResult == nil || !results.contains(where: { $0.id == selectedResult?.id }) {
                selectedResult = results.first
                await loadReviewArtifacts()
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func exportSelected() async {
        guard let selectedResult else { return }
        isExporting = true
        defer { isExporting = false }

        do {
            let url = try await SessionExportService().export(sessionID: selectedResult.sessionID)
            exportedURL = url
            NSWorkspace.shared.activateFileViewerSelecting([url])
            _ = try? await AppDatabase.shared.insertPrivacyAudit(
                PrivacyAuditRecord(id: UUID().uuidString,
                                   sessionID: selectedResult.sessionID,
                                   ts: Date.unixMilliseconds,
                                   action: "session_exported",
                                   detail: url.path)
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteSelected() async {
        guard let selectedResult else { return }
        let sessionID = selectedResult.sessionID

        do {
            _ = try? await AppDatabase.shared.insertPrivacyAudit(
                PrivacyAuditRecord(id: UUID().uuidString,
                                   sessionID: nil,
                                   ts: Date.unixMilliseconds,
                                   action: "session_deleted",
                                   detail: sessionID)
            )
            try await AppDatabase.shared.deleteSession(id: sessionID)
            results.removeAll { $0.sessionID == sessionID }
            reviewArtifacts = []
            exportedURL = nil
            self.selectedResult = nil
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadReviewArtifacts() async {
        guard let selectedResult else {
            reviewArtifacts = []
            return
        }

        do {
            reviewArtifacts = try await sessionStore.reviewArtifacts(for: selectedResult.sessionID)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func generateReview() async {
        guard let selectedResult else { return }
        isGeneratingReview = true
        defer { isGeneratingReview = false }

        do {
            let artifact = try await sessionStore.makeReviewArtifact(for: selectedResult.sessionID)
            reviewArtifacts.insert(artifact, at: 0)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
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
