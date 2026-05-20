//
//  AppDatabase.swift
//  OverlayOpus
//

import Foundation
import GRDB

final class AppDatabase {
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
    }

    func createOrUpdateSession(_ session: CallSessionRecord) async throws -> CallSessionRecord {
        try await write { db in
            try session.save(db)
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
        }
    }

    func fetchSession(id: String) async throws -> CallSessionRecord? {
        try await read { db in
            try CallSessionRecord.fetchOne(db, key: id)
        }
    }

    func insertContextDoc(_ doc: ContextDocRecord) async throws -> ContextDocRecord {
        try await write { db in
            try doc.insert(db)
            return doc
        }
    }

    func contextDocs(sessionID: String) async throws -> [ContextDocRecord] {
        try await read { db in
            try ContextDocRecord
                .filter(ContextDocRecord.Columns.sessionID == sessionID)
                .order(ContextDocRecord.Columns.addedAt.asc)
                .fetchAll(db)
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
                arguments: [summary, id])
        }
    }

    func insertTranscriptChunk(_ chunk: TranscriptChunkRecord) async throws -> TranscriptChunkRecord {
        try await write { db in
            try chunk.insert(db)
            return chunk
        }
    }

    func transcriptChunks(sessionID: String) async throws -> [TranscriptChunkRecord] {
        try await read { db in
            try TranscriptChunkRecord
                .filter(TranscriptChunkRecord.Columns.sessionID == sessionID)
                .order(TranscriptChunkRecord.Columns.ts.asc)
                .fetchAll(db)
        }
    }

    func insertSuggestion(_ suggestion: SuggestionRecord) async throws -> SuggestionRecord {
        try await write { db in
            try suggestion.insert(db)
            return suggestion
        }
    }

    func suggestions(sessionID: String) async throws -> [SuggestionRecord] {
        try await read { db in
            try SuggestionRecord
                .filter(SuggestionRecord.Columns.sessionID == sessionID)
                .order(SuggestionRecord.Columns.ts.asc)
                .fetchAll(db)
        }
    }

    func insertAnalysisEvent(_ event: AnalysisEventRecord) async throws -> AnalysisEventRecord {
        try await write { db in
            try event.insert(db)
            return event
        }
    }

    func insertMemoryItem(_ item: MemoryItemRecord) async throws -> MemoryItemRecord {
        try await write { db in
            try item.insert(db)
            return item
        }
    }

    func memoryItems(sessionID: String) async throws -> [MemoryItemRecord] {
        try await read { db in
            try MemoryItemRecord
                .filter(Column("session_id") == sessionID)
                .order(Column("ts").desc)
                .fetchAll(db)
        }
    }

    func insertPrivacyAudit(_ audit: PrivacyAuditRecord) async throws -> PrivacyAuditRecord {
        try await write { db in
            try audit.insert(db)
            return audit
        }
    }

    func insertSessionArtifact(_ artifact: SessionArtifactRecord) async throws -> SessionArtifactRecord {
        try await write { db in
            try artifact.insert(db)
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
        }
    }

    func fetchProviderConfigs() async throws -> [ProviderConfigRecord] {
        try await read { db in
            try ProviderConfigRecord
                .order(ProviderConfigRecord.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }

    func listProviderConfigs() async throws -> [ProviderConfigRecord] {
        try await fetchProviderConfigs()
    }

    func saveProviderConfig(_ config: ProviderConfigRecord) async throws -> ProviderConfigRecord {
        try await write { db in
            try config.save(db)
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

            let transcriptRows = try Row.fetchAll(db,
                                                  sql: """
                                                  SELECT
                                                      tc.id,
                                                      'transcript' AS kind,
                                                      tc.session_id,
                                                      cs.title,
                                                      snippet(transcript_fts, 0, '[', ']', '...', 12) AS snippet,
                                                      tc.ts AS created_at
                                                  FROM transcript_fts
                                                  JOIN transcript_chunk tc ON tc.rowid = transcript_fts.rowid
                                                  JOIN call_session cs ON cs.id = tc.session_id
                                                  WHERE transcript_fts MATCH ?
                                                  ORDER BY rank
                                                  LIMIT 25
                                                  """,
                                                  arguments: [trimmed])

            results.append(contentsOf: transcriptRows.compactMap(Self.makeSearchResult(row:)))

            let docRows = try Row.fetchAll(db,
                                           sql: """
                                           SELECT
                                               cd.id,
                                               'document' AS kind,
                                               cd.session_id,
                                               cs.title,
                                               snippet(doc_fts, 0, '[', ']', '...', 12) AS snippet,
                                               cd.added_at AS created_at
                                           FROM doc_fts
                                           JOIN context_doc cd ON cd.rowid = doc_fts.rowid
                                           JOIN call_session cs ON cs.id = cd.session_id
                                           WHERE doc_fts MATCH ?
                                           ORDER BY rank
                                           LIMIT 25
                                           """,
                                           arguments: [trimmed])

            results.append(contentsOf: docRows.compactMap(Self.makeSearchResult(row:)))
            return results.sorted { $0.createdAt > $1.createdAt }
        }
    }

    private func sessionsAsHistory() async throws -> [SearchHistoryResult] {
        try await read { db in
            try CallSessionRecord
                .order(CallSessionRecord.Columns.createdAt.desc)
                .limit(25)
                .fetchAll(db)
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
