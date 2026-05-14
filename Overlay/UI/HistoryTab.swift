//
//  HistoryTab.swift
//  OverlayOpus
//

import SwiftUI

struct HistoryTab: View {
    @State private var query = ""
    @State private var selectedResult: SearchHistoryResult?
    @State private var results: [SearchHistoryResult] = []
    @State private var errorMessage: String?

    var body: some View {
        HSplitView {
            VStack(spacing: 10) {
                TextField("Search sessions", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await search() } }

                List(selection: $selectedResult) {
                    ForEach(results) { result in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.title)
                                .font(.system(size: 12, weight: .semibold))
                            Text(result.kind.rawValue)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        .tag(Optional(result))
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 210)
            .padding(12)

            VStack(alignment: .leading, spacing: 10) {
                if let selectedResult {
                    Text(selectedResult.title)
                        .font(.system(size: 16, weight: .semibold))
                    Text(Date(timeIntervalSince1970: TimeInterval(selectedResult.createdAt)).formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Divider().opacity(0.25)
                    Text(selectedResult.snippet)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                    Spacer()
                } else if let errorMessage {
                    Spacer()
                    Text(errorMessage)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    Spacer()
                    Text("Search or select a session")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                    Spacer()
                }
            }
            .padding(14)
            .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task {
            await search()
        }
    }

    private func search() async {
        do {
            results = try await AppDatabase.shared.searchHistory(query: query)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
