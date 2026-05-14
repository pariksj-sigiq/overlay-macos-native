//
//  DocumentIngestor.swift
//  OverlayOpus
//

import Foundation

actor DocumentIngestor {
    static let shared = DocumentIngestor()

    enum IngestError: LocalizedError {
        case unsupportedFileType(String)
        case unreadableText

        var errorDescription: String? {
            switch self {
            case .unsupportedFileType(let ext):
                return "Unsupported document type: \(ext)"
            case .unreadableText:
                return "No readable text was found in this document."
            }
        }
    }

    private let pdfParser = PdfParser()
    private let docxParser = DocxParser()

    @discardableResult
    func ingest(url: URL,
                sessionID: String?,
                providerID: String,
                modelID: String) async throws -> ContextDocRecord {
        guard let sessionID else {
            throw IngestError.unreadableText
        }
        let filename = url.lastPathComponent
        let text = try await extractText(from: url)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IngestError.unreadableText
        }

        let record = ContextDocRecord(sessionID: sessionID,
                                      kind: kind(for: url),
                                      filename: filename,
                                      content: text,
                                      summary: nil)
        try await AppDatabase.shared.insertContextDoc(record)

        Task.detached(priority: .utility) {
            await self.summarize(record: record, providerID: providerID, modelID: modelID)
        }

        return record
    }

    private func extractText(from url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let ext = url.pathExtension.lowercased()
            switch ext {
            case "pdf":
                return try self.pdfParser.parse(url: url)
            case "docx":
                return try self.docxParser.parse(url: url)
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
