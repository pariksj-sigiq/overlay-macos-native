//
//  IntelligenceModels.swift
//  OverlayOpus
//

import Foundation

enum ConfidenceLabel: String, Codable, CaseIterable, Identifiable {
    case strong
    case uncertain
    case askClarifier
    case needsSource

    var id: String { rawValue }
}

enum AnswerMode: String, Codable, CaseIterable, Identifiable {
    case concise
    case firstPrinciples
    case framework
    case steelman
    case caveats

    var id: String { rawValue }
}

enum AnswerTone: String, Codable, CaseIterable, Identifiable {
    case direct
    case socratic
    case diplomatic
    case technical
    case executive

    var id: String { rawValue }
}

enum PrivacyMode: String, Codable, CaseIterable, Identifiable {
    case localOnly
    case providerAssisted

    var id: String { rawValue }
}

enum RecommendedMove: String, Codable {
    case answerDirectly
    case clarify
    case challengePremise
    case citeSource
    case deferAnswer = "defer"
}

struct QuestionAnalysis: Codable, Equatable {
    var question: String
    var parts: [String]
    var assumptions: [String]
    var traps: [String]
    var contradictions: [String]
    var confidence: ConfidenceLabel
    var recommendedMove: RecommendedMove
}

enum MemoryKind: String, Codable, CaseIterable {
    case name
    case claim
    case decision
    case objection
    case openLoop
}

struct MemoryItemPayload: Codable, Equatable {
    var kind: MemoryKind
    var text: String
    var sourceTranscriptID: String?
}

enum GroundingSourceKind: String, Codable {
    case brief
    case document
    case transcript
    case memory
}

struct GroundingSnippet: Codable, Equatable, Identifiable {
    var id: String
    var sourceKind: GroundingSourceKind
    var title: String
    var excerpt: String
    var rowID: String?

    init(id: String = UUID().uuidString,
         sourceKind: GroundingSourceKind,
         title: String,
         excerpt: String,
         rowID: String? = nil) {
        self.id = id
        self.sourceKind = sourceKind
        self.title = title
        self.excerpt = excerpt
        self.rowID = rowID
    }
}

struct SuggestionCard: Codable, Equatable {
    var nextThought: String
    var answerBullets: [String]
    var caveat: String?
    var citations: [GroundingSnippet]
    var confidence: ConfidenceLabel
}
