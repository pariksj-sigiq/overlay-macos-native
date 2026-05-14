//
//  PromptBuilder.swift
//  OverlayOpus
//

import Foundation

struct PromptBuilder {

    func buildRequest(brief: String,
                      question: String,
                      contextDocs: [ContextDocRecord],
                      transcriptTail: [TranscriptChunkRecord],
                      modelID: String) -> LLMRequest {
        let systemPrompt = """
        You are Overlay-Opus, a private local meeting copilot. Help the user answer live call questions with concise, accurate, source-aware guidance. Do not invent facts. If the documents do not contain enough context, say what is missing and give a safe answer.
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

        let userPrompt = """
        Meeting brief:
        \(brief.isEmpty ? "No brief provided." : brief)

        Relevant documents:
        \(context.isEmpty ? "No document context available." : context)

        Recent transcript:
        \(transcript.isEmpty ? "No transcript yet." : transcript)

        Question:
        \(question)

        Draft a useful answer in under 160 words. Include bullets only when they improve clarity.
        """

        return LLMRequest(systemPrompt: systemPrompt,
                          userPrompt: userPrompt,
                          modelID: modelID,
                          temperature: 0.3,
                          maxTokens: 500)
    }
}
