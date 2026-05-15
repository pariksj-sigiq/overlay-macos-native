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

        let context = rankedDocuments(contextDocs, for: question).prefix(3).map { doc in
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

    private func rankedDocuments(_ docs: [ContextDocRecord], for question: String) -> [ContextDocRecord] {
        let terms = searchTerms(from: question)
        guard !terms.isEmpty else { return docs }

        return docs.enumerated()
            .map { index, doc in
                (doc: doc, score: relevanceScore(doc, terms: terms), index: index)
            }
            .sorted {
                if $0.score == $1.score {
                    return $0.index < $1.index
                }
                return $0.score > $1.score
            }
            .map(\.doc)
    }

    private func relevanceScore(_ doc: ContextDocRecord, terms: Set<String>) -> Int {
        let haystack = [
            doc.title,
            doc.summary ?? "",
            String(doc.text.prefix(2_000))
        ].joined(separator: " ").lowercased()

        return terms.reduce(0) { score, term in
            score + (haystack.contains(term) ? 1 : 0)
        }
    }

    private func searchTerms(from text: String) -> Set<String> {
        let stopwords: Set<String> = [
            "about", "after", "again", "also", "because", "could", "from",
            "have", "into", "that", "their", "them", "then", "there", "they",
            "this", "what", "when", "where", "which", "with", "would", "your"
        ]

        return Set(text
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 4 && !stopwords.contains($0) })
    }
}
