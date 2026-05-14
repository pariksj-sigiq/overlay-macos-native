//
//  QuestionDetector.swift
//  OverlayOpus
//

import Combine
import Foundation

final class QuestionDetector {

    let questionPublisher = PassthroughSubject<DetectedQuestion, Never>()

    private var cancellables = Set<AnyCancellable>()
    private var sentenceBuffer: [String] = []
    private var pendingQuestion: String?
    private var pendingSessionID: String?
    private var debounceWorkItem: DispatchWorkItem?

    private let queue = DispatchQueue(label: "com.overlay-opus.question-detector", qos: .userInitiated)

    func bind(to transcriptPublisher: PassthroughSubject<TranscriptChunkRecord, Never>) {
        transcriptPublisher
            .sink { [weak self] chunk in
                self?.consume(chunk)
            }
            .store(in: &cancellables)
    }

    func reset() {
        queue.async { [weak self] in
            self?.sentenceBuffer.removeAll()
            self?.pendingQuestion = nil
            self?.pendingSessionID = nil
            self?.debounceWorkItem?.cancel()
            self?.debounceWorkItem = nil
        }
    }

    private func consume(_ chunk: TranscriptChunkRecord) {
        queue.async { [weak self] in
            self?.process(text: chunk.text, sessionID: chunk.sessionID)
        }
    }

    private func process(text: String, sessionID: String?) {
        for sentence in splitSentences(text) {
            sentenceBuffer.append(sentence)
            if sentenceBuffer.count > 12 {
                sentenceBuffer.removeFirst(sentenceBuffer.count - 12)
            }

            if isLikelyQuestion(sentence) {
                pendingQuestion = sentence
                pendingSessionID = sessionID
                scheduleEmit()
            }
        }
    }

    private func scheduleEmit() {
        debounceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.emitPendingQuestion()
        }
        debounceWorkItem = item
        queue.asyncAfter(deadline: .now() + 1.5, execute: item)
    }

    private func emitPendingQuestion() {
        guard let text = pendingQuestion else { return }
        pendingQuestion = nil

        let question = DetectedQuestion(sessionID: pendingSessionID,
                                        text: text,
                                        context: sentenceBuffer.suffix(5).joined(separator: " "),
                                        confidence: confidence(for: text))
        questionPublisher.send(question)
    }

    private func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""

        for character in text {
            current.append(character)
            if ".?!\n".contains(character) {
                let sentence = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty {
                    sentences.append(sentence)
                }
                current = ""
            }
        }

        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            sentences.append(tail)
        }
        return sentences
    }

    private func isLikelyQuestion(_ sentence: String) -> Bool {
        let lower = sentence.lowercased()
        if sentence.contains("?") { return true }

        let questionStarts = [
            "what ", "why ", "how ", "when ", "where ", "who ", "which ",
            "can you ", "could you ", "would you ", "should we ", "do we ",
            "does this ", "is there ", "are there ", "tell me "
        ]
        if questionStarts.contains(where: { lower.hasPrefix($0) }) {
            return true
        }

        let intentPhrases = [
            "i have a question",
            "one question",
            "quick question",
            "help me understand",
            "walk me through",
            "can someone explain"
        ]
        return intentPhrases.contains { lower.contains($0) }
    }

    private func confidence(for sentence: String) -> Double {
        if sentence.contains("?") { return 0.95 }
        if sentence.lowercased().hasPrefix("what ") || sentence.lowercased().hasPrefix("how ") {
            return 0.86
        }
        return 0.72
    }
}
