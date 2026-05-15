//
//  LiveTab.swift
//  OverlayOpus
//

import SwiftUI

struct LiveTab: View {
    @ObservedObject private var sessionStore = CallSessionStore.shared

    @State private var isPaused = false
    @State private var autoScroll = true
    @State private var now = Date()

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            controls
                .padding(12)
            Divider().opacity(0.25)
            transcriptView
        }
        .onReceive(timer) { date in
            now = date
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button(action: sessionStore.toggleRecording) {
                Label(sessionStore.isRecording ? "Stop" : "Record",
                      systemImage: sessionStore.isRecording ? "stop.circle.fill" : "record.circle")
                    .foregroundStyle(sessionStore.isRecording ? Color.red : Color.primary)
            }
            .buttonStyle(.bordered)
            .disabled(sessionStore.activeSession == nil)

            Text(elapsedText)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)

            AudioLevelMeter(level: sessionStore.audioLevel)
                .frame(width: 120)

            Text(sessionStore.status)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Spacer()

            Toggle("Auto-scroll", isOn: $autoScroll)
                .toggleStyle(.checkbox)

            Button(action: copyAll) {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy all transcript")
        }
        .font(.system(size: 12))
    }

    private var transcriptView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let error = sessionStore.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.orange)
                            .padding(12)
                    } else if sessionStore.transcript.isEmpty {
                        Text(emptyTranscriptText)
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .padding(12)
                    }

                    ForEach(sessionStore.transcript) { chunk in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(chunk.speaker.rawValue)
                                    .font(.system(size: 11, weight: .semibold))
                                Text(Date(timeIntervalSince1970: TimeInterval(chunk.ts) / 1000), style: .time)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                            Text(chunk.text)
                                .font(.system(size: 13))
                                .textSelection(.enabled)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                        .id(chunk.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: sessionStore.transcript.count) {
                guard autoScroll, !isPaused, let last = sessionStore.transcript.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private var elapsedText: String {
        guard let createdAt = sessionStore.activeSession?.createdAt else { return "00:00" }
        let start = Date(timeIntervalSince1970: TimeInterval(createdAt))
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private var emptyTranscriptText: String {
        if sessionStore.activeSession == nil {
            return "Start a call from Brief before recording."
        }
        if sessionStore.isRecording {
            return "Listening. Transcript appears after local Whisper returns text."
        }
        return "Recording is paused."
    }

    private func copyAll() {
        let value = sessionStore.transcript.map { "\($0.speaker.rawValue): \($0.text)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private struct AudioLevelMeter: View {
    var level: Float

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(Color.green.opacity(0.65))
                    .frame(width: max(4, proxy.size.width * CGFloat(max(0, min(1, level)))))
            }
        }
        .frame(height: 8)
        .help("Audio level")
    }
}
