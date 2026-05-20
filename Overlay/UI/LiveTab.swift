//
//  LiveTab.swift
//  OverlayOpus
//

import SwiftUI

struct LiveTab: View {
    @ObservedObject private var sessionStore = CallSessionStore.shared
    @AppStorage("overlay.privacyMode") private var privacyModeRaw = PrivacyMode.providerAssisted.rawValue

    @State private var isPaused = false
    @State private var autoScroll = true
    @State private var now = Date()

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                controls
                memoryChips
            }
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

            AudioLevelMeter()
                .frame(width: 120)

            Text(sessionStore.status)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Text(privacyModeRaw == PrivacyMode.localOnly.rawValue ? "LOCAL ONLY" : "PROVIDER ASSISTED")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Capsule().fill(privacyModeRaw == PrivacyMode.localOnly.rawValue ? Color.green.opacity(0.15) : Color.blue.opacity(0.15)))
                .foregroundStyle(privacyModeRaw == PrivacyMode.localOnly.rawValue ? Color.green : Color.blue)

            Spacer()

            Toggle("Pause", isOn: $isPaused)
                .toggleStyle(.checkbox)
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

    @ViewBuilder
    private var memoryChips: some View {
        if !sessionStore.memoryItems.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(sessionStore.memoryItems.prefix(6))) { item in
                        Text("\(item.kind.rawValue): \(item.text)")
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.white.opacity(0.07)))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var transcriptView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if sessionStore.transcript.isEmpty {
                        Text("Transcript will appear here once the call starts.")
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

    private func copyAll() {
        let value = sessionStore.transcript.map { "\($0.speaker.rawValue): \($0.text)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private struct AudioLevelMeter: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(Color.green.opacity(0.65))
                    .frame(width: max(8, proxy.size.width * 0.36))
            }
        }
        .frame(height: 8)
        .help("Audio level")
    }
}
