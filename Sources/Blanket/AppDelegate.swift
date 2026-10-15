import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: OverlayWindow?
    private var rugView: RugView?
    private var statusMenu: StatusMenu?
    private var hoverTimer: Timer?
    private var rugVisible = true
    private var debugDriver: DebugDriver?
    private var appliedSource: RugSource?
    private var appliedSize: RugSize?
    private let assetQueue = DispatchQueue(label: "blanket.assets", qos: .userInitiated)

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        let assets = RugAssets.current()
        appliedSource = assets.source
        appliedSize = Settings.rugSize
        let window = OverlayWindow(screen: screen)
        let rugView = RugView(frame: NSRect(origin: .zero, size: screen.frame.size),
                              config: RugConfig(assets: assets, coverage: Settings.rugSize.coverage))
        rugView.autoresizingMask = [.width, .height]
        window.contentView = rugView
        self.window = window
        self.rugView = rugView

        let menu = StatusMenu()
        menu.onReset = { [weak self] in self?.rugView?.reset() }
        menu.onToggle = { [weak self] in self?.toggleRug() }
        menu.onPickImage = { [weak self] in self?.pickImage() }
        statusMenu = menu

        rugVisible = !Settings.rugHidden || DebugDriver.isEnabled
        if rugVisible { window.orderFrontRegardless() }
        menu.setRugVisible(rugVisible)

        // Poll the cursor and make the window click-through wherever there is no fabric.
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.updateClickThrough()
        }
        hoverTimer?.tolerance = 0.01

        if let driver = DebugDriver(view: rugView) {
            debugDriver = driver
            driver.start()
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged),
            name: Settings.didChange, object: nil
        )
    }

    private func updateClickThrough() {
        guard let window, let rugView, rugVisible else { return }
        let screenPoint = NSEvent.mouseLocation
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let viewPoint = rugView.convert(windowPoint, from: nil)
        let overFabric = rugView.isDragging || rugView.isPointOverCloth(viewPoint)
        if window.ignoresMouseEvents == overFabric {
            window.ignoresMouseEvents = !overFabric
        }
    }

    private func toggleRug() {
        guard let window else { return }
        rugVisible.toggle()
        Settings.rugHidden = !rugVisible
        if rugVisible {
            window.orderFrontRegardless()
            rugView?.resume()
        } else {
            window.orderOut(nil)
        }
        statusMenu?.setRugVisible(rugVisible)
    }

    /// Rebuild the rug when its source or size changed. Textures are made off the main thread.
    @objc private func settingsChanged() {
        let source = Settings.rugSource
        let size = Settings.rugSize
        guard source != appliedSource || size != appliedSize else { return }
        appliedSource = source
        appliedSize = size
        assetQueue.async { [weak self] in
            let assets = RugAssets.current()
            DispatchQueue.main.async {
                guard let self, let rugView = self.rugView else { return }
                // A failed image load falls back to the style; record that so we don't loop.
                self.appliedSource = assets.source
                rugView.apply(RugConfig(assets: assets, coverage: size.coverage))
            }
        }
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.title = "Choose a rug image"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            Settings.customImagePath = url.path
        }
    }

    @objc private func screenParametersChanged() {
        guard let window, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        if window.frame != screen.frame {
            window.setFrame(screen.frame, display: true)
            rugView?.viewportChanged(to: screen.frame.size)
        }
    }
}
