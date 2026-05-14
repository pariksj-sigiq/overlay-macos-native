//
//  WhisperEngine.swift
//  OverlayOpus
//

import Combine
import Foundation

actor WhisperEngine {

    enum State: Equatable {
        case idle
        case loaded(URL)
        case running
    }

    nonisolated let transcriptPublisher = PassthroughSubject<TranscriptChunkRecord, Never>()

    private(set) var state: State = .idle
    private var currentModelURL: URL?
    private var sessionID: String?
    private var sampleBuffer = AudioRingBuffer(capacity: 16_000 * 8)

    private let windowSampleCount = 16_000 * 6
    private let overlapSampleCount = 16_000

    func loadModel(at url: URL) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        currentModelURL = url
        state = .loaded(url)
        // Insert whisper.cpp binding initialization here once the C module is wired.
    }

    func start(sessionID: String? = nil) {
        self.sessionID = sessionID
        sampleBuffer.removeAll()
        state = .running
    }

    func stop() {
        sampleBuffer.removeAll()
        sessionID = nil
        if let currentModelURL {
            state = .loaded(currentModelURL)
        } else {
            state = .idle
        }
    }

    func consume(samples: [Float]) {
        guard state == .running, !samples.isEmpty else { return }
        sampleBuffer.append(samples)

        let latest = sampleBuffer.latestSamples(count: windowSampleCount)
        guard latest.count >= windowSampleCount else { return }
        _ = sampleBuffer.drain(count: max(0, latest.count - overlapSampleCount))
        // Local placeholder only. Real transcription should run here and publish TranscriptChunkRecord.
    }

    func feed(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let sessionID else { return }
        let chunk = TranscriptChunkRecord(sessionID: sessionID,
                                          speaker: .them,
                                          text: trimmed,
                                          source: "whisper")
        transcriptPublisher.send(chunk)
    }
}
