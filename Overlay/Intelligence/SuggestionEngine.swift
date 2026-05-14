//
//  SuggestionEngine.swift
//  OverlayOpus
//

import Combine
import Foundation

actor SuggestionEngine {

    enum Trigger {
        case detected(DetectedQuestion)
        case manual(String)
        case hotkey(String)

        var questionText: String {
            switch self {
            case .detected(let question): return question.text
            case .manual(let text), .hotkey(let text): return text
            }
        }
    }

    nonisolated let updates = PassthroughSubject<SuggestionUpdate, Never>()

    private let promptBuilder = PromptBuilder()
    private var lastTriggers: [Trigger] = []
    private var activeTask: Task<Void, Never>?

    func suggest(trigger: Trigger,
                 sessionID: String,
                 brief: String,
                 providerID: String,
                 modelID: String,
                 contextDocs: [ContextDocRecord],
                 transcriptTail: [TranscriptChunkRecord]) {
        lastTriggers.append(trigger)
        if lastTriggers.count > 5 {
            lastTriggers.removeFirst(lastTriggers.count - 5)
        }

        activeTask?.cancel()
        activeTask = Task {
            await runSuggestion(trigger: trigger,
                                sessionID: sessionID,
                                brief: brief,
                                providerID: providerID,
                                modelID: modelID,
                                contextDocs: contextDocs,
                                transcriptTail: transcriptTail)
        }
    }

    func regenerateLast(sessionID: String,
                        brief: String,
                        providerID: String,
                        modelID: String,
                        contextDocs: [ContextDocRecord],
                        transcriptTail: [TranscriptChunkRecord]) {
        guard let last = lastTriggers.last else { return }
        suggest(trigger: last,
                sessionID: sessionID,
                brief: brief,
                providerID: providerID,
                modelID: modelID,
                contextDocs: contextDocs,
                transcriptTail: transcriptTail)
    }

    func stop() {
        activeTask?.cancel()
        activeTask = nil
    }

    private func runSuggestion(trigger: Trigger,
                               sessionID: String,
                               brief: String,
                               providerID: String,
                               modelID: String,
                               contextDocs: [ContextDocRecord],
                               transcriptTail: [TranscriptChunkRecord]) async {
        let suggestionID = UUID().uuidString
        let started = Date()
        let kind: SuggestionKind
        switch trigger {
        case .detected: kind = .auto
        case .manual: kind = .manual
        case .hotkey: kind = .hotkey
        }
        let request = promptBuilder.buildRequest(brief: brief,
                                                 question: trigger.questionText,
                                                 contextDocs: contextDocs,
                                                 transcriptTail: transcriptTail,
                                                 modelID: modelID)
        var accumulated = ""

        do {
            let provider = try await ProviderRegistry.shared.provider(id: providerID)
            updates.send(SuggestionUpdate(id: suggestionID,
                                          sessionID: sessionID,
                                          ts: Date.unixMilliseconds,
                                          kind: kind,
                                          prompt: trigger.questionText,
                                          text: "",
                                          isFinal: false,
                                          errorMessage: nil))

            for try await event in provider.stream(request) {
                try Task.checkCancellation()
                switch event {
                case .token(let token):
                    accumulated += token
                    updates.send(SuggestionUpdate(id: suggestionID,
                                                  sessionID: sessionID,
                                                  ts: Date.unixMilliseconds,
                                                  kind: kind,
                                                  prompt: trigger.questionText,
                                                  text: accumulated,
                                                  isFinal: false,
                                                  errorMessage: nil))
                case .done:
                    break
                case .error(let error):
                    throw error
                }
            }

            let record = SuggestionRecord(id: suggestionID,
                                          sessionID: sessionID,
                                          ts: Date.unixMilliseconds,
                                          kind: kind,
                                          prompt: trigger.questionText,
                                          content: accumulated,
                                          model: modelID,
                                          latencyMS: Int64(Date().timeIntervalSince(started) * 1000))
            try await AppDatabase.shared.insertSuggestion(record)
            updates.send(SuggestionUpdate(id: suggestionID,
                                          sessionID: sessionID,
                                          ts: Date.unixMilliseconds,
                                          kind: kind,
                                          prompt: trigger.questionText,
                                          text: accumulated,
                                          isFinal: true,
                                          errorMessage: nil))
        } catch is CancellationError {
            return
        } catch {
            updates.send(SuggestionUpdate(id: suggestionID,
                                          sessionID: sessionID,
                                          ts: Date.unixMilliseconds,
                                          kind: kind,
                                          prompt: trigger.questionText,
                                          text: accumulated,
                                          isFinal: true,
                                          errorMessage: error.localizedDescription))
        }
    }
}
