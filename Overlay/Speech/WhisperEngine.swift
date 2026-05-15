//
//  WhisperEngine.swift
//  OverlayOpus
//

import Combine
import Foundation

enum WhisperRuntimeError: LocalizedError, Equatable {
    case modelMissing(URL)
    case modelNotLoaded
    case runtimeUnavailable
    case runtimeLaunchFailed(URL, String)
    case runtimeFailed(URL, Int32, String)
    case runtimeTimedOut(URL)
    case sessionMissing

    var errorDescription: String? {
        switch self {
        case .modelMissing(let url):
            return "Whisper model is missing at \(url.path). Download a local ggml model before recording."
        case .modelNotLoaded:
            return "Whisper is not loaded. Download a local model and make sure a local whisper runtime is installed."
        case .runtimeUnavailable:
            return "No local Whisper runtime found. Install whisper-cli, whisper-cpp, or main, or bundle one with the app."
        case .runtimeLaunchFailed(let url, let message):
            return "Could not launch local Whisper runtime at \(url.path): \(message)"
        case .runtimeFailed(let url, let status, let output):
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "Local Whisper runtime \(url.lastPathComponent) failed with exit code \(status)."
            }
            return "Local Whisper runtime \(url.lastPathComponent) failed with exit code \(status): \(detail)"
        case .runtimeTimedOut(let url):
            return "Local Whisper runtime \(url.lastPathComponent) timed out while transcribing audio."
        case .sessionMissing:
            return "Start a call session before starting transcription."
        }
    }
}

actor WhisperEngine {

    struct Runtime: Equatable, Sendable {
        let executableURL: URL

        var displayName: String {
            executableURL.lastPathComponent
        }
    }

    enum State: Equatable {
        case idle
        case loaded(model: URL, runtime: URL)
        case running(model: URL, runtime: URL)
        case unavailable(String)
    }

    nonisolated let transcriptPublisher = PassthroughSubject<TranscriptChunkRecord, Never>()
    nonisolated let errorPublisher = PassthroughSubject<String, Never>()

    private(set) var state: State = .idle
    private var currentModelURL: URL?
    private var runtimeURL: URL?
    private var sessionID: String?
    private var sampleBuffer = AudioRingBuffer(capacity: 16_000 * 8)
    private var isTranscribing = false
    private var transcriptionTask: Task<Void, Never>?
    private var lastPublishedText = ""

    private let windowSampleCount = 16_000 * 4
    private static let sampleRate = 16_000
    private static let runtimeExecutableNames = ["whisper-cli", "whisper-cpp", "main"]

    func loadModel(at url: URL) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WhisperRuntimeError.modelMissing(url)
        }
        guard let runtime = Self.discoverRuntime() else {
            state = .unavailable(WhisperRuntimeError.runtimeUnavailable.localizedDescription)
            throw WhisperRuntimeError.runtimeUnavailable
        }

        currentModelURL = url
        runtimeURL = runtime.executableURL
        state = .loaded(model: url, runtime: runtime.executableURL)
    }

    func start(sessionID: String? = nil) throws {
        guard let sessionID, !sessionID.isEmpty else {
            throw WhisperRuntimeError.sessionMissing
        }
        guard let currentModelURL, let runtimeURL else {
            throw WhisperRuntimeError.modelNotLoaded
        }

        self.sessionID = sessionID
        sampleBuffer.removeAll()
        lastPublishedText = ""
        state = .running(model: currentModelURL, runtime: runtimeURL)
    }

    func stop() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        sampleBuffer.removeAll()
        sessionID = nil
        isTranscribing = false
        if let currentModelURL {
            if let runtimeURL {
                state = .loaded(model: currentModelURL, runtime: runtimeURL)
            } else {
                state = .idle
            }
        } else {
            state = .idle
        }
    }

    func consume(samples: [Float]) {
        guard case .running = state, !samples.isEmpty else { return }
        sampleBuffer.append(samples)
        guard !isTranscribing, sampleBuffer.count >= windowSampleCount else { return }
        guard let currentModelURL, let runtimeURL else { return }

        let window = sampleBuffer.drain(count: windowSampleCount)
        isTranscribing = true
        transcriptionTask = Task {
            do {
                let text = try await Self.transcribe(samples: window,
                                                     modelURL: currentModelURL,
                                                     runtimeURL: runtimeURL)
                await self.finishTranscription(text: text)
            } catch is CancellationError {
                await self.finishTranscription(text: "")
            } catch {
                await self.failTranscription(error)
            }
        }
    }

    func feed(text: String) {
        publish(text: text)
    }

    nonisolated static func discoverRuntime() -> Runtime? {
        let fileManager = FileManager.default
        return runtimeCandidateURLs().first { candidate in
            fileManager.isExecutableFile(atPath: candidate.path)
        }.map(Runtime.init(executableURL:))
    }

    // MARK: - Private

    private func publish(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let sessionID else { return }
        let normalized = Self.normalized(trimmed)
        guard !normalized.isEmpty, normalized != lastPublishedText else { return }
        lastPublishedText = normalized

        let chunk = TranscriptChunkRecord(sessionID: sessionID,
                                          speaker: .them,
                                          text: trimmed,
                                          source: "whisper")
        transcriptPublisher.send(chunk)
    }

    private func finishTranscription(text: String) {
        isTranscribing = false
        transcriptionTask = nil
        guard case .running = state else { return }
        publish(text: text)
    }

    private func failTranscription(_ error: Error) {
        isTranscribing = false
        transcriptionTask = nil
        errorPublisher.send(error.localizedDescription)
    }

    private nonisolated static func runtimeCandidateURLs() -> [URL] {
        let fileManager = FileManager.default
        var directories: [URL] = []

        if let resourceURL = Bundle.main.resourceURL {
            directories.append(resourceURL)
            directories.append(resourceURL.appendingPathComponent("bin", isDirectory: true))
        }
        if let executableURL = Bundle.main.executableURL {
            directories.append(executableURL.deletingLastPathComponent())
        }

        let appSupportBase = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        let overlaySupport = appSupportBase.appendingPathComponent("Overlay", isDirectory: true)
        directories.append(overlaySupport)
        directories.append(overlaySupport.appendingPathComponent("bin", isDirectory: true))
        directories.append(overlaySupport.appendingPathComponent("whisper", isDirectory: true))

        directories.append(URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true))

        let environmentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for path in environmentPath.split(separator: ":") {
            directories.append(URL(fileURLWithPath: String(path), isDirectory: true))
        }

        directories.append(contentsOf: [
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/bin", isDirectory: true),
            URL(fileURLWithPath: "/bin", isDirectory: true)
        ])

        var seen = Set<String>()
        let uniqueDirectories = directories.filter { seen.insert($0.path).inserted }
        return uniqueDirectories.flatMap { directory in
            runtimeExecutableNames.map { directory.appendingPathComponent($0, isDirectory: false) }
        }
    }

    private nonisolated static func transcribe(samples: [Float],
                                               modelURL: URL,
                                               runtimeURL: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            try Task.checkCancellation()

            let temporaryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("OverlayOpus-\(UUID().uuidString).wav", isDirectory: false)
            try Self.writeWAV(samples: samples, to: temporaryURL)
            defer { try? FileManager.default.removeItem(at: temporaryURL) }

            let process = Process()
            process.executableURL = runtimeURL
            process.arguments = [
                "-m", modelURL.path,
                "-f", temporaryURL.path,
                "-nt",
                "-np"
            ]

            let standardOutput = Pipe()
            let standardError = Pipe()
            process.standardOutput = standardOutput
            process.standardError = standardError

            do {
                try process.run()
            } catch {
                throw WhisperRuntimeError.runtimeLaunchFailed(runtimeURL, error.localizedDescription)
            }

            let deadline = Date().addingTimeInterval(45)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.15)
            }
            if process.isRunning {
                process.terminate()
                throw WhisperRuntimeError.runtimeTimedOut(runtimeURL)
            }

            let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
            let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8) ?? ""
            let diagnostics = String(data: errorData, encoding: .utf8) ?? ""

            guard process.terminationStatus == 0 else {
                throw WhisperRuntimeError.runtimeFailed(runtimeURL,
                                                        process.terminationStatus,
                                                        output + diagnostics)
            }

            try Task.checkCancellation()
            return Self.cleanTranscript(output)
        }.value
    }

    private nonisolated static func writeWAV(samples: [Float], to url: URL) throws {
        var data = Data()

        func appendString(_ value: String) {
            data.append(contentsOf: value.utf8)
        }

        func appendUInt16(_ value: UInt16) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }

        func appendUInt32(_ value: UInt32) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }

        func appendInt16(_ value: Int16) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }

        let bytesPerSample = 2
        let dataChunkSize = UInt32(samples.count * bytesPerSample)
        let byteRate = UInt32(sampleRate * bytesPerSample)

        appendString("RIFF")
        appendUInt32(36 + dataChunkSize)
        appendString("WAVE")
        appendString("fmt ")
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(1)
        appendUInt32(UInt32(sampleRate))
        appendUInt32(byteRate)
        appendUInt16(UInt16(bytesPerSample))
        appendUInt16(16)
        appendString("data")
        appendUInt32(dataChunkSize)

        for sample in samples {
            let clipped = max(-1, min(1, sample))
            appendInt16(Int16(clipped * Float(Int16.max)))
        }

        try data.write(to: url, options: .atomic)
    }

    private nonisolated static func cleanTranscript(_ raw: String) -> String {
        let diagnosticPrefixes = [
            "whisper_",
            "ggml_",
            "main:",
            "system_info:",
            "sampling:",
            "processing",
            "encode time",
            "decode time",
            "total time"
        ]

        let lines = raw.components(separatedBy: .newlines).compactMap { line -> String? in
            var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let lowercased = text.lowercased()
            if diagnosticPrefixes.contains(where: { lowercased.hasPrefix($0) }) {
                return nil
            }
            text = text.replacingOccurrences(of: #"\[[0-9:.,\s>\-]+\]"#,
                                              with: "",
                                              options: .regularExpression)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }

        return lines.joined(separator: " ")
    }

    private nonisolated static func normalized(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
