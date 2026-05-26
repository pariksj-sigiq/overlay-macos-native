//
//  NotesStore.swift
//  Overlay
//
//  Persists encrypted overlay note text to
//  ~/Library/Application Support/Overlay/notes.txt
//  Autosaves on change with a 0.5s debounce.
//

import Foundation
import Combine

final class NotesStore: ObservableObject {

    // MARK: - Singleton

    static let shared = NotesStore()

    // MARK: - Published state

    @Published var text: String = ""

    // MARK: - Internals

    private var cancellables = Set<AnyCancellable>()
    private let ioQueue = DispatchQueue(label: "com.overlay.notesstore.io", qos: .utility)
    private let fileManager = FileManager.default

    /// Flag used to suppress the initial debounce write that would otherwise
    /// fire right after we load the on-disk contents into `text`.
    private var didLoadInitial = false

    // MARK: - Paths

    /// ~/Library/Application Support/Overlay
    private var storageDirectory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory,
                                    in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support",
                                        isDirectory: true)
        return base.appendingPathComponent("Overlay", isDirectory: true)
    }

    /// ~/Library/Application Support/Overlay/notes.txt
    private var storageURL: URL {
        storageDirectory.appendingPathComponent("notes.txt", isDirectory: false)
    }

    // MARK: - Init

    private init() {
        ensureDirectoryExists()
        loadFromDisk()
        bindAutosave()
    }

    // MARK: - Directory

    private func ensureDirectoryExists() {
        let dir = storageDirectory
        if !fileManager.fileExists(atPath: dir.path) {
            do {
                try fileManager.createDirectory(at: dir,
                                                withIntermediateDirectories: true,
                                                attributes: nil)
            } catch {
                #if DEBUG
                print("NotesStore: failed to create storage dir")
                #endif
            }
        }
    }

    // MARK: - Load

    private func loadFromDisk() {
        let url = storageURL
        if let data = try? Data(contentsOf: url),
           let storedText = String(data: data, encoding: .utf8) {
            let protector = LocalDataProtector.shared
            self.text = protector.decryptString(storedText)
            if !protector.isEncryptedString(storedText), !storedText.isEmpty {
                saveAsync(self.text)
            }
        } else {
            self.text = ""
        }
        didLoadInitial = true
    }

    // MARK: - Autosave

    private func bindAutosave() {
        $text
            .dropFirst() // ignore the value we set during load
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] newValue in
                guard let self = self, self.didLoadInitial else { return }
                self.saveAsync(newValue)
            }
            .store(in: &cancellables)
    }

    private func saveAsync(_ value: String) {
        let url = storageURL
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            self.ensureDirectoryExists()
            do {
                let encrypted = try LocalDataProtector.shared.encryptString(value)
                let data = Data(encrypted.utf8)
                try data.write(to: url, options: [.atomic])
            } catch {
                #if DEBUG
                print("NotesStore: failed to protect notes")
                #endif
            }
        }
    }

    // MARK: - Public helpers

    /// Force a synchronous flush to disk. Useful from app-termination paths.
    func flush() {
        let value = self.text
        let url = storageURL
        ensureDirectoryExists()
        guard let encrypted = try? LocalDataProtector.shared.encryptString(value) else { return }
        try? Data(encrypted.utf8).write(to: url, options: [.atomic])
    }
}
