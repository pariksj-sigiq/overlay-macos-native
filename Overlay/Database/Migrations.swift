//
//  Migrations.swift
//  OverlayOpus
//

import Foundation
import GRDB

enum Migrations {
    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("createCallAssistantSchema") { db in
            try db.create(table: "call_session") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("scheduled_at", .integer)
                t.column("brief", .text).notNull().defaults(to: "")
                t.column("status", .text).notNull()
                t.column("provider_id", .text)
                t.column("model_id", .text)
                t.column("created_at", .integer).notNull()
                t.column("ended_at", .integer)
            }

            try db.create(table: "context_doc") { t in
                t.column("id", .text).primaryKey()
                t.column("session_id", .text)
                    .notNull()
                    .references("call_session", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("filename", .text)
                t.column("content", .text).notNull()
                t.column("summary", .text)
                t.column("added_at", .integer).notNull()
            }

            try db.create(table: "transcript_chunk") { t in
                t.column("id", .text).primaryKey()
                t.column("session_id", .text)
                    .notNull()
                    .references("call_session", onDelete: .cascade)
                t.column("ts", .integer).notNull()
                t.column("speaker", .text).notNull()
                t.column("text", .text).notNull()
                t.column("source", .text).notNull().defaults(to: "whisper")
            }

            try db.create(table: "suggestion") { t in
                t.column("id", .text).primaryKey()
                t.column("session_id", .text)
                    .notNull()
                    .references("call_session", onDelete: .cascade)
                t.column("ts", .integer).notNull()
                t.column("kind", .text).notNull()
                t.column("prompt", .text).notNull()
                t.column("content", .text).notNull()
                t.column("model", .text)
                t.column("latency_ms", .integer)
            }

            try db.create(table: "provider_config") { t in
                t.column("id", .text).primaryKey()
                t.column("kind", .text).notNull()
                t.column("name", .text).notNull()
                t.column("config_json", .blob).notNull()
                t.column("created_at", .integer).notNull()
            }

            try db.create(index: "idx_context_doc_session", on: "context_doc", columns: ["session_id"])
            try db.create(index: "idx_transcript_session_ts", on: "transcript_chunk", columns: ["session_id", "ts"])
            try db.create(index: "idx_suggestion_session_ts", on: "suggestion", columns: ["session_id", "ts"])
            try db.create(index: "idx_provider_config_kind", on: "provider_config", columns: ["kind"])

            try createFTSTables(db)
            try createFTSTriggers(db)
        }

        migrator.registerMigration("addIntelligenceSchema") { db in
            try db.create(table: "analysis_event") { t in
                t.column("id", .text).primaryKey()
                t.column("session_id", .text)
                    .notNull()
                    .references("call_session", onDelete: .cascade)
                t.column("ts", .integer).notNull()
                t.column("kind", .text).notNull()
                t.column("payload_json", .blob).notNull()
            }

            try db.create(table: "memory_item") { t in
                t.column("id", .text).primaryKey()
                t.column("session_id", .text)
                    .notNull()
                    .references("call_session", onDelete: .cascade)
                t.column("ts", .integer).notNull()
                t.column("kind", .text).notNull()
                t.column("text", .text).notNull()
                t.column("source_transcript_id", .text)
                t.column("payload_json", .blob)
            }

            try db.create(table: "privacy_audit") { t in
                t.column("id", .text).primaryKey()
                t.column("session_id", .text)
                    .references("call_session", onDelete: .cascade)
                t.column("ts", .integer).notNull()
                t.column("action", .text).notNull()
                t.column("detail", .text).notNull()
            }

            try db.create(table: "session_artifact") { t in
                t.column("id", .text).primaryKey()
                t.column("session_id", .text)
                    .notNull()
                    .references("call_session", onDelete: .cascade)
                t.column("ts", .integer).notNull()
                t.column("kind", .text).notNull()
                t.column("title", .text).notNull()
                t.column("content", .text).notNull()
                t.column("payload_json", .blob)
            }

            try db.create(index: "idx_analysis_session_ts", on: "analysis_event", columns: ["session_id", "ts"])
            try db.create(index: "idx_memory_session_kind", on: "memory_item", columns: ["session_id", "kind"])
            try db.create(index: "idx_privacy_audit_session_ts", on: "privacy_audit", columns: ["session_id", "ts"])
            try db.create(index: "idx_artifact_session_kind", on: "session_artifact", columns: ["session_id", "kind"])
        }

        return migrator
    }

    private static func createFTSTables(_ db: Database) throws {
        try db.execute(sql: """
            CREATE VIRTUAL TABLE transcript_fts USING fts5(
                text,
                content='transcript_chunk',
                content_rowid='rowid'
            )
            """)

        try db.execute(sql: """
            CREATE VIRTUAL TABLE doc_fts USING fts5(
                content,
                summary,
                content='context_doc',
                content_rowid='rowid'
            )
            """)
    }

    private static func createFTSTriggers(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TRIGGER transcript_chunk_ai AFTER INSERT ON transcript_chunk BEGIN
                INSERT INTO transcript_fts(rowid, text)
                VALUES (new.rowid, new.text);
            END
            """)

        try db.execute(sql: """
            CREATE TRIGGER transcript_chunk_ad AFTER DELETE ON transcript_chunk BEGIN
                INSERT INTO transcript_fts(transcript_fts, rowid, text)
                VALUES ('delete', old.rowid, old.text);
            END
            """)

        try db.execute(sql: """
            CREATE TRIGGER transcript_chunk_au AFTER UPDATE ON transcript_chunk BEGIN
                INSERT INTO transcript_fts(transcript_fts, rowid, text)
                VALUES ('delete', old.rowid, old.text);
                INSERT INTO transcript_fts(rowid, text)
                VALUES (new.rowid, new.text);
            END
            """)

        try db.execute(sql: """
            CREATE TRIGGER context_doc_ai AFTER INSERT ON context_doc BEGIN
                INSERT INTO doc_fts(rowid, content, summary)
                VALUES (new.rowid, new.content, new.summary);
            END
            """)

        try db.execute(sql: """
            CREATE TRIGGER context_doc_ad AFTER DELETE ON context_doc BEGIN
                INSERT INTO doc_fts(doc_fts, rowid, content, summary)
                VALUES ('delete', old.rowid, old.content, old.summary);
            END
            """)

        try db.execute(sql: """
            CREATE TRIGGER context_doc_au AFTER UPDATE ON context_doc BEGIN
                INSERT INTO doc_fts(doc_fts, rowid, content, summary)
                VALUES ('delete', old.rowid, old.content, old.summary);
                INSERT INTO doc_fts(rowid, content, summary)
                VALUES (new.rowid, new.content, new.summary);
            END
            """)
    }
}
