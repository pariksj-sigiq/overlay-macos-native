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
            await suggestionEngine.suggest(trigger: .manual(question),
                                           sessionID: session.id,
                                           brief: brief,
                                           providerID: providerID,
                                           modelID: modelID,
                                           contextDocs: contextDocs,
                                           transcriptTail: transcript)
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
                                                  contextDocs: contextDocs,
                                                  transcriptTail: transcript)
        }
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
            self.brief = brief
            self.providerID = providerID
            self.modelID = modelID
            transcript = []
            suggestions = []
            contextDocs = try await AppDatabase.shared.contextDocs(sessionID: session.id)
            status = "Call ready"
            errorMessage = nil
            await whisperEngine.start(sessionID: session.id)
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

        if let session = activeSession {
            try? await AppDatabase.shared.finishCallSession(id: session.id, endedAt: Date())
        }

        activeSession = nil
        providerID = nil
        modelID = nil
        brief = ""
        contextDocs = []
        status = "Idle"
    }

    private func startRecording() async {
        guard activeSession != nil, !isRecording else { return }

        do {
            let frames = await audioCapturer.frames()
            try await audioCapturer.start()
            isRecording = true
            status = "Recording"
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
        if activeSession != nil {
            status = "Paused"
        }
    }
}
