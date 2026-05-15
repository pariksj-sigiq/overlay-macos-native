//
//  DropZoneView.swift
//  OverlayOpus
//

import SwiftUI
import UniformTypeIdentifiers

struct DropZoneView: View {
    var onURLs: ([URL]) -> Void

    @State private var isTargeted = false
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: isLoading ? "doc.badge.clock" : "tray.and.arrow.down")
                .font(.system(size: 22))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
            Text(isLoading ? "Reading drop" : "Drop documents")
                .font(.system(size: 13, weight: .semibold))
            Text("PDF, DOCX, Markdown, TXT")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isTargeted ? Color.accentColor.opacity(0.12) : Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isTargeted ? Color.accentColor.opacity(0.7) : Color.white.opacity(0.1), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
        )
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            loadFileURLs(from: providers)
            return true
        }
    }

    private func loadFileURLs(from providers: [NSItemProvider]) {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return }

        isLoading = true

        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        for provider in fileProviders {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let itemURL = item as? URL {
                    url = itemURL
                } else {
                    url = nil
                }

                guard let url else { return }
                lock.lock()
                urls.append(url)
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            isLoading = false
            if !urls.isEmpty {
                onURLs(urls)
            }
        }
    }
}
