import AppKit
import Foundation

/// Owns the menu bar `NSStatusItem` and its dropdown menu.
///
/// Keep a strong reference to an instance of this class for the lifetime of the app;
/// releasing it removes the icon from the menu bar.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {

    // MARK: - State

    private let statusItem: NSStatusItem
    private let toggleVisibility: () -> Void
    private let startStopCall: () -> Void

    private var pinMenuItem: NSMenuItem?
    private var markdownMenuItem: NSMenuItem?
    private var startStopMenuItem: NSMenuItem?
    private var focusModeItems: [FocusMode: NSMenuItem] = [:]

    // MARK: - Init

    init(toggleVisibility: @escaping () -> Void,
         startStopCall: @escaping () -> Void = {}) {
        self.toggleVisibility = toggleVisibility
        self.startStopCall = startStopCall
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureButton()
        statusItem.menu = buildMenu()
    }

    deinit {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    // MARK: - Button

    private func configureButton() {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Overlay")
        image?.isTemplate = true
        button.image = image
        button.toolTip = "Overlay-Opus"
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        // Show/Hide Overlay — ⌘⇧\
        let toggleItem = NSMenuItem(
            title: "Show/Hide Overlay",
            action: #selector(toggleOverlayAction(_:)),
            keyEquivalent: "\\"
        )
        toggleItem.target = self
        toggleItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        let startStopItem = NSMenuItem(
            title: "Start/Stop Call",
            action: #selector(startStopCallAction(_:)),
            keyEquivalent: "r"
        )
        startStopItem.target = self
        startStopItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(startStopItem)
        self.startStopMenuItem = startStopItem

        menu.addItem(.separator())

        // Focus Mode submenu — the critical escape hatch from click-through.
        let focusHeader = NSMenuItem(title: "Focus Mode", action: nil, keyEquivalent: "")
        let focusSubmenu = NSMenu()
        focusSubmenu.autoenablesItems = false
        for (index, mode) in FocusMode.allCases.enumerated() {
            let item = NSMenuItem(
                title: mode.label,
                action: #selector(setFocusModeAction(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = index
            item.toolTip = mode.description
            item.state = (FocusModeStore.shared.mode == mode) ? .on : .off
            focusSubmenu.addItem(item)
            focusModeItems[mode] = item
        }
        focusSubmenu.addItem(.separator())
        let cycleItem = NSMenuItem(
            title: "Cycle Focus Mode",
            action: #selector(cycleFocusModeAction(_:)),
            keyEquivalent: "l"
        )
        cycleItem.target = self
        cycleItem.keyEquivalentModifierMask = [.command, .shift]
        focusSubmenu.addItem(cycleItem)

        menu.setSubmenu(focusSubmenu, for: focusHeader)
        menu.addItem(focusHeader)

        menu.addItem(.separator())

        // Pin on Top — checkmark reflects PinState.shared.isPinned
        let pinItem = NSMenuItem(
            title: "Pin on Top",
            action: #selector(togglePinAction(_:)),
            keyEquivalent: ""
        )
        pinItem.target = self
        pinItem.state = PinState.shared.isPinned ? .on : .off
        menu.addItem(pinItem)
        self.pinMenuItem = pinItem

        // Render Markdown — ⌘⇧M
        let mdItem = NSMenuItem(
            title: "Render Markdown",
            action: #selector(toggleMarkdownAction(_:)),
            keyEquivalent: "m"
        )
        mdItem.target = self
        mdItem.keyEquivalentModifierMask = [.command, .shift]
        mdItem.state = UserDefaults.standard.bool(forKey: "overlay.markdownRender") ? .on : .off
        menu.addItem(mdItem)
        self.markdownMenuItem = mdItem

        menu.addItem(.separator())

        // Quit — ⌘Q
        let quitItem = NSMenuItem(
            title: "Quit",
            action: #selector(quitAction(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        quitItem.keyEquivalentModifierMask = [.command]
        menu.addItem(quitItem)

        return menu
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        pinMenuItem?.state = PinState.shared.isPinned ? .on : .off
        markdownMenuItem?.state = UserDefaults.standard.bool(forKey: "overlay.markdownRender") ? .on : .off
        startStopMenuItem?.title = CallSessionStore.shared.isRecording ? "Stop Call Recording" : "Start Call Recording"
        let current = FocusModeStore.shared.mode
        for (mode, item) in focusModeItems {
            item.state = (mode == current) ? .on : .off
        }
    }

    // MARK: - Actions

    @objc private func toggleOverlayAction(_ sender: NSMenuItem) {
        toggleVisibility()
    }

    @objc private func startStopCallAction(_ sender: NSMenuItem) {
        startStopCall()
    }

    @objc private func togglePinAction(_ sender: NSMenuItem) {
        PinState.shared.isPinned.toggle()
        sender.state = PinState.shared.isPinned ? .on : .off
    }

    @objc private func toggleMarkdownAction(_ sender: NSMenuItem) {
        let defaults = UserDefaults.standard
        let next = !defaults.bool(forKey: "overlay.markdownRender")
        defaults.set(next, forKey: "overlay.markdownRender")
        sender.state = next ? .on : .off
    }

    @objc private func setFocusModeAction(_ sender: NSMenuItem) {
        let all = FocusMode.allCases
        guard sender.tag >= 0, sender.tag < all.count else { return }
        FocusModeStore.shared.mode = all[sender.tag]
        let current = FocusModeStore.shared.mode
        for (mode, item) in focusModeItems {
            item.state = (mode == current) ? .on : .off
        }
    }

    @objc private func cycleFocusModeAction(_ sender: NSMenuItem) {
        FocusModeStore.shared.cycle()
        let current = FocusModeStore.shared.mode
        for (mode, item) in focusModeItems {
            item.state = (mode == current) ? .on : .off
        }
    }

    @objc private func quitAction(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }
}
