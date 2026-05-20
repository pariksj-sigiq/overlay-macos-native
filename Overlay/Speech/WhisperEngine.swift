//
//  WhisperEngine.swift
//  OverlayOpus
//

import Combine
import Foundation
import WhisperKit

actor WhisperEngine {

    enum State: Equatable {
        case idle
        case loading(String)
        case loaded(String)
        case running(String)
    }

    nonisolated let transcriptPublisher = PassthroughSubject<TranscriptChunkRecord, Never>()

    private(set) var state: State = .idle
    private var whisperKit: WhisperKit?
    private var currentModelName: String?
    private var sessionID: String?
    private var sampleBuffer = AudioRingBuffer(capacity: 16_000 * 12)
    private var isTranscribing = false
    private var transcriptionTask: Task<Void, Never>?
    private var lastPublishedFingerprint = ""

    private let windowSampleCount = 16_000 * 6
    private let overlapSampleCount = 16_000

    func loadModel(named modelName: String, downloadBase: URL) async throws {
        if currentModelName == modelName, whisperKit != nil {
            state = .loaded(modelName)
            return
        }

        transcriptionTask?.cancel()
        transcriptionTask = nil
        isTranscribing = false
        state = .loading(modelName)

        let config = WhisperKitConfig(model: modelName,
                                      downloadBase: downloadBase,
                                      verbose: false,
                                      prewarm: false,
                                      load: true,
                                      download: true)
        whisperKit = try await WhisperKit(config)
        currentModelName = modelName
        state = .loaded(modelName)
    }

    func start(sessionID: String? = nil, modelName: String, downloadBase: URL) async throws {
        try await loadModel(named: modelName, downloadBase: downloadBase)
        self.sessionID = sessionID
        sampleBuffer.removeAll()
        lastPublishedFingerprint = ""
        state = .running(modelName)
    }

    func stop() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        isTranscribing = false
        sampleBuffer.removeAll()
        sessionID = nil
        if let currentModelName {
            state = .loaded(currentModelName)
        } else {
            state = .idle
        }
    }

    func consume(samples: [Float]) {
        guard case .running = state, !samples.isEmpty else { return }
        sampleBuffer.append(samples)
        scheduleTranscriptionIfReady()
    }

    func feed(text: String) {
        publish(text: text)
    }

    private func scheduleTranscriptionIfReady() {
        guard !isTranscribing, sampleBuffer.count >= windowSampleCount else { return }

        let window = sampleBuffer.latestSamples(count: windowSampleCount)
        _ = sampleBuffer.drain(count: windowSampleCount - overlapSampleCount)
        isTranscribing = true
        transcriptionTask = Task { await self.transcribe(window: window) }
    }

    private func transcribe(window samples: [Float]) async {
        defer {
            isTranscribing = false
            transcriptionTask = nil
            scheduleTranscriptionIfReady()
        }

        guard let whisperKit, !Task.isCancelled else { return }

        do {
            let options = DecodingOptions(language: "en",
                                          temperature: 0,
                                          withoutTimestamps: true,
                                          wordTimestamps: false)
            let results = try await whisperKit.transcribe(audioArray: samples,
                                                          decodeOptions: options)
            let text = results.map(\.text).joined(separator: " ")
            publish(text: text)
        } catch is CancellationError {
            return
        } catch {
            // Keep the live audio loop alive; failed windows should not end the call.
            return
        }
    }

    private func publish(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let sessionID else { return }

        let fingerprint = Self.fingerprint(for: trimmed)
        guard !fingerprint.isEmpty,
              fingerprint != lastPublishedFingerprint,
              !lastPublishedFingerprint.hasSuffix(fingerprint) else {
            return
        }

        lastPublishedFingerprint = fingerprint
        let chunk = TranscriptChunkRecord(sessionID: sessionID,
                                          speaker: .them,
                                          text: trimmed,
                                          source: "whisperkit")
        transcriptPublisher.send(chunk)
    }

    private static func fingerprint(for text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
