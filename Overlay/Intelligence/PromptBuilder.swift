//
//  PromptBuilder.swift
//  OverlayOpus
//

import Foundation

struct PromptBuilder {

    func buildRequest(brief: String,
                      question: String,
                      analysis: QuestionAnalysis?,
                      grounding: [GroundingSnippet],
                      memoryItems: [MemoryItemRecord],
                      answerMode: AnswerMode,
                      tone: AnswerTone,
                      contextDocs: [ContextDocRecord],
                      transcriptTail: [TranscriptChunkRecord],
                      modelID: String) -> LLMRequest {
        let systemPrompt = """
        You are Overlay-Opus, a private local meeting copilot. Return concise live-call help. Use this format:
        NEXT: one sentence
        ANSWER:
        - bullet
        - bullet
        CAVEAT: one sentence or "none"
        CONFIDENCE: strong|uncertain|askClarifier|needsSource
        CITATIONS: cite only provided source labels, or "none"
        Do not invent facts. If sources are weak, say what is missing.
        """

        let context = contextDocs.prefix(6).map { doc in
            let title = doc.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = doc.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = summary?.isEmpty == false ? (summary ?? "") : String(doc.text.prefix(800))
            return "- \(title): \(body)"
        }.joined(separator: "\n")

        let transcript = transcriptTail.suffix(16)
            .map { $0.text }
            .joined(separator: "\n")

        let sourceList = grounding.enumerated().map { index, snippet in
            let label = "S\(index + 1)"
            return "\(label) [\(snippet.sourceKind.rawValue)] \(snippet.title): \(snippet.excerpt)"
        }.joined(separator: "\n")

        let memory = memoryItems.prefix(8)
            .map { "- \($0.kind.rawValue): \($0.text)" }
            .joined(separator: "\n")

        let analysisText: String
        if let analysis {
            analysisText = """
            Parts: \(analysis.parts.joined(separator: " | "))
            Assumptions: \(analysis.assumptions.isEmpty ? "none" : analysis.assumptions.joined(separator: ", "))
            Traps: \(analysis.traps.isEmpty ? "none" : analysis.traps.joined(separator: ", "))
            Contradictions: \(analysis.contradictions.isEmpty ? "none" : analysis.contradictions.joined(separator: ", "))
            Recommended move: \(analysis.recommendedMove.rawValue)
            Confidence: \(analysis.confidence.rawValue)
            """
        } else {
            analysisText = "No local analysis available."
        }

        let userPrompt = """
        Answer mode: \(answerMode.rawValue)
        Tone: \(tone.rawValue)

        Meeting brief:
        \(brief.isEmpty ? "No brief provided." : brief)

        Relevant documents:
        \(context.isEmpty ? "No document context available." : context)

        Recent transcript:
        \(transcript.isEmpty ? "No transcript yet." : transcript)

        Local question analysis:
        \(analysisText)

        Conversation memory:
        \(memory.isEmpty ? "No memory items yet." : memory)

        Provided source labels:
        \(sourceList.isEmpty ? "No sources available." : sourceList)

        Question:
        \(question)

        Draft a useful answer in under 160 words. Cite only source labels from the provided source list.
        """

        return LLMRequest(systemPrompt: systemPrompt,
                          userPrompt: userPrompt,
                          modelID: modelID,
                          temperature: 0.3,
                          maxTokens: 500)
    }
}
