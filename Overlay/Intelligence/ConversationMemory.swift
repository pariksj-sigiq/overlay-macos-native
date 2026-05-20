//
//  ConversationMemory.swift
//  OverlayOpus
//

import Foundation

actor ConversationMemory {
    private var seen = Set<String>()

    func reset() {
        seen.removeAll()
    }

    func extract(from chunk: TranscriptChunkRecord) -> [MemoryItemPayload] {
        let text = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        var items: [MemoryItemPayload] = []
        let lower = text.lowercased()

        if lower.contains("my name is ") || lower.contains("i'm ") {
            items.append(MemoryItemPayload(kind: .name, text: text, sourceTranscriptID: chunk.id))
        }
        if lower.contains("we decided") || lower.contains("decision") {
            items.append(MemoryItemPayload(kind: .decision, text: text, sourceTranscriptID: chunk.id))
        }
        if lower.contains("i disagree") || lower.contains("concern") || lower.contains("objection") {
            items.append(MemoryItemPayload(kind: .objection, text: text, sourceTranscriptID: chunk.id))
        }
        if lower.contains("follow up") || lower.contains("open question") || lower.contains("circle back") {
            items.append(MemoryItemPayload(kind: .openLoop, text: text, sourceTranscriptID: chunk.id))
        }
        if lower.contains("we believe") || lower.contains("the claim") || lower.contains("because") {
            items.append(MemoryItemPayload(kind: .claim, text: text, sourceTranscriptID: chunk.id))
        }

        return items.filter { seen.insert("\($0.kind.rawValue):\($0.text)").inserted }
    }
}
