//
//  PdfParser.swift
//  OverlayOpus
//

import Foundation
import PDFKit

struct PdfParser {
    func parse(url: URL) throws -> String {
        guard let document = PDFDocument(url: url) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        var pages: [String] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index),
                  let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                continue
            }
            pages.append(text)
        }
        return pages.joined(separator: "\n\n")
    }
}
