//
//  AppDatabase.swift
//  OverlayOpus
//

import Foundation
import GRDB

enum AppDatabaseError: LocalizedError {
    case missingSession(String)

    var errorDescription: String? {
        switch self {
        case .missingSession(let id):
            return "No session found for id \(id)"
        }
    }
}

struct SessionExportSnapshot: Codable {
    var session: CallSessionRecord
    var contextDocs: [ContextDocRecord]
    var transcript: [TranscriptChunkRecord]
    var suggestions: [SuggestionRecord]
    var memory: [MemoryItemRecord]
    var artifacts: [SessionArtifactRecord]
    var audits: [PrivacyAuditRecord]
}

final class AppDatabase: @unchecked Sendable {
    static let shared: AppDatabase = {
        do {
            return try AppDatabase()
        } catch {
            fatalError("AppDatabase failed to open: \(error)")
        }
    }()

    private let dbQueue: DatabaseQueue
    private let workQueue = DispatchQueue(label: "com.overlayopus.database", qos: .utility)
    private let fileManager = FileManager.default

    private static func storageDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory,
                                    in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support",
                                        isDirectory: true)
        return base.appendingPathComponent("Overlay", isDirectory: true)
    }

    private static func databaseURL(fileManager: FileManager = .default) -> URL {
        storageDirectory(fileManager: fileManager).appendingPathComponent("db.sqlite", isDirectory: false)
    }

    init() throws {
        let directory = Self.storageDirectory(fileManager: fileManager)
        let url = Self.databaseURL(fileManager: fileManager)

        try fileManager.createDirectory(at: directory,
                                        withIntermediateDirectories: true,
                                        attributes: nil)

        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        dbQueue = try DatabaseQueue(path: url.path, configuration: configuration)
        try Migrations.makeMigrator().migrate(dbQueue)
        try migrateSensitiveRowsAtRest()
    }

    func createOrUpdateSession(_ session: CallSessionRecord) async throws -> CallSessionRecord {
        try await write { db in
            try self.encrypted(session).save(db)
            return session
        }
    }

    func insertCallSession(_ session: CallSessionRecord) async throws {
        _ = try await createOrUpdateSession(session)
    }

    func finishCallSession(id: String, endedAt: Date) async throws {
        try await write { db in
            try db.execute(sql: """
                UPDATE call_session
                SET status = ?, ended_at = ?
                WHERE id = ?
                """,
                arguments: [CallSessionStatus.ended.rawValue, endedAt.unixSeconds, id])
        }
    }

    func fetchSessions() async throws -> [CallSessionRecord] {
        try await read { db in
            try CallSessionRecord
                .order(CallSessionRecord.Columns.createdAt.desc)
                .fetchAll(db)
                .map(self.decrypted)
        }
    }

    func fetchSession(id: String) async throws -> CallSessionRecord? {
        try await read { db in
            try CallSessionRecord.fetchOne(db, key: id).map(self.decrypted)
        }
    }

    func insertContextDoc(_ doc: ContextDocRecord) async throws -> ContextDocRecord {
        try await write { db in
            try self.encrypted(doc).insert(db)
            return doc
        }
    }

    func contextDocs(sessionID: String) async throws -> [ContextDocRecord] {
        try await read { db in
            try ContextDocRecord
                .filter(ContextDocRecord.Columns.sessionID == sessionID)
                .order(ContextDocRecord.Columns.addedAt.asc)
                .fetchAll(db)
                .map(self.decrypted)
        }
    }

    func updateContextDocSummary(id: String, summary: String?) async throws {
        try await updateContextDocSummary(id: id, summary: summary, updatedAt: Date())
    }

    func updateContextDocSummary(id: String, summary: String?, updatedAt: Date) async throws {
        try await write { db in
            try db.execute(sql: """
                UPDATE context_doc
                SET summary = ?
                WHERE id = ?
                """,
                arguments: [try self.protector.encryptString(summary), id])
        }
    }

    func insertTranscriptChunk(_ chunk: TranscriptChunkRecord) async throws -> TranscriptChunkRecord {
        try await write { db in
            try self.encrypted(chunk).insert(db)
            return chunk
        }
    }

    func transcriptChunks(sessionID: String) async throws -> [TranscriptChunkRecord] {
        try await read { db in
            try TranscriptChunkRecord
                .filter(TranscriptChunkRecord.Columns.sessionID == sessionID)
                .order(TranscriptChunkRecord.Columns.ts.asc)
                .fetchAll(db)
                .map(self.decrypted)
        }
    }

    func insertSuggestion(_ suggestion: SuggestionRecord) async throws -> SuggestionRecord {
        try await write { db in
            try self.encrypted(suggestion).insert(db)
            return suggestion
        }
    }

    func suggestions(sessionID: String) async throws -> [SuggestionRecord] {
        try await read { db in
            try SuggestionRecord
                .filter(SuggestionRecord.Columns.sessionID == sessionID)
                .order(SuggestionRecord.Columns.ts.asc)
                .fetchAll(db)
                .map(self.decrypted)
        }
    }

    func insertAnalysisEvent(_ event: AnalysisEventRecord) async throws -> AnalysisEventRecord {
        try await write { db in
            try self.encrypted(event).insert(db)
            return event
        }
    }

    func insertMemoryItem(_ item: MemoryItemRecord) async throws -> MemoryItemRecord {
        try await write { db in
            try self.encrypted(item).insert(db)
            return item
        }
    }

    func memoryItems(sessionID: String) async throws -> [MemoryItemRecord] {
        try await read { db in
            try MemoryItemRecord
                .filter(Column("session_id") == sessionID)
                .order(Column("ts").desc)
                .fetchAll(db)
                .map(self.decrypted)
        }
    }

    func insertPrivacyAudit(_ audit: PrivacyAuditRecord) async throws -> PrivacyAuditRecord {
        try await write { db in
            try self.encrypted(audit).insert(db)
            return audit
        }
    }

    func insertSessionArtifact(_ artifact: SessionArtifactRecord) async throws -> SessionArtifactRecord {
        try await write { db in
            try self.encrypted(artifact).insert(db)
            return artifact
        }
    }

    func sessionArtifacts(sessionID: String, kind: String? = nil) async throws -> [SessionArtifactRecord] {
        try await read { db in
            var request = SessionArtifactRecord
                .filter(Column("session_id") == sessionID)
            if let kind {
                request = request.filter(Column("kind") == kind)
            }
            return try request
                .order(Column("ts").desc)
                .fetchAll(db)
                .map(self.decrypted)
        }
    }

    func exportSnapshot(sessionID: String) async throws -> SessionExportSnapshot {
        try await read { db in
            guard let session = try CallSessionRecord.fetchOne(db, key: sessionID) else {
                throw AppDatabaseError.missingSession(sessionID)
            }

            let contextDocs = try ContextDocRecord
                .filter(ContextDocRecord.Columns.sessionID == sessionID)
                .order(ContextDocRecord.Columns.addedAt.asc)
                .fetchAll(db)
            let transcript = try TranscriptChunkRecord
                .filter(TranscriptChunkRecord.Columns.sessionID == sessionID)
                .order(TranscriptChunkRecord.Columns.ts.asc)
                .fetchAll(db)
            let suggestions = try SuggestionRecord
                .filter(SuggestionRecord.Columns.sessionID == sessionID)
                .order(SuggestionRecord.Columns.ts.asc)
                .fetchAll(db)
            let memory = try MemoryItemRecord
                .filter(Column("session_id") == sessionID)
                .order(Column("ts").asc)
                .fetchAll(db)
            let artifacts = try SessionArtifactRecord
                .filter(Column("session_id") == sessionID)
                .order(Column("ts").asc)
                .fetchAll(db)
            let audits = try PrivacyAuditRecord
                .filter(Column("session_id") == sessionID)
                .order(Column("ts").asc)
                .fetchAll(db)

            return SessionExportSnapshot(session: self.decrypted(session),
                                         contextDocs: contextDocs.map(self.decrypted),
                                         transcript: transcript.map(self.decrypted),
                                         suggestions: suggestions.map(self.decrypted),
                                         memory: memory.map(self.decrypted),
                                         artifacts: artifacts.map(self.decrypted),
                                         audits: audits.map(self.decrypted))
        }
    }

    func deleteSession(id: String) async throws {
        try await write { db in
            _ = try CallSessionRecord.deleteOne(db, key: id)
        }
    }

    func fetchProviderConfigs() async throws -> [ProviderConfigRecord] {
        try await read { db in
            try ProviderConfigRecord
                .order(ProviderConfigRecord.Columns.createdAt.desc)
                .fetchAll(db)
                .map(self.decrypted)
        }
    }

    func listProviderConfigs() async throws -> [ProviderConfigRecord] {
        try await fetchProviderConfigs()
    }

    func saveProviderConfig(_ config: ProviderConfigRecord) async throws -> ProviderConfigRecord {
        try await write { db in
            try self.encrypted(config).save(db)
            return config
        }
    }

    func deleteProviderConfig(id: String) async throws {
        try await write { db in
            _ = try ProviderConfigRecord.deleteOne(db, key: id)
        }
    }

    func searchHistory(query: String) async throws -> [SearchHistoryResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try await sessionsAsHistory() }

        return try await read { db in
            var results: [SearchHistoryResult] = []

            let sessions = try CallSessionRecord.fetchAll(db)
                .map(self.decrypted)
            let titlesByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.title) })

            let transcriptRows = try TranscriptChunkRecord.fetchAll(db)
                .map(self.decrypted)
                .filter { $0.text.localizedCaseInsensitiveContains(trimmed) }
                .prefix(25)
                .map {
                    SearchHistoryResult(id: $0.id,
                                        kind: .transcript,
                                        sessionID: $0.sessionID,
                                        title: titlesByID[$0.sessionID] ?? "Session",
                                        snippet: Self.snippet(for: $0.text, matching: trimmed),
                                        createdAt: $0.ts / 1000)
                }
            results.append(contentsOf: transcriptRows)

            let docRows = try ContextDocRecord.fetchAll(db)
                .map(self.decrypted)
                .filter { doc in
                    doc.content.localizedCaseInsensitiveContains(trimmed)
                        || (doc.summary?.localizedCaseInsensitiveContains(trimmed) ?? false)
                }
                .prefix(25)
                .map {
                    SearchHistoryResult(id: $0.id,
                                        kind: .document,
                                        sessionID: $0.sessionID,
                                        title: titlesByID[$0.sessionID] ?? "Session",
                                        snippet: Self.snippet(for: [$0.summary, $0.content].compactMap { $0 }.joined(separator: "\n"),
                                                              matching: trimmed),
                                        createdAt: $0.addedAt)
                }
            results.append(contentsOf: docRows)
            return results.sorted { $0.createdAt > $1.createdAt }
        }
    }

    private func sessionsAsHistory() async throws -> [SearchHistoryResult] {
        try await read { db in
            try CallSessionRecord
                .order(CallSessionRecord.Columns.createdAt.desc)
                .limit(25)
                .fetchAll(db)
                .map(self.decrypted)
                .map {
                    SearchHistoryResult(id: $0.id,
                                        kind: .transcript,
                                        sessionID: $0.id,
                                        title: $0.title,
                                        snippet: $0.brief.isEmpty ? $0.status.rawValue : $0.brief,
                                        createdAt: $0.createdAt)
                }
        }
    }

    private func read<T>(_ block: @escaping (Database) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            workQueue.async {
                do {
                    continuation.resume(returning: try self.dbQueue.read(block))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func write<T>(_ block: @escaping (Database) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            workQueue.async {
                do {
                    continuation.resume(returning: try self.dbQueue.write(block))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private var protector: LocalDataProtector {
        LocalDataProtector.shared
    }

    private func migrateSensitiveRowsAtRest() throws {
        try dbQueue.write { db in
            for record in try CallSessionRecord.fetchAll(db) { try encrypted(record).update(db) }
            for record in try ContextDocRecord.fetchAll(db) { try encrypted(record).update(db) }
            for record in try TranscriptChunkRecord.fetchAll(db) { try encrypted(record).update(db) }
            for record in try SuggestionRecord.fetchAll(db) { try encrypted(record).update(db) }
            for record in try ProviderConfigRecord.fetchAll(db) { try encrypted(record).update(db) }
            for record in try AnalysisEventRecord.fetchAll(db) { try encrypted(record).update(db) }
            for record in try MemoryItemRecord.fetchAll(db) { try encrypted(record).update(db) }
            for record in try PrivacyAuditRecord.fetchAll(db) { try encrypted(record).update(db) }
            for record in try SessionArtifactRecord.fetchAll(db) { try encrypted(record).update(db) }
        }
    }

    private func encrypted(_ record: CallSessionRecord) throws -> CallSessionRecord {
        var copy = record
        copy.title = try protector.encryptString(copy.title)
        copy.brief = try protector.encryptString(copy.brief)
        return copy
    }

    private func decrypted(_ record: CallSessionRecord) -> CallSessionRecord {
        var copy = record
        copy.title = protector.decryptString(copy.title)
        copy.brief = protector.decryptString(copy.brief)
        return copy
    }

    private func encrypted(_ record: ContextDocRecord) throws -> ContextDocRecord {
        var copy = record
        copy.filename = try protector.encryptString(copy.filename)
        copy.content = try protector.encryptString(copy.content)
        copy.summary = try protector.encryptString(copy.summary)
        return copy
    }

    private func decrypted(_ record: ContextDocRecord) -> ContextDocRecord {
        var copy = record
        copy.filename = protector.decryptString(copy.filename)
        copy.content = protector.decryptString(copy.content)
        copy.summary = protector.decryptString(copy.summary)
        return copy
    }

    private func encrypted(_ record: TranscriptChunkRecord) throws -> TranscriptChunkRecord {
        var copy = record
        copy.text = try protector.encryptString(copy.text)
        return copy
    }

    private func decrypted(_ record: TranscriptChunkRecord) -> TranscriptChunkRecord {
        var copy = record
        copy.text = protector.decryptString(copy.text)
        return copy
    }

    private func encrypted(_ record: SuggestionRecord) throws -> SuggestionRecord {
        var copy = record
        copy.prompt = try protector.encryptString(copy.prompt)
        copy.content = try protector.encryptString(copy.content)
        return copy
    }

    private func decrypted(_ record: SuggestionRecord) -> SuggestionRecord {
        var copy = record
        copy.prompt = protector.decryptString(copy.prompt)
        copy.content = protector.decryptString(copy.content)
        return copy
    }

    private func encrypted(_ record: ProviderConfigRecord) throws -> ProviderConfigRecord {
        var copy = record
        copy.name = try protector.encryptString(copy.name)
        copy.configJSON = try protector.encryptData(copy.configJSON)
        return copy
    }

    private func decrypted(_ record: ProviderConfigRecord) -> ProviderConfigRecord {
        var copy = record
        copy.name = protector.decryptString(copy.name)
        copy.configJSON = protector.decryptData(copy.configJSON)
        return copy
    }

    private func encrypted(_ record: AnalysisEventRecord) throws -> AnalysisEventRecord {
        var copy = record
        copy.payloadJSON = try protector.encryptData(copy.payloadJSON)
        return copy
    }

    private func encrypted(_ record: MemoryItemRecord) throws -> MemoryItemRecord {
        var copy = record
        copy.text = try protector.encryptString(copy.text)
        copy.payloadJSON = try protector.encryptData(copy.payloadJSON)
        return copy
    }

    private func decrypted(_ record: MemoryItemRecord) -> MemoryItemRecord {
        var copy = record
        copy.text = protector.decryptString(copy.text)
        copy.payloadJSON = protector.decryptData(copy.payloadJSON)
        return copy
    }

    private func encrypted(_ record: PrivacyAuditRecord) throws -> PrivacyAuditRecord {
        var copy = record
        copy.detail = try protector.encryptString(copy.detail)
        return copy
    }

    private func decrypted(_ record: PrivacyAuditRecord) -> PrivacyAuditRecord {
        var copy = record
        copy.detail = protector.decryptString(copy.detail)
        return copy
    }

    private func encrypted(_ record: SessionArtifactRecord) throws -> SessionArtifactRecord {
        var copy = record
        copy.title = try protector.encryptString(copy.title)
        copy.content = try protector.encryptString(copy.content)
        copy.payloadJSON = try protector.encryptData(copy.payloadJSON)
        return copy
    }

    private func decrypted(_ record: SessionArtifactRecord) -> SessionArtifactRecord {
        var copy = record
        copy.title = protector.decryptString(copy.title)
        copy.content = protector.decryptString(copy.content)
        copy.payloadJSON = protector.decryptData(copy.payloadJSON)
        return copy
    }

    private static func snippet(for text: String, matching query: String) -> String {
        let normalizedText = text as NSString
        let range = normalizedText.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
        guard range.location != NSNotFound else {
            return String(text.prefix(180))
        }

        let start = max(0, range.location - 70)
        let end = min(normalizedText.length, range.location + range.length + 90)
        let snippet = normalizedText.substring(with: NSRange(location: start, length: end - start))
        let prefix = start > 0 ? "..." : ""
        let suffix = end < normalizedText.length ? "..." : ""
        return prefix + snippet + suffix
    }

    private static func makeSearchResult(row: Row) -> SearchHistoryResult? {
        guard let id: String = row["id"],
              let rawKind: String = row["kind"],
              let kind = SearchHistoryKind(rawValue: rawKind),
              let sessionID: String = row["session_id"],
              let title: String = row["title"],
              let snippet: String = row["snippet"],
              let createdAt: Int64 = row["created_at"] else {
            return nil
        }

        return SearchHistoryResult(id: id,
                                   kind: kind,
                                   sessionID: sessionID,
                                   title: title,
                                   snippet: snippet,
                                   createdAt: createdAt)
    }
}
