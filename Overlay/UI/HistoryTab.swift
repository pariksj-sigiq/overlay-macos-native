//
//  HistoryTab.swift
//  OverlayOpus
//

import SwiftUI

struct HistoryTab: View {
    @ObservedObject private var sessionStore = CallSessionStore.shared

    @State private var query = ""
    @State private var selectedResult: SearchHistoryResult?
    @State private var results: [SearchHistoryResult] = []
    @State private var reviewArtifacts: [SessionArtifactRecord] = []
    @State private var isGeneratingReview = false
    @State private var errorMessage: String?

    var body: some View {
        HSplitView {
            VStack(spacing: 10) {
                TextField("Search sessions", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await search() } }

                List(selection: $selectedResult) {
                    ForEach(results) { result in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.title)
                                .font(.system(size: 12, weight: .semibold))
                            Text(result.kind.rawValue)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        .tag(Optional(result))
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

                        Button {
                            Task { await generateReview() }
                        } label: {
                            Label(isGeneratingReview ? "Reviewing" : "Generate Review",
                                  systemImage: "doc.text.magnifyingglass")
                        }
                        .buttonStyle(.bordered)
                        .disabled(isGeneratingReview)
                    }
                    Divider().opacity(0.25)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
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
            Task { await loadReviewArtifacts() }
        }
    }

    private func search() async {
        do {
            results = try await AppDatabase.shared.searchHistory(query: query)
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
