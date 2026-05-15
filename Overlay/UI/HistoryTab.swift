//
//  HistoryTab.swift
//  OverlayOpus
//

import SwiftUI

struct HistoryTab: View {
    @State private var query = ""
    @State private var selectedResultID: String?
    @State private var results: [SearchHistoryResult] = []
    @State private var detail: HistorySessionDetail?
    @State private var errorMessage: String?
    @State private var isSearching = false
    @State private var isLoadingDetail = false

    var body: some View {
        HSplitView {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    TextField("Search sessions", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await search(selectFirst: true) } }

                    Button {
                        Task { await search(selectFirst: true) }
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .help("Search")
                }

                if isSearching {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                }

                List {
                    ForEach(results) { result in
                        Button {
                            select(result)
                        } label: {
                            resultRow(result)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(selectedResultID == result.id ? Color.accentColor.opacity(0.18) : Color.clear)
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 230)
            .padding(12)

            detailPane
                .padding(14)
                .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task {
            await search(selectFirst: true)
        }
    }

    private func resultRow(_ result: SearchHistoryResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: result.kind.iconName)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(result.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }

            Text(result.kind.label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)

            if !result.snippet.isEmpty {
                Text(cleanSnippet(result.snippet))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var detailPane: some View {
        if isLoadingDetail {
            VStack {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if let detail {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    sessionHeader(detail.session)
                    Divider().opacity(0.25)
                    detailSection(title: "Brief") {
                        Text(detail.session.brief.isEmpty ? "No brief saved." : detail.session.brief)
                            .font(.system(size: 13))
                            .textSelection(.enabled)
                    }
                    detailSection(title: "Documents") {
                        if detail.documents.isEmpty {
                            emptyText("No documents ingested for this session.")
                        } else {
                            ForEach(detail.documents) { document in
                                documentDetail(document)
                            }
                        }
                    }
                    detailSection(title: "Transcript") {
                        if detail.transcript.isEmpty {
                            emptyText("No transcript chunks saved.")
                        } else {
                            ForEach(detail.transcript) { chunk in
                                transcriptDetail(chunk)
                            }
                        }
                    }
                    detailSection(title: "Suggestions") {
                        if detail.suggestions.isEmpty {
                            emptyText("No suggestions saved.")
                        } else {
                            ForEach(detail.suggestions) { suggestion in
                                suggestionDetail(suggestion)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else if let errorMessage {
            VStack {
                Spacer()
                Text(errorMessage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
        } else {
            VStack {
                Spacer()
                Text(results.isEmpty ? "No sessions found" : "Select a session")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
        }
    }

    private func sessionHeader(_ session: CallSessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.title)
                .font(.system(size: 17, weight: .semibold))
                .textSelection(.enabled)

            HStack(spacing: 10) {
                Label(session.status.rawValue.capitalized, systemImage: "record.circle")
                Label(formatSeconds(session.createdAt), systemImage: "calendar")
                if let scheduledAt = session.scheduledAt {
                    Label("Scheduled \(formatSeconds(scheduledAt))", systemImage: "clock")
                }
                if let endedAt = session.endedAt {
                    Label("Ended \(formatSeconds(endedAt))", systemImage: "stop.circle")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            if let providerID = session.providerID, let modelID = session.modelID {
                Text("\(providerID) / \(modelID)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
    }

    private func detailSection<Content: View>(title: String,
                                              @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func documentDetail(_ document: ContextDocRecord) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(document.filename ?? document.kind.rawValue.uppercased(), systemImage: "doc.text")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(formatSeconds(document.addedAt))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Text(document.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                 ? document.summary ?? ""
                 : excerpt(document.content, limit: 600))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 5)
    }

    private func transcriptDetail(_ chunk: TranscriptChunkRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(chunk.speaker.rawValue.capitalized)
                    .font(.system(size: 11, weight: .semibold))
                Text(formatMilliseconds(chunk.ts))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Text(chunk.text)
                .font(.system(size: 12))
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }

    private func suggestionDetail(_ suggestion: SuggestionRecord) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Label(suggestion.kind.rawValue.capitalized, systemImage: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                Text(formatMilliseconds(suggestion.ts))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                if let latencyMS = suggestion.latencyMS {
                    Text("\(latencyMS)ms")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            if !suggestion.prompt.isEmpty {
                Text("Q: \(suggestion.prompt)")
                    .font(.system(size: 12, weight: .medium))
                    .textSelection(.enabled)
            }

            Text(suggestion.content)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 5)
    }

    private func emptyText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
    }

    @MainActor
    private func search(selectFirst: Bool) async {
        isSearching = true
        defer { isSearching = false }

        do {
            let nextResults = try await AppDatabase.shared.searchHistory(query: query)
            results = nextResults
            errorMessage = nil

            if let selectedResultID,
               nextResults.contains(where: { $0.id == selectedResultID }) {
                return
            }

            selectedResultID = nil
            detail = nil
            if selectFirst, let first = nextResults.first {
                selectedResultID = first.id
                await loadDetail(sessionID: first.sessionID)
            }
        } catch {
            errorMessage = error.localizedDescription
            results = []
            selectedResultID = nil
            detail = nil
        }
    }

    @MainActor
    private func select(_ result: SearchHistoryResult) {
        selectedResultID = result.id
        Task {
            await loadDetail(sessionID: result.sessionID)
        }
    }

    @MainActor
    private func loadDetail(sessionID: String) async {
        isLoadingDetail = true
        defer { isLoadingDetail = false }

        do {
            detail = try await AppDatabase.shared.historySessionDetail(sessionID: sessionID)
            errorMessage = detail == nil ? "Session no longer exists." : nil
        } catch {
            detail = nil
            errorMessage = error.localizedDescription
        }
    }

    private func cleanSnippet(_ snippet: String) -> String {
        snippet.replacingOccurrences(of: "\\s+",
                                      with: " ",
                                      options: .regularExpression)
    }

    private func excerpt(_ text: String, limit: Int) -> String {
        let collapsed = cleanSnippet(text)
        return String(collapsed.prefix(limit))
    }

    private func formatSeconds(_ seconds: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(seconds))
            .formatted(date: .abbreviated, time: .shortened)
    }

    private func formatMilliseconds(_ milliseconds: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
            .formatted(date: .abbreviated, time: .shortened)
    }
}

private extension SearchHistoryKind {
    var label: String {
        switch self {
        case .session: return "Session"
        case .transcript: return "Transcript"
        case .document: return "Document"
        case .suggestion: return "Suggestion"
        }
    }

    var iconName: String {
        switch self {
        case .session: return "rectangle.stack"
        case .transcript: return "quote.bubble"
        case .document: return "doc.text"
        case .suggestion: return "sparkles"
        }
    }
}
