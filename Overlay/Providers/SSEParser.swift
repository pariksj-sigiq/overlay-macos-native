//
//  SSEParser.swift
//  OverlayOpus
//

import Foundation

struct SSEParser {
    private var buffer = ""

    mutating func feed(_ data: Data) throws -> [String] {
        guard let chunk = String(data: data, encoding: .utf8) else {
            throw LLMProviderError.invalidResponse("SSE stream contained non-UTF8 data")
        }
        return feed(chunk)
    }

    mutating func feed(_ chunk: String) -> [String] {
        buffer += chunk.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var events: [String] = []
        while let range = buffer.range(of: "\n\n") {
            let rawEvent = String(buffer[..<range.lowerBound])
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)

            if let event = parseEvent(rawEvent) {
                events.append(event)
            }
        }
        return events
    }

    mutating func finish() -> [String] {
        guard !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            buffer = ""
            return []
        }

        let rawEvent = buffer
        buffer = ""
        guard let event = parseEvent(rawEvent) else { return [] }
        return [event]
    }

    private func parseEvent(_ rawEvent: String) -> String? {
        let payload = rawEvent
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { line -> String? in
                if line.hasPrefix(":") {
                    return nil
                }
                if line.hasPrefix("data:") {
                    let value = line.dropFirst(5)
                    if value.hasPrefix(" ") {
                        return String(value.dropFirst())
                    }
                    return String(value)
                }
                return nil
            }
            .joined(separator: "\n")

        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "[DONE]" else { return nil }
        return payload
    }
}

