//
//  MarkdownView.swift
//  OverlayOpus
//
//  Renders the notes as markdown when the user toggles render mode on.
//  Uses AttributedString's built-in markdown parser (macOS 12+) for
//  inline formatting + heading/list styling done manually line-by-line.
//

import SwiftUI
import AppKit

struct MarkdownView: View {
    let text: String
    let fontSize: CGFloat
    var scrollCommand: NotesScrollCommand? = nil

    var body: some View {
        MarkdownScrollView(
            text: text,
            fontSize: fontSize,
            scrollCommand: scrollCommand
        )
    }
}

private struct MarkdownRenderedContent: View {
    let text: String
    let fontSize: CGFloat
    let availableWidth: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                renderedBlock(block)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: max(availableWidth, 1), alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Block parsing

    private enum Block {
        case heading(level: Int, text: String)
        case bullet(text: String, indent: Int)
        case numbered(number: String, text: String, indent: Int)
        case code(String)
        case quote(String)
        case hrule
        case paragraph(String)
        case blank
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var inCode = false
        var codeBuffer: [String] = []

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine

            // Fenced code block toggle.
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode {
                    result.append(.code(codeBuffer.joined(separator: "\n")))
                    codeBuffer.removeAll()
                    inCode = false
                } else {
                    inCode = true
                }
                continue
            }
            if inCode {
                codeBuffer.append(line)
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                result.append(.blank); continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                result.append(.hrule); continue
            }
            // Headings.
            if let headingLevel = headingLevel(of: trimmed) {
                let text = String(trimmed.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
                result.append(.heading(level: headingLevel, text: text)); continue
            }
            // Blockquote.
            if trimmed.hasPrefix(">") {
                result.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
                continue
            }
            // Bulleted list.
            let leading = line.prefix(while: { $0 == " " || $0 == "\t" })
            let indentLevel = leading.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                result.append(.bullet(text: String(trimmed.dropFirst(2)), indent: indentLevel))
                continue
            }
            // Numbered list.
            if let match = numberedPrefix(trimmed) {
                result.append(.numbered(number: match.0, text: match.1, indent: indentLevel))
                continue
            }
            result.append(.paragraph(trimmed))
        }
        if inCode && !codeBuffer.isEmpty {
            result.append(.code(codeBuffer.joined(separator: "\n")))
        }
        return result
    }

    private func headingLevel(of line: String) -> Int? {
        var count = 0
        for ch in line {
            if ch == "#" { count += 1 } else { break }
        }
        guard count > 0, count <= 6 else { return nil }
        // Must be followed by a space.
        let rest = line.dropFirst(count)
        return rest.first == " " ? count : nil
    }

    private func numberedPrefix(_ s: String) -> (String, String)? {
        var digits = ""
        var rest = s
        while let ch = rest.first, ch.isNumber {
            digits.append(ch)
            rest.removeFirst()
        }
        guard !digits.isEmpty, rest.hasPrefix(". ") else { return nil }
        return (digits, String(rest.dropFirst(2)))
    }

    // MARK: - Rendering

    @ViewBuilder
    private func renderedBlock(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let t):
            Text(inline(t))
                .font(.system(size: headingSize(level), weight: .bold))
                .padding(.top, level <= 2 ? 6 : 2)
        case .bullet(let t, let indent):
            HStack(alignment: .top, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                Text(inline(t)).font(.system(size: fontSize))
            }
            .padding(.leading, CGFloat(indent) * 14)
        case .numbered(let n, let t, let indent):
            HStack(alignment: .top, spacing: 6) {
                Text("\(n).").foregroundStyle(.secondary).monospaced()
                Text(inline(t)).font(.system(size: fontSize))
            }
            .padding(.leading, CGFloat(indent) * 14)
        case .code(let c):
            Text(c)
                .font(.system(size: fontSize - 1, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.black.opacity(0.25))
                )
        case .quote(let t):
            HStack(spacing: 8) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.6))
                    .frame(width: 2)
                Text(inline(t))
                    .italic()
                    .foregroundStyle(.secondary)
                    .font(.system(size: fontSize))
            }
        case .hrule:
            Divider().opacity(0.5).padding(.vertical, 4)
        case .paragraph(let p):
            Text(inline(p)).font(.system(size: fontSize))
        case .blank:
            Spacer().frame(height: 4)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return fontSize + 9
        case 2: return fontSize + 6
        case 3: return fontSize + 4
        case 4: return fontSize + 2
        default: return fontSize + 1
        }
    }

    private func inline(_ s: String) -> AttributedString {
        // AttributedString's markdown parser handles **bold**, *italic*,
        // `code`, [links](url), ~~strike~~ inline.
        if let attr = try? AttributedString(markdown: s,
            options: AttributedString.MarkdownParsingOptions(
                allowsExtendedAttributes: true,
                interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return attr
        }
        return AttributedString(s)
    }
}

private struct MarkdownScrollView: NSViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let scrollCommand: NotesScrollCommand?

    private static let fallbackWidth: CGFloat = 480

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.scrollsDynamically = true

        let hostingView = HardenedHostingView(
            rootView: MarkdownRenderedContent(
                text: text,
                fontSize: fontSize,
                availableWidth: Self.contentWidth(in: scrollView)
            )
        )
        hostingView.autoresizingMask = [.width]
        hostingView.wantsLayer = true
        scrollView.documentView = hostingView

        NotesScrollBridge.register(scrollView)
        Self.updateDocumentSize(hostingView, in: scrollView, text: text, fontSize: fontSize)
        PrivacyHardeningController.shared.apply(to: scrollView)
        DispatchQueue.main.async { [weak scrollView, weak hostingView] in
            guard let scrollView, let hostingView else { return }
            Self.updateDocumentSize(hostingView, in: scrollView, text: text, fontSize: fontSize)
            PrivacyHardeningController.shared.apply(to: scrollView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let hostingView = scrollView.documentView as? NSHostingView<MarkdownRenderedContent> else {
            return
        }

        NotesScrollBridge.register(scrollView)
        Self.updateDocumentSize(hostingView, in: scrollView, text: text, fontSize: fontSize)
        PrivacyHardeningController.shared.apply(to: scrollView)

        guard let command = scrollCommand,
              context.coordinator.lastScrollCommandID != command.id else {
            return
        }
        context.coordinator.lastScrollCommandID = command.id
        NotesScrollBridge.scroll(scrollView, direction: command.direction)
    }

    private static func updateDocumentSize(
        _ hostingView: NSHostingView<MarkdownRenderedContent>,
        in scrollView: NSScrollView,
        text: String,
        fontSize: CGFloat
    ) {
        scrollView.layoutSubtreeIfNeeded()
        let previousOrigin = scrollView.contentView.bounds.origin
        let visibleSize = scrollView.contentSize
        let width = contentWidth(in: scrollView)

        hostingView.rootView = MarkdownRenderedContent(
            text: text,
            fontSize: fontSize,
            availableWidth: width
        )
        hostingView.frame = NSRect(origin: .zero, size: NSSize(width: width, height: 10))
        hostingView.layoutSubtreeIfNeeded()
        let fittingSize = hostingView.fittingSize
        let height = max(visibleSize.height, ceil(fittingSize.height))
        hostingView.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
        restoreScrollOrigin(previousOrigin, in: scrollView)
    }

    private static func contentWidth(in scrollView: NSScrollView) -> CGFloat {
        let contentWidth = max(scrollView.contentView.bounds.width, scrollView.contentSize.width)
        return contentWidth > 100 ? contentWidth : fallbackWidth
    }

    private static func restoreScrollOrigin(_ origin: NSPoint, in scrollView: NSScrollView) {
        guard let documentView = scrollView.documentView else { return }
        let clipView = scrollView.contentView
        let maxX = max(0, documentView.bounds.width - clipView.bounds.width)
        let maxY = max(0, documentView.bounds.height - clipView.bounds.height)
        let restoredOrigin = NSPoint(
            x: min(max(0, origin.x), maxX),
            y: min(max(0, origin.y), maxY)
        )
        clipView.scroll(to: restoredOrigin)
        scrollView.reflectScrolledClipView(clipView)
    }

    final class Coordinator {
        var lastScrollCommandID: UUID?
    }
}
