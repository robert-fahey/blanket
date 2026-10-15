import AppKit

final class StatusMenu: NSObject {
    private let item: NSStatusItem
    private let toggleItem: NSMenuItem
    var onReset: (() -> Void)?
    var onToggle: (() -> Void)?

    override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        toggleItem = NSMenuItem(title: "Hide Rug", action: nil, keyEquivalent: "")
        super.init()

        if let image = NSImage(systemSymbolName: "rectangle.inset.filled", accessibilityDescription: "Blanket") {
            image.isTemplate = true
            item.button?.image = image
        } else {
            item.button?.title = "🧶"
        }

        let menu = NSMenu()
        let reset = NSMenuItem(title: "Reset Rug", action: #selector(resetTapped), keyEquivalent: "r")
        reset.target = self
        menu.addItem(reset)
        toggleItem.action = #selector(toggleTapped)
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Blanket", action: #selector(quitTapped), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
    }

    func setRugVisible(_ visible: Bool) {
        toggleItem.title = visible ? "Hide Rug" : "Show Rug"
    }

    @objc private func resetTapped() { onReset?() }
    @objc private func toggleTapped() { onToggle?() }
    @objc private func quitTapped() { NSApp.terminate(nil) }
}
