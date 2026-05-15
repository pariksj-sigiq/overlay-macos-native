//
//  DocumentIngestor.swift
//  OverlayOpus
//

import Foundation

actor DocumentIngestor {
    static let shared = DocumentIngestor()

    struct PreparedDocument: Equatable {
        var filename: String
        var kind: ContextDocKind
        var characterCount: Int
        var preview: String
    }

    enum IngestError: LocalizedError {
        case missingSession
        case unsupportedFileType(String)
        case unreadableText

        var errorDescription: String? {
            switch self {
            case .missingSession:
                return "Start a call before ingesting this document."
            case .unsupportedFileType(let ext):
                return "Unsupported document type: \(ext)"
            case .unreadableText:
                return "No readable text was found in this document."
            }
        }
    }

    private struct PreparedPayload {
        var document: PreparedDocument
        var text: String
    }

    private var preparedPayloads: [String: PreparedPayload] = [:]

    @discardableResult
    func prepare(url: URL) async throws -> PreparedDocument {
        let payload = try await makePayload(for: url)
        preparedPayloads[cacheKey(for: url)] = payload
        return payload.document
    }

    @discardableResult
    func ingest(url: URL,
                sessionID: String?,
                providerID: String,
                modelID: String) async throws -> ContextDocRecord {
        guard let sessionID else {
            throw IngestError.missingSession
        }
        let key = cacheKey(for: url)
        let payload: PreparedPayload
        if let preparedPayload = preparedPayloads[key] {
            payload = preparedPayload
        } else {
            payload = try await makePayload(for: url)
        }
        preparedPayloads[key] = nil

        let record = ContextDocRecord(sessionID: sessionID,
                                      kind: kind(for: url),
                                      filename: payload.document.filename,
                                      content: payload.text,
                                      summary: nil)
        _ = try await AppDatabase.shared.insertContextDoc(record)

        Task.detached(priority: .utility) {
            await self.summarize(record: record, providerID: providerID, modelID: modelID)
        }

        return record
    }

    private func makePayload(for url: URL) async throws -> PreparedPayload {
        let text = try await extractText(from: url)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw IngestError.unreadableText
        }

        let document = PreparedDocument(filename: url.lastPathComponent,
                                        kind: kind(for: url),
                                        characterCount: trimmed.count,
                                        preview: Self.preview(from: trimmed))
        return PreparedPayload(document: document, text: trimmed)
    }

    private func extractText(from url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let ext = url.pathExtension.lowercased()
            switch ext {
            case "pdf":
                return try PdfParser().parse(url: url)
            case "docx":
                return try DocxParser().parse(url: url)
            case "md", "markdown", "txt":
                return try String(contentsOf: url, encoding: .utf8)
            default:
                throw IngestError.unsupportedFileType(ext.isEmpty ? "unknown" : ext)
            }
        }.value
    }

    private func summarize(record: ContextDocRecord, providerID: String, modelID: String) async {
        let excerpt = String(record.content.prefix(12_000))
        let request = LLMRequest(systemPrompt: "Summarize this meeting context document in 200 words or fewer. Keep concrete names, dates, decisions, and risks.",
                                 userPrompt: excerpt,
                                 modelID: modelID,
                                 temperature: 0.2,
                                 maxTokens: 350)

        do {
            let provider = try await ProviderRegistry.shared.provider(id: providerID)
            var summary = ""
            for try await event in provider.stream(request) {
                switch event {
                case .token(let token):
                    summary += token
                case .done:
                    break
                case .error(let error):
                    throw error
                }
            }
            try await AppDatabase.shared.updateContextDocSummary(id: record.id,
                                                                 summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
                                                                 updatedAt: Date())
        } catch {
            #if DEBUG
            print("DocumentIngestor: summary failed: \(error)")
            #endif
        }
    }

    private func cacheKey(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private static func preview(from text: String) -> String {
        let collapsed = text.replacingOccurrences(of: "\\s+",
                                                   with: " ",
                                                   options: .regularExpression)
        return String(collapsed.prefix(260))
    }

    private func kind(for url: URL) -> ContextDocKind {
        switch url.pathExtension.lowercased() {
        case "pdf": return .pdf
        case "docx": return .docx
        case "md", "markdown": return .md
        case "txt": return .txt
        default: return .note
        }
    }
}
