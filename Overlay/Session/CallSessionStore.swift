//
//  CallSessionStore.swift
//  OverlayOpus
//

import Combine
import CoreGraphics
import Foundation

@MainActor
final class CallSessionStore: ObservableObject {

    static let shared = CallSessionStore()

    @Published private(set) var activeSession: CallSessionRecord?
    @Published private(set) var transcript: [TranscriptChunkRecord] = []
    @Published private(set) var questionAnalyses: [QuestionAnalysis] = []
    @Published private(set) var memoryItems: [MemoryItemRecord] = []
    @Published private(set) var suggestions: [SuggestionUpdate] = []
    @Published private(set) var prepArtifacts: [SessionArtifactRecord] = []
    @Published private(set) var reviewArtifacts: [SessionArtifactRecord] = []
    @Published private(set) var isRecording = false
    @Published private(set) var status = "Idle"
    @Published var errorMessage: String?

    private let audioCapturer = SystemAudioCapturer()
    private let whisperEngine = WhisperEngine()
    private let questionDetector = QuestionDetector()
    private let questionAnalyzer = QuestionAnalyzer()
    private let conversationMemory = ConversationMemory()
    private let groundingEngine = GroundingEngine()
    private let suggestionEngine = SuggestionEngine()
    private let prepReviewEngine = PrepReviewEngine()
    private let documentIngestor = DocumentIngestor.shared

    private var cancellables = Set<AnyCancellable>()
    private var audioTask: Task<Void, Never>?
    private var providerID: String?
    private var modelID: String?
    private var brief = ""
    private var contextDocs: [ContextDocRecord] = []

    private init() {
        bindPipelines()
    }

    func startCall(title: String,
                   brief: String,
                   providerID: String,
                   modelID: String,
                   documents: [URL] = []) {
        Task {
            await startCallAsync(title: title,
                                 brief: brief,
                                 providerID: providerID,
                                 modelID: modelID,
                                 documents: documents)
        }
    }

    func setExcludedWindowIDs(_ ids: [CGWindowID]) {
        Task {
            await audioCapturer.setExcludedWindows(ids)
        }
    }

    func stopCall() {
        Task {
            await stopCallAsync()
        }
    }

    func toggleRecording() {
        guard activeSession != nil else { return }
        if isRecording {
            Task { await stopRecording() }
        } else {
            Task { await startRecording() }
        }
    }

    func manualAsk(_ question: String) {
        guard let session = activeSession,
              let providerID,
              let modelID else {
            return
        }

        Task {
            await suggest(trigger: .manual(question),
                          sessionID: session.id,
                          providerID: providerID,
                          modelID: modelID)
        }
    }

    func regenerateLast() {
        guard let session = activeSession,
              let providerID,
              let modelID else {
            return
        }

        Task {
            await suggestionEngine.regenerateLast(sessionID: session.id,
                                                  brief: brief,
                                                  providerID: providerID,
                                                  modelID: modelID,
                                                  analysis: questionAnalyses.last,
                                                  grounding: groundingEngine.snippets(question: transcript.last?.text ?? "",
                                                                                     brief: brief,
                                                                                     contextDocs: contextDocs,
                                                                                     transcriptTail: transcript,
                                                                                     memoryItems: memoryItems),
                                                  memoryItems: memoryItems,
                                                  answerMode: answerMode,
                                                  tone: answerTone,
                                                  contextDocs: contextDocs,
                                                  transcriptTail: transcript)
        }
    }

    func recordPrivacyModeChange(_ rawValue: String) {
        audit("privacy_mode_change", detail: rawValue)
    }

    func generatePrep() {
        guard let session = activeSession else { return }

        Task {
            do {
                let artifact = try await prepReviewEngine.makePrep(sessionID: session.id,
                                                                    brief: brief,
                                                                    docs: contextDocs,
                                                                    providerID: providerID,
                                                                    modelID: modelID,
                                                                    privacyMode: privacyMode)
                prepArtifacts.insert(artifact, at: 0)
                audit("prep_generated", detail: artifact.id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func generateReview(for sessionID: String? = nil) {
        Task {
            do {
                _ = try await makeReviewArtifact(for: sessionID)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func makeReviewArtifact(for sessionID: String? = nil) async throws -> SessionArtifactRecord {
        let session: CallSessionRecord
        if let activeSession, sessionID == nil || sessionID == activeSession.id {
            session = activeSession
        } else if let sessionID, let stored = try await AppDatabase.shared.fetchSession(id: sessionID) {
            session = stored
        } else {
            throw LLMProviderError.invalidConfiguration("No call session selected for review")
        }

        let transcriptRows = session.id == activeSession?.id
            ? transcript
            : try await AppDatabase.shared.transcriptChunks(sessionID: session.id)
        let suggestionRows = try await AppDatabase.shared.suggestions(sessionID: session.id)
        let artifact = try await prepReviewEngine.makeReview(session: session,
                                                              transcript: transcriptRows,
                                                              suggestions: suggestionRows,
                                                              providerID: session.providerID ?? providerID,
                                                              modelID: session.modelID ?? modelID,
                                                              privacyMode: privacyMode)
        reviewArtifacts.insert(artifact, at: 0)
        audit("review_generated", detail: artifact.id)
        return artifact
    }

    func reviewArtifacts(for sessionID: String) async throws -> [SessionArtifactRecord] {
        try await AppDatabase.shared.sessionArtifacts(sessionID: sessionID, kind: "review")
    }

    func ingestDocument(url: URL) {
        guard let providerID, let modelID else { return }
        let sessionID = activeSession?.id

        Task {
            do {
                let record = try await documentIngestor.ingest(url: url,
                                                               sessionID: sessionID,
                                                               providerID: providerID,
                                                               modelID: modelID)
                contextDocs.append(record)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Binding

    private func bindPipelines() {
        questionDetector.bind(to: whisperEngine.transcriptPublisher)

        whisperEngine.transcriptPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] chunk in
                guard let self else { return }
                self.transcript.append(chunk)
                self.processLocalIntelligence(for: chunk)
                Task {
                    try? await AppDatabase.shared.insertTranscriptChunk(chunk)
                }
            }
            .store(in: &cancellables)

        questionDetector.questionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] question in
                guard let self,
                      let session = self.activeSession,
                      let providerID = self.providerID,
                      let modelID = self.modelID else {
                    return
                }
                Task {
                    await self.suggest(trigger: .detected(question),
                                       sessionID: session.id,
                                       providerID: providerID,
                                       modelID: modelID)
                }
            }
            .store(in: &cancellables)

        suggestionEngine.updates
            .receive(on: DispatchQueue.main)
            .sink { [weak self] update in
                guard let self else { return }
                if let index = self.suggestions.firstIndex(where: { $0.id == update.id }) {
                    self.suggestions[index] = update
                } else {
                    self.suggestions.append(update)
                }
            }
            .store(in: &cancellables)
    }

    private var answerMode: AnswerMode {
        AnswerMode(rawValue: UserDefaults.standard.string(forKey: "overlay.answerMode") ?? "") ?? .concise
    }

    private var answerTone: AnswerTone {
        AnswerTone(rawValue: UserDefaults.standard.string(forKey: "overlay.answerTone") ?? "") ?? .direct
    }

    private var privacyMode: PrivacyMode {
        PrivacyMode(rawValue: UserDefaults.standard.string(forKey: "overlay.privacyMode") ?? "") ?? .providerAssisted
    }

    private func suggest(trigger: SuggestionEngine.Trigger,
                         sessionID: String,
                         providerID: String,
                         modelID: String) async {
        let question = trigger.questionText
        let analysis = questionAnalyses.last { $0.question == question } ??
            questionAnalyzer.analyze(question: question, context: transcript)
        let grounding = groundingEngine.snippets(question: question,
                                                 brief: brief,
                                                 contextDocs: contextDocs,
                                                 transcriptTail: transcript,
                                                 memoryItems: memoryItems)

        if privacyMode == .localOnly {
            publishLocalSuggestion(trigger: trigger,
                                   sessionID: sessionID,
                                   analysis: analysis,
                                   grounding: grounding)
            audit("provider_request_blocked", detail: "localOnly")
            return
        }

        audit("provider_request_started", detail: trigger.questionText)
        await suggestionEngine.suggest(trigger: trigger,
                                       sessionID: sessionID,
                                       brief: brief,
                                       providerID: providerID,
                                       modelID: modelID,
                                       analysis: analysis,
                                       grounding: grounding,
                                       memoryItems: memoryItems,
                                       answerMode: answerMode,
                                       tone: answerTone,
                                       contextDocs: contextDocs,
                                       transcriptTail: transcript)
    }

    private func publishLocalSuggestion(trigger: SuggestionEngine.Trigger,
                                        sessionID: String,
                                        analysis: QuestionAnalysis,
                                        grounding: [GroundingSnippet]) {
        let nextThought: String
        switch analysis.recommendedMove {
        case .answerDirectly:
            nextThought = "Answer directly, then name the strongest support."
        case .clarify:
            nextThought = "Clarify the premise before answering."
        case .challengePremise:
            nextThought = "Challenge the framing gently before giving a narrow answer."
        case .citeSource:
            nextThought = "Use the available source and mark uncertainty."
        case .deferAnswer:
            nextThought = "Defer until a source is available."
        }

        let bullets = [
            analysis.parts.first.map { "Address: \($0)" },
            analysis.assumptions.first.map { "Assumption to check: \($0)" },
            analysis.traps.first.map { "Watch for loaded framing: \($0)" }
        ].compactMap { $0 }

        let card = SuggestionCard(nextThought: nextThought,
                                  answerBullets: bullets.isEmpty ? ["No provider call was made in local-only mode."] : bullets,
                                  caveat: grounding.isEmpty ? "No local sources matched yet." : nil,
                                  citations: grounding,
                                  confidence: analysis.confidence)

        let update = SuggestionUpdate(id: UUID().uuidString,
                                      sessionID: sessionID,
                                      ts: Date.unixMilliseconds,
                                      kind: suggestionKind(for: trigger),
                                      prompt: trigger.questionText,
                                      text: nextThought,
                                      card: card,
                                      isFinal: true,
                                      errorMessage: nil)
        suggestions.append(update)
    }

    private func suggestionKind(for trigger: SuggestionEngine.Trigger) -> SuggestionKind {
        switch trigger {
        case .detected: return .auto
        case .manual: return .manual
        case .hotkey: return .hotkey
        }
    }

    private func audit(_ action: String, detail: String = "") {
        let record = PrivacyAuditRecord(id: UUID().uuidString,
                                        sessionID: activeSession?.id,
                                        ts: Date.unixMilliseconds,
                                        action: action,
                                        detail: detail)
        Task {
            try? await AppDatabase.shared.insertPrivacyAudit(record)
        }
    }

    private func processLocalIntelligence(for chunk: TranscriptChunkRecord) {
        let analysis = questionAnalyzer.analyze(question: chunk.text, context: transcript)
        if chunk.text.contains("?") || analysis.parts.count > 1 || !analysis.traps.isEmpty {
            questionAnalyses.append(analysis)
            if let data = try? JSONEncoder().encode(analysis) {
                Task {
                    try? await AppDatabase.shared.insertAnalysisEvent(
                        AnalysisEventRecord(id: UUID().uuidString,
                                            sessionID: chunk.sessionID,
                                            ts: Date.unixMilliseconds,
                                            kind: "question",
                                            payloadJSON: data)
                    )
                }
            }
        }

        Task {
            let payloads = await conversationMemory.extract(from: chunk)
            for payload in payloads {
                let data = try? JSONEncoder().encode(payload)
                let record = MemoryItemRecord(id: UUID().uuidString,
                                              sessionID: chunk.sessionID,
                                              ts: Date.unixMilliseconds,
                                              kind: payload.kind,
                                              text: payload.text,
                                              sourceTranscriptID: payload.sourceTranscriptID,
                                              payloadJSON: data)
                _ = try? await AppDatabase.shared.insertMemoryItem(record)
                await MainActor.run {
                    self.memoryItems.insert(record, at: 0)
                }
            }
        }
    }

    // MARK: - Lifecycle

    private func startCallAsync(title: String,
                                brief: String,
                                providerID: String,
                                modelID: String,
                                documents: [URL]) async {
        await stopCallAsync()

        let session = CallSessionRecord(title: title,
                                        brief: brief,
                                        status: .live,
                                        providerID: providerID,
                                        modelID: modelID)

        do {
            try await AppDatabase.shared.insertCallSession(session)
            activeSession = session
            audit("session_start", detail: title)
            self.brief = brief
            self.providerID = providerID
            self.modelID = modelID
            transcript = []
            questionAnalyses = []
            memoryItems = []
            await conversationMemory.reset()
            suggestions = []
            contextDocs = try await AppDatabase.shared.contextDocs(sessionID: session.id)
            prepArtifacts = try await AppDatabase.shared.sessionArtifacts(sessionID: session.id, kind: "prep")
            reviewArtifacts = try await AppDatabase.shared.sessionArtifacts(sessionID: session.id, kind: "review")
            status = "Loading speech model"
            errorMessage = nil
            let speechModel = WhisperModelManager.shared.selectedModel
            try await whisperEngine.start(sessionID: session.id,
                                          modelName: speechModel.modelName,
                                          downloadBase: WhisperModelManager.shared.modelsDirectory)
            status = "Call ready"
            for url in documents {
                ingestDocument(url: url)
            }
            await startRecording()
        } catch {
            errorMessage = error.localizedDescription
            status = "Failed to start"
        }
    }

    private func stopCallAsync() async {
        await stopRecording()
        await whisperEngine.stop()
        await suggestionEngine.stop()
        questionDetector.reset()
        await conversationMemory.reset()

        if let session = activeSession {
            audit("session_stop", detail: session.title)
            try? await AppDatabase.shared.finishCallSession(id: session.id, endedAt: Date())
        }

        activeSession = nil
        providerID = nil
        modelID = nil
        brief = ""
        contextDocs = []
        questionAnalyses = []
        memoryItems = []
        prepArtifacts = []
        reviewArtifacts = []
        status = "Idle"
    }

    private func startRecording() async {
        guard activeSession != nil, !isRecording else { return }

        do {
            let frames = await audioCapturer.frames()
            try await audioCapturer.start()
            isRecording = true
            status = "Recording"
            audit("recording_start")
            errorMessage = nil

            audioTask?.cancel()
            audioTask = Task {
                for await samples in frames {
                    await self.whisperEngine.consume(samples: samples)
                }
            }
        } catch let error as SystemAudioCaptureError {
            errorMessage = error.errorDescription
            status = "Audio permission needed"
        } catch {
            errorMessage = error.localizedDescription
            status = "Audio failed"
        }
    }

    private func stopRecording() async {
        guard isRecording || audioTask != nil else { return }
        audioTask?.cancel()
        audioTask = nil
        await audioCapturer.stop()
        isRecording = false
        audit("recording_stop")
        if activeSession != nil {
            status = "Paused"
        }
    }
}
