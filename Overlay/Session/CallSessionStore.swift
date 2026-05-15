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
    @Published private(set) var suggestions: [SuggestionUpdate] = []
    @Published private(set) var isRecording = false
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var status = "Idle"
    @Published var errorMessage: String?

    private let audioCapturer = SystemAudioCapturer()
    private let whisperEngine = WhisperEngine()
    private let questionDetector = QuestionDetector()
    private let suggestionEngine = SuggestionEngine()
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
                   scheduledAt: Date? = nil,
                   documents: [URL] = []) {
        Task {
            await startCallAsync(title: title,
                                 brief: brief,
                                 providerID: providerID,
                                 modelID: modelID,
                                 scheduledAt: scheduledAt,
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
            await stopCallAsync(reportIfIdle: true)
        }
    }

    func toggleRecording() {
        guard activeSession != nil else {
            reportStatus("No active call", "Start a call from the Brief tab before recording.")
            return
        }
        if isRecording {
            Task { await stopRecording() }
        } else {
            Task { await startRecording() }
        }
    }

    func manualAsk(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            reportStatus("Question is empty", "Type a question before asking for a suggestion.")
            return
        }
        guard let session = activeSession else {
            reportStatus("No active call", "Start a call before asking for suggestions.")
            return
        }
        guard let providerID, let modelID else {
            reportStatus("Provider missing", "Choose a provider and model before asking for suggestions.")
            return
        }

        Task {
            await suggestionEngine.suggest(trigger: .manual(trimmed),
                                           sessionID: session.id,
                                           brief: brief,
                                           providerID: providerID,
                                           modelID: modelID,
                                           contextDocs: contextDocs,
                                           transcriptTail: transcript)
        }
    }

    func regenerateLast() {
        guard let session = activeSession else {
            reportStatus("No active call", "Start a call before regenerating a suggestion.")
            return
        }
        guard let providerID, let modelID else {
            reportStatus("Provider missing", "Choose a provider and model before regenerating.")
            return
        }
        guard !suggestions.isEmpty else {
            reportStatus("Nothing to regenerate", "Ask a question before regenerating a suggestion.")
            return
        }

        Task {
            await suggestionEngine.regenerateLast(sessionID: session.id,
                                                  brief: brief,
                                                  providerID: providerID,
                                                  modelID: modelID,
                                                  contextDocs: contextDocs,
                                                  transcriptTail: transcript)
        }
    }

    func regenerateSuggestion(_ suggestion: SuggestionUpdate) {
        guard let session = activeSession else {
            reportStatus("No active call", "Start a call before regenerating a suggestion.")
            return
        }
        guard let providerID, let modelID else {
            reportStatus("Provider missing", "Choose a provider and model before regenerating.")
            return
        }

        let prompt = suggestion.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            reportStatus("Nothing to regenerate", "This suggestion has no saved prompt.")
            return
        }

        let trigger: SuggestionEngine.Trigger
        switch suggestion.kind {
        case .auto:
            trigger = .manual(prompt)
        case .manual:
            trigger = .manual(prompt)
        case .hotkey:
            trigger = .hotkey(prompt)
        }

        Task {
            await suggestionEngine.suggest(trigger: trigger,
                                           sessionID: session.id,
                                           brief: brief,
                                           providerID: providerID,
                                           modelID: modelID,
                                           contextDocs: contextDocs,
                                           transcriptTail: transcript)
        }
    }

    func ingestDocument(url: URL) {
        guard let providerID, let modelID else {
            reportStatus("Provider missing", "Choose a provider and model before ingesting documents.")
            return
        }
        let sessionID = activeSession?.id

        Task {
            do {
                let record = try await documentIngestor.ingest(url: url,
                                                               sessionID: sessionID,
                                                               providerID: providerID,
                                                               modelID: modelID)
                contextDocs.append(record)
            } catch {
                reportStatus("Document ingest failed", error.localizedDescription)
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
                Task {
                    try? await AppDatabase.shared.insertTranscriptChunk(chunk)
                }
            }
            .store(in: &cancellables)

        whisperEngine.errorPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                guard let self else { return }
                Task { @MainActor in
                    await self.stopRecording(reportIfIdle: false)
                    self.reportStatus("Transcription failed", message)
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
                    await self.suggestionEngine.suggest(trigger: .detected(question),
                                                        sessionID: session.id,
                                                        brief: self.brief,
                                                        providerID: providerID,
                                                        modelID: modelID,
                                                        contextDocs: self.contextDocs,
                                                        transcriptTail: self.transcript)
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

    // MARK: - Lifecycle

    private func startCallAsync(title: String,
                                brief: String,
                                providerID: String,
                                modelID: String,
                                scheduledAt: Date?,
                                documents: [URL]) async {
        await stopCallAsync(reportIfIdle: false)

        let session = CallSessionRecord(title: title,
                                        scheduledAt: scheduledAt?.unixSeconds,
                                        brief: brief,
                                        status: .live,
                                        providerID: providerID,
                                        modelID: modelID)

        do {
            try await AppDatabase.shared.insertCallSession(session)
            activeSession = session
            self.brief = brief
            self.providerID = providerID
            self.modelID = modelID
            transcript = []
            suggestions = []
            contextDocs = try await AppDatabase.shared.contextDocs(sessionID: session.id)
            status = "Call ready"
            errorMessage = nil
            for url in documents {
                ingestDocument(url: url)
            }
            await startRecording()
        } catch {
            errorMessage = error.localizedDescription
            status = "Failed to start"
        }
    }

    private func stopCallAsync(reportIfIdle: Bool = false) async {
        let hadSession = activeSession != nil
        await stopRecording(reportIfIdle: false)
        await whisperEngine.stop()
        await suggestionEngine.stop()
        questionDetector.reset()

        if let session = activeSession {
            try? await AppDatabase.shared.finishCallSession(id: session.id, endedAt: Date())
        }

        activeSession = nil
        providerID = nil
        modelID = nil
        brief = ""
        contextDocs = []
        audioLevel = 0

        if hadSession || !reportIfIdle {
            status = "Idle"
            errorMessage = nil
        } else {
            reportStatus("No active call", "There is no active call to stop.")
        }
    }

    private func startRecording() async {
        guard let session = activeSession else {
            reportStatus("No active call", "Start a call before recording.")
            return
        }
        guard !isRecording else {
            reportStatus("Already recording")
            return
        }
        guard let modelURL = WhisperModelManager.shared.installedModelURL(preferred: .baseEN) else {
            audioLevel = 0
            reportStatus("Whisper model missing", "Download a local ggml Whisper model in Settings before recording.")
            return
        }

        do {
            try await whisperEngine.loadModel(at: modelURL)
            try await whisperEngine.start(sessionID: session.id)
            let frames = await audioCapturer.frames()
            try await audioCapturer.start()
            isRecording = true
            audioLevel = 0
            status = "Recording"
            errorMessage = nil

            audioTask?.cancel()
            let store = self
            let whisperEngine = self.whisperEngine
            audioTask = Task.detached { [weak store, frames, whisperEngine] in
                for await frame in frames {
                    await store?.setAudioLevel(frame.level)
                    await whisperEngine.consume(samples: frame.samples)
                }
            }
        } catch let error as WhisperRuntimeError {
            await whisperEngine.stop()
            await audioCapturer.stop()
            audioLevel = 0
            reportStatus(statusTitle(for: error), error.localizedDescription)
        } catch let error as SystemAudioCaptureError {
            await whisperEngine.stop()
            await audioCapturer.stop()
            audioLevel = 0
            errorMessage = error.errorDescription
            status = "Audio permission needed"
        } catch {
            await whisperEngine.stop()
            await audioCapturer.stop()
            audioLevel = 0
            errorMessage = error.localizedDescription
            status = "Audio failed"
        }
    }

    private func setAudioLevel(_ level: Float) {
        audioLevel = level
    }

    private func stopRecording(reportIfIdle: Bool = true) async {
        guard isRecording || audioTask != nil else {
            audioLevel = 0
            if reportIfIdle {
                if activeSession == nil {
                    reportStatus("No active call", "Start a call before stopping recording.")
                } else {
                    reportStatus("Recording already stopped")
                }
            }
            return
        }
        audioTask?.cancel()
        audioTask = nil
        await audioCapturer.stop()
        await whisperEngine.stop()
        isRecording = false
        audioLevel = 0
        if activeSession != nil {
            status = "Paused"
        }
    }

    private func reportStatus(_ status: String, _ message: String? = nil) {
        self.status = status
        self.errorMessage = message
    }

    private func statusTitle(for error: WhisperRuntimeError) -> String {
        switch error {
        case .modelMissing, .modelNotLoaded:
            return "Whisper model missing"
        case .runtimeUnavailable, .runtimeLaunchFailed:
            return "Whisper unavailable"
        case .runtimeFailed, .runtimeTimedOut:
            return "Transcription failed"
        case .sessionMissing:
            return "No active call"
        }
    }
}
