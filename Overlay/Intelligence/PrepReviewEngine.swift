//
//  PrepReviewEngine.swift
//  OverlayOpus
//

import Foundation

actor PrepReviewEngine {

    func makePrep(sessionID: String,
                  brief: String,
                  docs: [ContextDocRecord],
                  providerID: String?,
                  modelID: String?,
                  privacyMode: PrivacyMode) async throws -> SessionArtifactRecord {
        let content: String
        if privacyMode == .localOnly || providerID == nil || modelID == nil {
            content = localPrepContent(brief: brief, docs: docs)
        } else {
            content = try await providerContent(providerID: providerID,
                                                modelID: modelID,
                                                systemPrompt: "You prepare compact meeting prep notes. Use only the supplied brief and document excerpts.",
                                                userPrompt: prepPrompt(brief: brief, docs: docs),
                                                fallback: localPrepContent(brief: brief, docs: docs))
        }

        let record = SessionArtifactRecord(id: UUID().uuidString,
                                           sessionID: sessionID,
                                           ts: Date.unixMilliseconds,
                                           kind: "prep",
                                           title: "Prep",
                                           content: content,
                                           payloadJSON: nil)
        return try await AppDatabase.shared.insertSessionArtifact(record)
    }

    func makeReview(session: CallSessionRecord,
                    transcript: [TranscriptChunkRecord],
                    suggestions: [SuggestionRecord],
                    providerID: String?,
                    modelID: String?,
                    privacyMode: PrivacyMode) async throws -> SessionArtifactRecord {
        let content: String
        if privacyMode == .localOnly || providerID == nil || modelID == nil {
            content = localReviewContent(session: session,
                                         transcript: transcript,
                                         suggestions: suggestions)
        } else {
            content = try await providerContent(providerID: providerID,
                                                modelID: modelID,
                                                systemPrompt: "You write concise post-call review notes for the speaker. Be practical and specific.",
                                                userPrompt: reviewPrompt(session: session,
                                                                         transcript: transcript,
                                                                         suggestions: suggestions),
                                                fallback: localReviewContent(session: session,
                                                                             transcript: transcript,
                                                                             suggestions: suggestions))
        }

        let record = SessionArtifactRecord(id: UUID().uuidString,
                                           sessionID: session.id,
                                           ts: Date.unixMilliseconds,
                                           kind: "review",
                                           title: "Post-call review",
                                           content: content,
                                           payloadJSON: nil)
        return try await AppDatabase.shared.insertSessionArtifact(record)
    }

    private func providerContent(providerID: String?,
                                 modelID: String?,
                                 systemPrompt: String,
                                 userPrompt: String,
                                 fallback: String) async throws -> String {
        guard let providerID,
              let modelID else {
            return fallback
        }

        let provider = try await ProviderRegistry.shared.provider(id: providerID)
        let request = LLMRequest(systemPrompt: systemPrompt,
                                 userPrompt: userPrompt,
                                 modelID: modelID,
                                 temperature: 0.2,
                                 maxTokens: 700)
        var output = ""

        for try await event in provider.stream(request) {
            switch event {
            case .token(let token):
                output += token
            case .done:
                break
            case .error(let error):
                throw error
            }
        }

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func localPrepContent(brief: String, docs: [ContextDocRecord]) -> String {
        let briefLine = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceLine = docs.isEmpty
            ? "No attached documents yet."
            : "Available sources: " + docs.prefix(4).map(\.title).joined(separator: ", ")

        return """
        Likely questions:
        - What is the main decision needed?
        - What evidence supports the recommendation?
        - What risks or tradeoffs should be named?

        Answer bullets:
        - State the goal.
        - Cite the strongest available source.
        - Name uncertainty directly.

        Local context:
        - \(briefLine.isEmpty ? "No brief entered yet." : briefLine)
        - \(sourceLine)
        """
    }

    private func localReviewContent(session: CallSessionRecord,
                                    transcript: [TranscriptChunkRecord],
                                    suggestions: [SuggestionRecord]) -> String {
        let questionCount = transcript.filter { $0.text.contains("?") }.count
        let suggestionCount = suggestions.count
        return """
        Missed questions:
        - Revisit unclear asks from the transcript, especially where no source was cited.
        - Check whether any of the \(questionCount) question-like moments still need a follow-up.

        Better answers:
        - Ground responses in the brief and attached sources.
        - Name caveats early when confidence is low.
        - Use generated suggestions as drafts, not final wording. Suggestions captured: \(suggestionCount).

        Follow-ups:
        - Send decisions, objections, and open loops to attendees.
        - Turn unresolved questions from \(session.title) into explicit next steps.
        """
    }

    private func prepPrompt(brief: String, docs: [ContextDocRecord]) -> String {
        let docText = docs.prefix(5)
            .map { doc in
                let excerpt = String(doc.text.prefix(1_200))
                return "DOC: \(doc.title)\n\(excerpt)"
            }
            .joined(separator: "\n\n")

        return """
        Create meeting prep in exactly these sections:
        Likely questions:
        - ...

        Answer bullets:
        - ...

        Caveats:
        - ...

        Brief:
        \(brief)

        Documents:
        \(docText.isEmpty ? "None" : docText)
        """
    }

    private func reviewPrompt(session: CallSessionRecord,
                              transcript: [TranscriptChunkRecord],
                              suggestions: [SuggestionRecord]) -> String {
        let transcriptText = transcript.suffix(40)
            .map { "\($0.speaker.rawValue): \($0.text)" }
            .joined(separator: "\n")
        let suggestionText = suggestions.suffix(12)
            .map { "Q: \($0.prompt)\nA: \(String($0.content.prefix(600)))" }
            .joined(separator: "\n\n")

        return """
        Review this call in exactly these sections:
        Missed questions:
        - ...

        Better answers:
        - ...

        Follow-ups:
        - ...

        Session: \(session.title)
        Brief:
        \(session.brief)

        Transcript tail:
        \(transcriptText.isEmpty ? "No transcript captured." : transcriptText)

        Suggestions used:
        \(suggestionText.isEmpty ? "None" : suggestionText)
        """
    }
}
