//
//  WhisperModelManager.swift
//  OverlayOpus
//

import Combine
import Foundation
import WhisperKit

@MainActor
final class WhisperModelManager: ObservableObject {

    enum ModelChoice: String, CaseIterable, Identifiable {
        case tiny = "tiny"
        case baseEN = "base.en"
        case smallEN = "small.en"
        case largeV3 = "large-v3-v20240930_626MB"

        var id: String { rawValue }
        var modelName: String { rawValue }

        var label: String {
            switch self {
            case .tiny:
                return "Tiny"
            case .baseEN:
                return "Base English"
            case .smallEN:
                return "Small English"
            case .largeV3:
                return "Large v3"
            }
        }
    }

    static let shared = WhisperModelManager()
    private static let selectedModelKey = "overlay.whisperKitModel"

    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var isDownloading = false
    @Published private(set) var errorMessage: String?
    @Published var selectedModel: ModelChoice {
        didSet {
            UserDefaults.standard.set(selectedModel.rawValue, forKey: Self.selectedModelKey)
        }
    }

    private let fileManager = FileManager.default

    var modelsDirectory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Overlay/whisperkit-models", isDirectory: true)
    }

    private init() {
        if let rawValue = UserDefaults.standard.string(forKey: Self.selectedModelKey),
           let model = ModelChoice(rawValue: rawValue) {
            selectedModel = model
        } else {
            selectedModel = .baseEN
        }
        try? ensureModelsDirectory()
    }

    func isInstalled(_ choice: ModelChoice) -> Bool {
        installedModelURL(for: choice) != nil
    }

    func ensureBaseModelDownloaded() async throws -> URL {
        try await downloadIfNeeded(.baseEN)
    }

    func downloadIfNeeded(_ choice: ModelChoice) async throws -> URL {
        if let modelURL = installedModelURL(for: choice) {
            return modelURL
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
            let modelURL = try await WhisperKit.download(variant: choice.modelName,
                                                         downloadBase: modelsDirectory) { [weak self] progress in
                Task { @MainActor in
                    let fraction = progress.fractionCompleted
                    if fraction.isFinite {
                        self?.downloadProgress = fraction
                    }
                }
            }

            downloadProgress = 1
            isDownloading = false
            return modelURL
        } catch {
            isDownloading = false
            errorMessage = error.localizedDescription
            throw error
        }
    }

    private func installedModelURL(for choice: ModelChoice) -> URL? {
        let prefix = "openai_whisper-\(choice.modelName)"
        guard let enumerator = fileManager.enumerator(at: modelsDirectory,
                                                      includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles]) else {
            return nil
        }

        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix(prefix),
                  isUsableWhisperKitModel(at: url) else {
                continue
            }
            return url
        }

        return nil
    }

    private func isUsableWhisperKitModel(at url: URL) -> Bool {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            return false
        }

        let requiredPaths = [
            "AudioEncoder.mlmodelc/weights/weight.bin",
            "MelSpectrogram.mlmodelc/weights/weight.bin",
            "TextDecoder.mlmodelc/weights/weight.bin",
            "config.json",
            "generation_config.json"
        ]

        return requiredPaths.allSatisfy { relativePath in
            fileManager.fileExists(atPath: url.appendingPathComponent(relativePath).path)
        }
    }

    private func ensureModelsDirectory() throws {
        try fileManager.createDirectory(at: modelsDirectory,
                                        withIntermediateDirectories: true,
                                        attributes: nil)
    }
}
