import AppKit

final class StatusMenu: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let menu = NSMenu()
    private let toggleItem: NSMenuItem
    private let styleItems: [NSMenuItem]
    private let sizeItems: [NSMenuItem]
    private let builtInItem: NSMenuItem

    var onReset: (() -> Void)?
    var onToggle: (() -> Void)?
    var onPickImage: (() -> Void)?

    override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        toggleItem = NSMenuItem(title: "Hide Rug", action: nil, keyEquivalent: "")
        styleItems = RugStyle.allCases.map { NSMenuItem(title: $0.displayName, action: nil, keyEquivalent: "") }
        sizeItems = RugSize.allCases.map { NSMenuItem(title: $0.displayName, action: nil, keyEquivalent: "") }
        builtInItem = NSMenuItem(title: "Use Built-in Rug", action: nil, keyEquivalent: "")
        super.init()

        if let image = NSImage(systemSymbolName: "rectangle.inset.filled", accessibilityDescription: "Blanket") {
            image.isTemplate = true
            item.button?.image = image
        } else {
            item.button?.title = "Rug"
        }

        let reset = NSMenuItem(title: "Reset Rug", action: #selector(resetTapped), keyEquivalent: "r")
        reset.target = self
        menu.addItem(reset)
        toggleItem.action = #selector(toggleTapped)
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())

        let rugMenu = NSMenu(title: "Rug")
        for (style, mi) in zip(RugStyle.allCases, styleItems) {
            mi.representedObject = style.rawValue
            mi.action = #selector(styleTapped(_:))
            mi.target = self
            rugMenu.addItem(mi)
        }
        rugMenu.addItem(.separator())
        let pick = NSMenuItem(title: "Use Image…", action: #selector(pickImageTapped), keyEquivalent: "")
        pick.target = self
        rugMenu.addItem(pick)
        builtInItem.action = #selector(builtInTapped)
        builtInItem.target = self
        rugMenu.addItem(builtInItem)
        let rugItem = NSMenuItem(title: "Rug", action: nil, keyEquivalent: "")
        rugItem.submenu = rugMenu
        menu.addItem(rugItem)

        let sizeMenu = NSMenu(title: "Size")
        for (size, mi) in zip(RugSize.allCases, sizeItems) {
            mi.representedObject = size.rawValue
            mi.action = #selector(sizeTapped(_:))
            mi.target = self
            sizeMenu.addItem(mi)
        }
        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Blanket", action: #selector(quitTapped), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        menu.delegate = self
        item.menu = menu
    }

    func setRugVisible(_ visible: Bool) {
        toggleItem.title = visible ? "Hide Rug" : "Show Rug"
    }

    /// Reflect the current settings in the check marks.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let usingImage = Settings.customImagePath != nil
        for (style, mi) in zip(RugStyle.allCases, styleItems) {
            mi.state = (!usingImage && style == Settings.rugStyle) ? .on : .off
        }
        builtInItem.isEnabled = usingImage
        builtInItem.state = .off
        for (size, mi) in zip(RugSize.allCases, sizeItems) {
            mi.state = size == Settings.rugSize ? .on : .off
        }
    }

    @objc private func resetTapped() { onReset?() }
    @objc private func toggleTapped() { onToggle?() }
    @objc private func pickImageTapped() { onPickImage?() }
    @objc private func quitTapped() { NSApp.terminate(nil) }

    @objc private func styleTapped(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = RugStyle(rawValue: raw) else { return }
        Settings.customImagePath = nil
        Settings.rugStyle = style
    }

    @objc private func builtInTapped() {
        Settings.customImagePath = nil
    }

    @objc private func sizeTapped(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let size = RugSize(rawValue: raw) else { return }
        Settings.rugSize = size
    }
}
