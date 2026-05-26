//
//  NotesTab.swift
//  OverlayOpus
//

import SwiftUI
import AppKit

enum NotesScrollDirection {
    case up
    case down
    case left
    case right
}

enum NotesScrollBridge {
    private static weak var activeScrollView: NSScrollView?

    static func register(_ scrollView: NSScrollView) {
        activeScrollView = scrollView
    }

    @discardableResult
    static func scroll(_ direction: NotesScrollDirection) -> Bool {
        guard let scrollView = activeScrollView else {
            return false
        }
        scroll(scrollView, direction: direction)
        return true
    }

    static func scroll(_ scrollView: NSScrollView, direction: NotesScrollDirection) {
        scrollView.layoutSubtreeIfNeeded()
        guard let documentView = scrollView.documentView else { return }

        let clipView = scrollView.contentView
        var origin = clipView.bounds.origin
        let horizontalStep = max(80, clipView.bounds.width * 0.65)
        let verticalStep = max(80, clipView.bounds.height * 0.65)

        switch direction {
        case .up:
            origin.y -= verticalStep
        case .down:
            origin.y += verticalStep
        case .left:
            origin.x -= horizontalStep
        case .right:
            origin.x += horizontalStep
        }

        let maxX = max(0, documentView.bounds.width - clipView.bounds.width)
        let maxY = max(0, documentView.bounds.height - clipView.bounds.height)
        origin.x = min(max(0, origin.x), maxX)
        origin.y = min(max(0, origin.y), maxY)

        clipView.scroll(to: origin)
        scrollView.reflectScrolledClipView(clipView)
    }
}

struct NotesScrollCommand: Equatable {
    let id = UUID()
    let direction: NotesScrollDirection
}

struct NotesTab: View {
    @ObservedObject var notesStore: NotesStore
    @ObservedObject private var commandStore = AppCommandStore.shared

    @AppStorage("overlay.fontSize") private var fontSize: Double = 14
    @AppStorage("overlay.markdownRender") private var markdownRender: Bool = false

    var body: some View {
        Group {
            if markdownRender {
                MarkdownView(
                    text: notesStore.text,
                    fontSize: fontSize,
                    scrollCommand: commandStore.notesScrollCommand
                )
            } else {
                NotesTextEditor(
                    text: $notesStore.text,
                    fontSize: fontSize,
                    scrollCommand: commandStore.notesScrollCommand
                )
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 10)
            }
        }
    }
}

private struct NotesTextEditor: NSViewRepresentable {
    @Binding var text: String
    let fontSize: Double
    let scrollCommand: NotesScrollCommand?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = HardenedTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false

        scrollView.documentView = textView
        NotesScrollBridge.register(scrollView)
        Self.updateDocumentSize(textView, in: scrollView)
        PrivacyHardeningController.shared.apply(to: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        NotesScrollBridge.register(scrollView)
        PrivacyHardeningController.shared.apply(to: scrollView)
        context.coordinator.text = $text
        if textView.string != text {
            let selectedRanges = Self.validSelectedRanges(textView.selectedRanges, textLength: (text as NSString).length)
            textView.string = text
            textView.selectedRanges = selectedRanges
        }
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        Self.updateDocumentSize(textView, in: scrollView)

        guard let command = scrollCommand,
              context.coordinator.lastScrollCommandID != command.id else {
            return
        }
        context.coordinator.lastScrollCommandID = command.id
        Self.scroll(scrollView, direction: command.direction)
    }

    static func scroll(_ scrollView: NSScrollView, direction: NotesScrollDirection) {
        NotesScrollBridge.scroll(scrollView, direction: direction)
    }

    private static func updateDocumentSize(_ textView: NSTextView, in scrollView: NSScrollView) {
        guard let textContainer = textView.textContainer else { return }

        let previousOrigin = scrollView.contentView.bounds.origin
        let visibleSize = scrollView.contentSize
        let padding: CGFloat = 24
        let font = textView.font ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let longestLineWidth = textView.string
            .components(separatedBy: .newlines)
            .map { ($0 as NSString).size(withAttributes: attributes).width }
            .max() ?? 0
        let width = max(visibleSize.width, ceil(longestLineWidth + padding))

        textContainer.containerSize = NSSize(
            width: width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.layoutManager?.ensureLayout(for: textContainer)
        let usedRect = textView.layoutManager?.usedRect(for: textContainer) ?? .zero
        let height = max(visibleSize.height, ceil(usedRect.height + textView.textContainerInset.height * 2 + padding))
        textView.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
        Self.restoreScrollOrigin(previousOrigin, in: scrollView)
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

    private static func validSelectedRanges(_ ranges: [NSValue], textLength: Int) -> [NSValue] {
        let valid = ranges.filter { value in
            let range = value.rangeValue
            return range.location != NSNotFound && range.location + range.length <= textLength
        }
        return valid.isEmpty ? [NSValue(range: NSRange(location: 0, length: 0))] : valid
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var lastScrollCommandID: UUID?

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}

private final class HardenedTextView: NSTextView {
    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        if becameFirstResponder {
            SecureInputManager.shared.enable()
        }
        return becameFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let resignedFirstResponder = super.resignFirstResponder()
        if let overlayWindow = window as? OverlayWindow {
            overlayWindow.refreshPrivacyHardeningState()
        } else {
            SecureInputManager.shared.disable()
        }
        return resignedFirstResponder
    }

    override func didChangeText() {
        super.didChangeText()
        PrivacyHardeningController.shared.apply(to: self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        PrivacyHardeningController.shared.apply(to: self)
    }

    override func accessibilityChildren() -> [Any]? {
        []
    }

    override func accessibilityLabel() -> String? {
        ""
    }

    override func accessibilitySelectedText() -> String? {
        nil
    }

    override func accessibilityString(for range: NSRange) -> String? {
        nil
    }

    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        nil
    }

    override func accessibilityNumberOfCharacters() -> Int {
        0
    }

    override func copy(_ sender: Any?) {}

    override func cut(_ sender: Any?) {}

    override func pasteAsPlainText(_ sender: Any?) {
        paste(sender)
    }

    override func pasteAsRichText(_ sender: Any?) {
        paste(sender)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        nil
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)),
             #selector(cut(_:)),
             #selector(selectAll(_:)):
            return false
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        false
    }

    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        false
    }

    override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        if sendType != nil {
            return nil
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }
}
