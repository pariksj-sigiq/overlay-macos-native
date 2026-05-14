//
//  DocxParser.swift
//  OverlayOpus
//

import Foundation

final class DocxParser: NSObject, XMLParserDelegate {

    private var textRuns: [String] = []
    private var currentText = ""
    private var isInsideTextNode = false

    func parse(url: URL) throws -> String {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OverlayOpusDocx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory,
                                                withIntermediateDirectories: true,
                                                attributes: nil)
        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        try unzip(docxURL: url, into: tempDirectory)

        let documentXML = tempDirectory
            .appendingPathComponent("word", isDirectory: true)
            .appendingPathComponent("document.xml", isDirectory: false)
        let data = try Data(contentsOf: documentXML)

        textRuns = []
        currentText = ""
        isInsideTextNode = false

        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else {
            throw parser.parserError ?? CocoaError(.fileReadCorruptFile)
        }

        return textRuns
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func unzip(docxURL: URL, into destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-qq", docxURL.path, "-d", destination.path]

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        if elementName == "w:t" {
            isInsideTextNode = true
            currentText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard isInsideTextNode else { return }
        currentText += string
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        if elementName == "w:t" {
            textRuns.append(currentText)
            currentText = ""
            isInsideTextNode = false
        } else if elementName == "w:p" {
            textRuns.append("\n")
        }
    }
}
