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
    @State private var documents: [BriefDocumentItem] = []
    @State private var providerID = ""
    @State private var modelID = ""
    @State private var isStarting = false
    @State private var startStatus: String?
    @State private var startError: String?
    @State private var trackingTask: Task<Void, Never>?

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedModelID: String {
        modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var readyDocuments: [BriefDocumentItem] {
        documents.filter(\.isReadyForStart)
    }

    private var hasPreparingDocuments: Bool {
        documents.contains { document in
            if case .extracting = document.status {
                return true
            }
            return false
        }
    }

    private var hasQueuedDocuments: Bool {
        documents.contains { document in
            if case .queued = document.status {
                return true
            }
            return false
        }
    }

    private var startDisabled: Bool {
        trimmedTitle.isEmpty ||
            providerID.isEmpty ||
            trimmedModelID.isEmpty ||
            hasPreparingDocuments ||
            isStarting
    }

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
                    addDroppedDocuments(urls)
                }

                documentsSection

                if let startStatus {
                    Label(startStatus, systemImage: "checkmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                if let startError {
                    Label(startError, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                } else if let sessionError = sessionStore.errorMessage {
                    Label(sessionError, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }

                controlsRow
            }
            .padding(14)
        }
        .task {
            try? await providerRegistry.reload()
            if providerID.isEmpty {
                providerID = providerRegistry.providers.first?.id ?? ""
                modelID = providerRegistry.defaultModelID(for: providerID) ?? ""
            }
        }
        .onChange(of: providerID) { _, newValue in
            modelID = providerRegistry.defaultModelID(for: newValue) ?? modelID
        }
        .onDisappear {
            trackingTask?.cancel()
        }
    }

    private var documentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Documents")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            if documents.isEmpty {
                Text("Drop PDFs, DOCX, Markdown, or text files to prepare them for this call.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(documents) { document in
                    documentRow(document)
                }
            }
        }
    }

    private var controlsRow: some View {
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
                startPreparedCall()
            } label: {
                Label(isStarting ? "Starting" : "Start Call", systemImage: "phone.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(startDisabled)
        }
    }

    private func documentRow(_ document: BriefDocumentItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: document.status.iconName)
                .foregroundStyle(document.status.tint)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(document.filename)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(document.fileType)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 8)
                    Text(document.status.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(document.status.tint)
                }

                if let detail = document.status.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }

            if document.canRemove {
                Button {
                    removeDocument(id: document.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .imageScale(.medium)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Remove")
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
    }

    @MainActor
    private func addDroppedDocuments(_ urls: [URL]) {
        startStatus = nil
        startError = nil

        for url in urls {
            let path = url.standardizedFileURL.path
            guard !documents.contains(where: { $0.path == path }) else { continue }

            let item = BriefDocumentItem(url: url,
                                         path: path,
                                         filename: url.lastPathComponent,
                                         fileType: fileTypeLabel(for: url),
                                         status: isAcceptedDocument(url)
                                            ? .extracting
                                            : .failed("Unsupported document type."))
            documents.append(item)

            guard isAcceptedDocument(url) else { continue }
            Task {
                await prepareDocument(id: item.id, url: url)
            }
        }
    }

    @MainActor
    private func removeDocument(id: UUID) {
        documents.removeAll { $0.id == id && $0.canRemove }
    }

    private func prepareDocument(id: UUID, url: URL) async {
        do {
            let prepared = try await DocumentIngestor.shared.prepare(url: url)
            setDocument(id: id) { document in
                document.fileType = prepared.kind.rawValue.uppercased()
                document.status = .ready(characterCount: prepared.characterCount,
                                         preview: prepared.preview)
            }
        } catch {
            setDocument(id: id) { document in
                document.status = .failed(error.localizedDescription)
            }
        }
    }

    @MainActor
    private func setDocument(id: UUID, update: (inout BriefDocumentItem) -> Void) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        update(&documents[index])
    }

    @MainActor
    private func startPreparedCall() {
        let attachableDocuments = readyDocuments
        let ignoredCount = documents.count - attachableDocuments.count
        for document in attachableDocuments {
            setDocument(id: document.id) { item in
                item.status = .queued
            }
        }

        isStarting = true
        startError = nil
        startStatus = startMessage(queuedCount: attachableDocuments.count,
                                   ignoredCount: ignoredCount)

        let requestedAt = Date().unixSeconds
        let scheduledAt = hasScheduledDate ? scheduledDate : nil
        sessionStore.startCall(title: trimmedTitle,
                               brief: brief,
                               providerID: providerID,
                               modelID: trimmedModelID,
                               scheduledAt: scheduledAt,
                               documents: attachableDocuments.map(\.url))

        trackingTask?.cancel()
        trackingTask = Task {
            await trackStartedCall(title: trimmedTitle,
                                   requestedAt: requestedAt,
                                   scheduledAt: scheduledAt,
                                   documentIDs: attachableDocuments.map(\.id))
        }
    }

    private func trackStartedCall(title: String,
                                  requestedAt: Int64,
                                  scheduledAt: Date?,
                                  documentIDs: [UUID]) async {
        guard let session = await waitForActiveSession(title: title, requestedAt: requestedAt) else {
            markStartFailed("Call did not start. Check provider and audio permissions.")
            return
        }

        if let scheduledAt {
            do {
                try await AppDatabase.shared.updateCallSessionScheduledAt(id: session.id,
                                                                          scheduledAt: scheduledAt)
            } catch {
                await MainActor.run {
                    startError = "Call started, but scheduled date was not saved: \(error.localizedDescription)"
                }
            }
        }

        await pollDocumentIngestion(sessionID: session.id, documentIDs: documentIDs)
    }

    private func waitForActiveSession(title: String, requestedAt: Int64) async -> CallSessionRecord? {
        for _ in 0..<50 {
            let session = await MainActor.run {
                sessionStore.activeSession
            }
            if let session,
               session.title == title,
               session.createdAt >= requestedAt - 1 {
                return session
            }

            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    private func pollDocumentIngestion(sessionID: String, documentIDs: [UUID]) async {
        guard !documentIDs.isEmpty else {
            await MainActor.run {
                isStarting = false
                startStatus = "Call started without prepared documents."
            }
            return
        }

        var lastError: String?
        for _ in 0..<45 {
            do {
                let records = try await AppDatabase.shared.contextDocs(sessionID: sessionID)
                let state = reconcileDocumentRecords(records, documentIDs: documentIDs)
                if !state.hasQueuedDocuments && !state.hasSummaryPending {
                    await MainActor.run {
                        isStarting = false
                        startStatus = "Call started. Documents are available in history."
                    }
                    return
                }
            } catch {
                lastError = error.localizedDescription
            }

            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        await MainActor.run {
            markQueuedDocumentsNotConfirmed(message: lastError ?? sessionStore.errorMessage ?? "Ingestion is still not visible in history.")
            isStarting = false
            if hasQueuedDocuments {
                startError = "Some documents were not confirmed after Start Call."
            } else {
                startStatus = "Call started. Document summaries may continue in the background."
            }
        }
    }

    @MainActor
    private func reconcileDocumentRecords(_ records: [ContextDocRecord],
                                          documentIDs: [UUID]) -> DocumentIngestionState {
        var matchedRecordIDs = Set<String>()

        for id in documentIDs {
            guard let index = documents.firstIndex(where: { $0.id == id }) else { continue }
            guard documents[index].canReceiveIngestionUpdate else { continue }

            guard let record = records.first(where: { record in
                !matchedRecordIDs.contains(record.id) &&
                    record.filename == documents[index].filename
            }) else {
                continue
            }

            matchedRecordIDs.insert(record.id)
            let summary = record.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
            documents[index].status = .ingested(summary: summary?.isEmpty == false ? summary : nil,
                                                preview: excerpt(record.content, limit: 260))
        }

        return DocumentIngestionState(hasQueuedDocuments: hasQueuedDocuments,
                                      hasSummaryPending: documents.contains { document in
                                          documentIDs.contains(document.id) && document.status.isSummaryPending
                                      })
    }

    @MainActor
    private func markStartFailed(_ message: String) {
        markQueuedDocumentsNotConfirmed(message: message)
        isStarting = false
        startStatus = nil
        startError = message
    }

    @MainActor
    private func markQueuedDocumentsNotConfirmed(message: String) {
        for index in documents.indices {
            if case .queued = documents[index].status {
                documents[index].status = .notConfirmed(message)
            }
        }
    }

    private func startMessage(queuedCount: Int, ignoredCount: Int) -> String {
        var parts: [String] = []
        parts.append(queuedCount == 1 ? "1 document queued for ingestion." : "\(queuedCount) documents queued for ingestion.")
        if queuedCount == 0 {
            parts = ["Call starting without prepared documents."]
        }
        if ignoredCount > 0 {
            parts.append(ignoredCount == 1 ? "1 document is not ready and will be ignored." : "\(ignoredCount) documents are not ready and will be ignored.")
        }
        return parts.joined(separator: " ")
    }

    private func isAcceptedDocument(_ url: URL) -> Bool {
        ["pdf", "docx", "md", "markdown", "txt"].contains(url.pathExtension.lowercased())
    }

    private func fileTypeLabel(for url: URL) -> String {
        let ext = url.pathExtension.uppercased()
        return ext.isEmpty ? "FILE" : ext
    }

    private func excerpt(_ text: String, limit: Int) -> String {
        let collapsed = text.replacingOccurrences(of: "\\s+",
                                                   with: " ",
                                                   options: .regularExpression)
        return String(collapsed.prefix(limit))
    }
}

private struct BriefDocumentItem: Identifiable, Equatable {
    var id = UUID()
    var url: URL
    var path: String
    var filename: String
    var fileType: String
    var status: BriefDocumentStatus

    var isReadyForStart: Bool {
        if case .ready = status {
            return true
        }
        return false
    }

    var canRemove: Bool {
        switch status {
        case .queued, .ingested:
            return false
        case .extracting, .ready, .failed, .notConfirmed:
            return true
        }
    }

    var canReceiveIngestionUpdate: Bool {
        switch status {
        case .queued, .ingested:
            return true
        case .extracting, .ready, .failed, .notConfirmed:
            return false
        }
    }
}

private enum BriefDocumentStatus: Equatable {
    case extracting
    case ready(characterCount: Int, preview: String)
    case queued
    case ingested(summary: String?, preview: String)
    case failed(String)
    case notConfirmed(String)

    var iconName: String {
        switch self {
        case .extracting: return "doc.badge.clock"
        case .ready: return "checkmark.circle"
        case .queued: return "arrow.triangle.2.circlepath"
        case .ingested: return "doc.text.magnifyingglass"
        case .failed: return "exclamationmark.triangle"
        case .notConfirmed: return "questionmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .extracting, .queued:
            return .secondary
        case .ready, .ingested:
            return .green
        case .failed:
            return .red
        case .notConfirmed:
            return .orange
        }
    }

    var label: String {
        switch self {
        case .extracting:
            return "Extracting"
        case .ready(let characterCount, _):
            return "\(characterCount.formatted()) chars ready"
        case .queued:
            return "Queued"
        case .ingested(let summary, _):
            return summary == nil ? "Ingested" : "Summarized"
        case .failed:
            return "Failed"
        case .notConfirmed:
            return "Not confirmed"
        }
    }

    var detail: String? {
        switch self {
        case .extracting:
            return "Reading text before the call starts."
        case .ready(_, let preview):
            return preview
        case .queued:
            return "Waiting for the live session to attach this document."
        case .ingested(let summary, let preview):
            return summary ?? preview
        case .failed(let message), .notConfirmed(let message):
            return message
        }
    }

    var isSummaryPending: Bool {
        if case .ingested(let summary, _) = self {
            return summary == nil
        }
        return false
    }
}

private struct DocumentIngestionState {
    var hasQueuedDocuments: Bool
    var hasSummaryPending: Bool
}
