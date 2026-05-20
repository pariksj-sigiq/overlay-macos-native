//
//  GroundingEngine.swift
//  OverlayOpus
//

import Foundation

struct GroundingEngine {
    func snippets(question: String,
                  brief: String,
                  contextDocs: [ContextDocRecord],
                  transcriptTail: [TranscriptChunkRecord],
                  memoryItems: [MemoryItemRecord]) -> [GroundingSnippet] {
        let terms = Set(question.lowercased()
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count > 3 })
        var snippets: [GroundingSnippet] = []

        if !brief.isEmpty {
            snippets.append(GroundingSnippet(sourceKind: .brief,
                                             title: "Brief",
                                             excerpt: String(brief.prefix(500)),
                                             rowID: nil))
        }

        snippets += contextDocs.prefix(5).map {
            GroundingSnippet(sourceKind: .document,
                             title: $0.title,
                             excerpt: bestExcerpt(in: $0.text, terms: terms),
                             rowID: $0.id)
        }

        snippets += transcriptTail.suffix(8).map {
            GroundingSnippet(sourceKind: .transcript,
                             title: "Transcript",
                             excerpt: $0.text,
                             rowID: $0.id)
        }

        snippets += memoryItems.prefix(8).map {
            GroundingSnippet(sourceKind: .memory,
                             title: $0.kind.rawValue,
                             excerpt: $0.text,
                             rowID: $0.id)
        }

        return Array(snippets.prefix(8))
    }

    private func bestExcerpt(in text: String, terms: Set<String>) -> String {
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".?!\n"))
        let best = sentences.max { lhs, rhs in score(lhs, terms: terms) < score(rhs, terms: terms) }
        return String((best ?? text).trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
    }

    private func score(_ text: String, terms: Set<String>) -> Int {
        let lower = text.lowercased()
        return terms.reduce(0) { $0 + (lower.contains($1) ? 1 : 0) }
    }
}
