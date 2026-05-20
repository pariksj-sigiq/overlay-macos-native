//
//  Models.swift
//  OverlayOpus
//

import Foundation
import GRDB

enum CallSessionStatus: String, Codable, CaseIterable {
    case draft
    case live
    case ended
}

enum ContextDocKind: String, Codable, CaseIterable {
    case pdf
    case docx
    case md
    case txt
    case note
}

enum TranscriptSpeaker: String, Codable, CaseIterable {
    case them
    case me
    case unknown
}

enum SuggestionKind: String, Codable, CaseIterable {
    case auto
    case manual
    case hotkey
}

enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case azureOpenAI
    case bedrock
    case lmStudio
    case ollama
    case openAI

    var id: String { rawValue }

    var label: String {
        switch self {
        case .azureOpenAI: return "Azure OpenAI"
        case .bedrock: return "AWS Bedrock"
        case .lmStudio: return "LM Studio"
        case .ollama: return "Ollama"
        case .openAI: return "OpenAI"
        }
    }
}

struct CallSessionRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "call_session"

    var id: String
    var title: String
    var scheduledAt: Int64?
    var brief: String
    var status: CallSessionStatus
    var providerID: String?
    var modelID: String?
    var createdAt: Int64
    var endedAt: Int64?

    enum Columns {
        static let id = Column("id")
        static let title = Column("title")
        static let scheduledAt = Column("scheduled_at")
        static let brief = Column("brief")
        static let status = Column("status")
        static let providerID = Column("provider_id")
        static let modelID = Column("model_id")
        static let createdAt = Column("created_at")
        static let endedAt = Column("ended_at")
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case scheduledAt = "scheduled_at"
        case brief
        case status
        case providerID = "provider_id"
        case modelID = "model_id"
        case createdAt = "created_at"
        case endedAt = "ended_at"
    }

    init(id: String = UUID().uuidString,
         title: String,
         scheduledAt: Int64? = nil,
         brief: String = "",
         status: CallSessionStatus = .draft,
         providerID: String? = nil,
         modelID: String? = nil,
         createdAt: Int64 = Date.unixSeconds,
         endedAt: Int64? = nil) {
        self.id = id
        self.title = title
        self.scheduledAt = scheduledAt
        self.brief = brief
        self.status = status
        self.providerID = providerID
        self.modelID = modelID
        self.createdAt = createdAt
        self.endedAt = endedAt
    }
}

struct ContextDocRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "context_doc"

    var id: String
    var sessionID: String
    var kind: ContextDocKind
    var filename: String?
    var content: String
    var summary: String?
    var addedAt: Int64

    enum Columns {
        static let id = Column("id")
        static let sessionID = Column("session_id")
        static let kind = Column("kind")
        static let filename = Column("filename")
        static let content = Column("content")
        static let summary = Column("summary")
        static let addedAt = Column("added_at")
    }

    enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case kind
        case filename
        case content
        case summary
        case addedAt = "added_at"
    }

    init(id: String = UUID().uuidString,
         sessionID: String,
         kind: ContextDocKind,
         filename: String?,
         content: String,
         summary: String? = nil,
         addedAt: Int64 = Date.unixSeconds) {
        self.id = id
        self.sessionID = sessionID
        self.kind = kind
        self.filename = filename
        self.content = content
        self.summary = summary
        self.addedAt = addedAt
    }

    var title: String { filename ?? kind.rawValue.uppercased() }
    var text: String { content }
}

struct TranscriptChunkRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "transcript_chunk"

    var id: String
    var sessionID: String
    var ts: Int64
    var speaker: TranscriptSpeaker
    var text: String
    var source: String

    enum Columns {
        static let id = Column("id")
        static let sessionID = Column("session_id")
        static let ts = Column("ts")
        static let speaker = Column("speaker")
        static let text = Column("text")
        static let source = Column("source")
    }

    enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case ts
        case speaker
        case text
        case source
    }

    init(id: String = UUID().uuidString,
         sessionID: String,
         ts: Int64 = Date.unixMilliseconds,
         speaker: TranscriptSpeaker = .them,
         text: String,
         source: String = "whisper") {
        self.id = id
        self.sessionID = sessionID
        self.ts = ts
        self.speaker = speaker
        self.text = text
        self.source = source
    }
}

struct SuggestionRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "suggestion"

    var id: String
    var sessionID: String
    var ts: Int64
    var kind: SuggestionKind
    var prompt: String
    var content: String
    var model: String?
    var latencyMS: Int64?

    enum Columns {
        static let id = Column("id")
        static let sessionID = Column("session_id")
        static let ts = Column("ts")
        static let kind = Column("kind")
        static let prompt = Column("prompt")
        static let content = Column("content")
        static let model = Column("model")
        static let latencyMS = Column("latency_ms")
    }

    enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case ts
        case kind
        case prompt
        case content
        case model
        case latencyMS = "latency_ms"
    }
}

struct ProviderConfigRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "provider_config"

    var id: String
    var kind: ProviderKind
    var name: String
    var configJSON: Data
    var createdAt: Int64

    enum Columns {
        static let id = Column("id")
        static let kind = Column("kind")
        static let name = Column("name")
        static let configJSON = Column("config_json")
        static let createdAt = Column("created_at")
    }

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case name
        case configJSON = "config_json"
        case createdAt = "created_at"
    }

    init(id: String = UUID().uuidString,
         kind: ProviderKind,
         name: String,
         configJSON: Data,
         createdAt: Int64 = Date.unixSeconds) {
        self.id = id
        self.kind = kind
        self.name = name
        self.configJSON = configJSON
        self.createdAt = createdAt
    }
}

struct DetectedQuestion: Identifiable, Equatable {
    var id: String
    var sessionID: String?
    var text: String
    var context: String
    var confidence: Double
    var ts: Int64

    init(id: String = UUID().uuidString,
         sessionID: String?,
         text: String,
         context: String,
         confidence: Double,
         ts: Int64 = Date.unixMilliseconds) {
        self.id = id
        self.sessionID = sessionID
        self.text = text
        self.context = context
        self.confidence = confidence
        self.ts = ts
    }
}

struct SuggestionUpdate: Identifiable, Equatable {
    var id: String
    var sessionID: String
    var ts: Int64
    var kind: SuggestionKind
    var prompt: String
    var text: String
    var isFinal: Bool
    var errorMessage: String?
}

enum SearchHistoryKind: String, Codable {
    case transcript
    case document
}

struct SearchHistoryResult: Codable, Equatable, Hashable, Identifiable {
    var id: String
    var kind: SearchHistoryKind
    var sessionID: String
    var title: String
    var snippet: String
    var createdAt: Int64
}

typealias CallSession = CallSessionRecord
typealias ContextDoc = ContextDocRecord
typealias TranscriptChunk = TranscriptChunkRecord
typealias Suggestion = SuggestionRecord
typealias ProviderConfig = ProviderConfigRecord

extension Date {
    static var unixSeconds: Int64 {
        Int64(Date().timeIntervalSince1970)
    }

    static var unixMilliseconds: Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    var unixSeconds: Int64 {
        Int64(timeIntervalSince1970)
    }

    var unixMilliseconds: Int64 {
        Int64(timeIntervalSince1970 * 1000)
    }
}
