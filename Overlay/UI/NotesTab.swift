//
//  NotesTab.swift
//  OverlayOpus
//

import SwiftUI

struct NotesTab: View {
    @ObservedObject var notesStore: NotesStore

    @AppStorage("overlay.fontSize") private var fontSize: Double = 14
    @AppStorage("overlay.markdownRender") private var markdownRender: Bool = false

    var body: some View {
        Group {
            if markdownRender {
                MarkdownView(text: notesStore.text, fontSize: fontSize)
            } else {
                TextEditor(text: $notesStore.text)
                    .font(.system(size: fontSize, weight: .regular, design: .monospaced))
                    .foregroundColor(.primary)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 10)
            }
        }
    }
}
