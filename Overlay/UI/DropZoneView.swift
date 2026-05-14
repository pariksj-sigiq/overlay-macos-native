//
//  DropZoneView.swift
//  OverlayOpus
//

import SwiftUI
import UniformTypeIdentifiers

struct DropZoneView: View {
    var onURLs: ([URL]) -> Void

    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 22))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
            Text("Drop documents")
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
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let itemURL = item as? URL {
                    url = itemURL
                } else {
                    url = nil
                }

                guard let url else { return }
                DispatchQueue.main.async {
                    onURLs([url])
                }
            }
        }
    }
}
