//
//  WhisperModelManager.swift
//  OverlayOpus
//

import Combine
import Foundation

@MainActor
final class WhisperModelManager: ObservableObject {

    enum ModelChoice: String, CaseIterable, Identifiable {
        case tinyEN = "tiny.en"
        case baseEN = "base.en"
        case smallEN = "small.en"
        case mediumEN = "medium.en"

        var id: String { rawValue }

        var fileName: String {
            "ggml-\(rawValue).bin"
        }

        var downloadURL: URL {
            get throws {
                guard let url = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)") else {
                    throw URLError(.badURL)
                }
                return url
            }
        }
    }

    static let shared = WhisperModelManager()

    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var isDownloading = false
    @Published private(set) var errorMessage: String?

    private let fileManager = FileManager.default

    var modelsDirectory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Overlay/models", isDirectory: true)
    }

    private init() {
        try? ensureModelsDirectory()
    }

    func modelURL(for choice: ModelChoice) -> URL {
        modelsDirectory.appendingPathComponent(choice.fileName, isDirectory: false)
    }

    func isInstalled(_ choice: ModelChoice) -> Bool {
        fileManager.fileExists(atPath: modelURL(for: choice).path)
    }

    func installedModelURL(preferred choice: ModelChoice = .baseEN) -> URL? {
        if isInstalled(choice) {
            return modelURL(for: choice)
        }

        guard let installedChoice = ModelChoice.allCases.first(where: { isInstalled($0) }) else {
            return nil
        }
        return modelURL(for: installedChoice)
    }

    func installedModels() -> [ModelChoice] {
        ModelChoice.allCases.filter { isInstalled($0) }
    }

    func ensureBaseModelDownloaded() async throws -> URL {
        try await downloadIfNeeded(.baseEN)
    }

    func downloadIfNeeded(_ choice: ModelChoice) async throws -> URL {
        let destination = modelURL(for: choice)
        if fileManager.fileExists(atPath: destination.path) {
            return destination
        }
        return try await download(choice)
    }

    @discardableResult
    func download(_ choice: ModelChoice) async throws -> URL {
        try ensureModelsDirectory()

        isDownloading = true
        downloadProgress = 0
        errorMessage = nil

        do {
            let destination = modelURL(for: choice)
            let delegate = ModelDownloadDelegate { [weak self] progress in
                Task { @MainActor in self?.downloadProgress = progress }
            }
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            let (temporaryURL, _) = try await session.download(from: try choice.downloadURL)

            try await Task.detached(priority: .utility) { [fileManager] in
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: temporaryURL, to: destination)
            }.value

            downloadProgress = 1
            isDownloading = false
            return destination
        } catch {
            isDownloading = false
            errorMessage = error.localizedDescription
            throw error
        }
    }

    private func ensureModelsDirectory() throws {
        try fileManager.createDirectory(at: modelsDirectory,
                                        withIntermediateDirectories: true,
                                        attributes: nil)
    }
}

private final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let onProgress: (Double) -> Void

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
    }
}
