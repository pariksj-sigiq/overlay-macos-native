//
//  SessionExportService.swift
//  OverlayOpus
//

import Foundation

struct SessionExportService {
    func export(sessionID: String) async throws -> URL {
        let snapshot = try await AppDatabase.shared.exportSnapshot(sessionID: sessionID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let url = directory.appendingPathComponent("overlay-session-\(sessionID).json")
        try data.write(to: url, options: [.atomic])
        return url
    }
}
