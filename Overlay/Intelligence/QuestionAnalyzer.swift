//
//  QuestionAnalyzer.swift
//  OverlayOpus
//

import Foundation

struct QuestionAnalyzer {
    func analyze(question: String, context: [TranscriptChunkRecord]) -> QuestionAnalysis {
        let parts = splitParts(question)
        let assumptions = detectAssumptions(question)
        let traps = detectTraps(question)
        let contradictions = detectContradictions(question: question, context: context)
        let confidence = label(parts: parts,
                               assumptions: assumptions,
                               traps: traps,
                               contradictions: contradictions)
        return QuestionAnalysis(question: question,
                                parts: parts,
                                assumptions: assumptions,
                                traps: traps,
                                contradictions: contradictions,
                                confidence: confidence,
                                recommendedMove: move(confidence: confidence,
                                                      traps: traps,
                                                      contradictions: contradictions))
    }

    private func splitParts(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: "?;"))
            .flatMap { $0.components(separatedBy: " and ") }
            .flatMap { $0.components(separatedBy: " or ") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func detectAssumptions(_ text: String) -> [String] {
        let lower = text.lowercased()
        return [
            "assuming",
            "given that",
            "since you",
            "why did you",
            "isn't it true"
        ].filter { lower.contains($0) }
    }

    private func detectTraps(_ text: String) -> [String] {
        let lower = text.lowercased()
        return [
            "always",
            "never",
            "obviously",
            "admit",
            "failed",
            "can't you just"
        ].filter { lower.contains($0) }
    }

    private func detectContradictions(question: String, context: [TranscriptChunkRecord]) -> [String] {
        let lower = question.lowercased()
        let recent = context.suffix(12).map { $0.text.lowercased() }.joined(separator: " ")
        let pairs = [
            ("increase", "decrease"),
            ("higher", "lower"),
            ("faster", "slower"),
            ("approved", "rejected"),
            ("yes", "no")
        ]

        return pairs.compactMap { first, second in
            let conflictsWithRecentContext =
                (lower.contains(first) && recent.contains(second)) ||
                (lower.contains(second) && recent.contains(first))

            guard conflictsWithRecentContext else {
                return nil
            }
            return "\(first)/\(second)"
        }
    }

    private func label(parts: [String],
                       assumptions: [String],
                       traps: [String],
                       contradictions: [String]) -> ConfidenceLabel {
        if !contradictions.isEmpty { return .askClarifier }
        if !traps.isEmpty { return .askClarifier }
        if !assumptions.isEmpty { return .uncertain }
        if parts.count > 2 { return .uncertain }
        return .strong
    }

    private func move(confidence: ConfidenceLabel,
                      traps: [String],
                      contradictions: [String]) -> RecommendedMove {
        if !contradictions.isEmpty { return .clarify }
        if !traps.isEmpty { return .challengePremise }

        switch confidence {
        case .strong:
            return .answerDirectly
        case .uncertain:
            return .citeSource
        case .askClarifier:
            return .clarify
        case .needsSource:
            return .deferAnswer
        }
    }
}
