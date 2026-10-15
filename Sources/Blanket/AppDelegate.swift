import AppKit
import ServiceManagement
import UniformTypeIdentifiers

/// One rug per display.
final class ScreenRug {
    let window: OverlayWindow
    let view: RugView
    let frame: NSRect
    let stateKey: String

    init(screen: NSScreen, assets: RugAssets) {
        frame = screen.frame
        stateKey = ScreenRug.stateKey(for: screen.frame)
        window = OverlayWindow(screen: screen)
        var config = RugConfig(assets: assets, coverage: Settings.rugSize.coverage)
        config.restore = RugStateStore.load(key: stateKey)
        view = RugView(frame: NSRect(origin: .zero, size: screen.frame.size), config: config)
        view.autoresizingMask = [.width, .height]
        window.contentView = view
    }

    static func stateKey(for frame: NSRect) -> String {
        "\(Int(frame.width))x\(Int(frame.height))@\(Int(frame.minX)),\(Int(frame.minY))"
    }

    func saveState() {
        let shape = view.currentShape()
        RugStateStore.save(positions: shape.positions, cols: shape.cols, rows: shape.rows, key: stateKey)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var rugs: [ScreenRug] = []
    private var statusMenu: StatusMenu?
    private var hoverTimer: Timer?
    private var rugVisible = true
    private var debugDriver: DebugDriver?
    private var hotKey: HotKey?
    private var appliedSource: RugSource?
    private var appliedSize: RugSize?
    private let assetQueue = DispatchQueue(label: "blanket.assets", qos: .userInitiated)

    func applicationDidFinishLaunching(_ notification: Notification) {
        appliedSource = Settings.rugSource
        appliedSize = Settings.rugSize
        rugVisible = !Settings.rugHidden || DebugDriver.isEnabled
        rebuildScreens()

        let menu = StatusMenu()
        menu.onReset = { [weak self] in self?.resetAll() }
        menu.onToggle = { [weak self] in self?.toggleRug() }
        menu.onPickImage = { [weak self] in self?.pickImage() }
        menu.onLaunchAtLoginToggle = { [weak self] in self?.toggleLaunchAtLogin() }
        menu.launchAtLoginState = { AppDelegate.launchAtLoginState() }
        menu.setRugVisible(rugVisible)
        statusMenu = menu

        hotKey = HotKey(keyCode: HotKey.keyR, modifiers: HotKey.controlOptionCommand) { [weak self] in self?.resetAll() }

        // Poll the cursor and make the windows click-through wherever there is no fabric.
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.updateClickThrough()
        }
        hoverTimer?.tolerance = 0.01

        if let main = rugs.first, let driver = DebugDriver(view: main.view) {
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

    func applicationWillTerminate(_ notification: Notification) {
        rugs.forEach { $0.saveState() }
    }

    // MARK: - Screens

    /// Create a rug for every display, keeping the ones whose display is unchanged.
    private func rebuildScreens() {
        let screens = NSScreen.screens
        let keep = rugs.filter { rug in screens.contains { $0.frame == rug.frame } }
        for gone in rugs where !keep.contains(where: { $0 === gone }) {
            gone.saveState()
            gone.window.orderOut(nil)
            gone.window.close()
        }
        var result = keep
        let assets = RugAssets.current()
        // Main display first so the debug driver and ordering are predictable.
        let ordered = screens.sorted { a, _ in a == NSScreen.main }
        for screen in ordered where !result.contains(where: { $0.frame == screen.frame }) {
            let rug = ScreenRug(screen: screen, assets: assets)
            rug.view.onSettle = { [weak rug] in rug?.saveState() }
            if rugVisible { rug.window.orderFrontRegardless() }
            result.append(rug)
        }
        rugs = result.sorted { a, _ in a.frame == NSScreen.main?.frame }
    }

    @objc private func screenParametersChanged() {
        rebuildScreens()
    }

    // MARK: - Interaction

    private func updateClickThrough() {
        guard rugVisible else { return }
        let screenPoint = NSEvent.mouseLocation
        for rug in rugs {
            let overFabric: Bool
            if rug.view.isDragging {
                overFabric = true
            } else if rug.frame.contains(screenPoint) {
                let windowPoint = rug.window.convertPoint(fromScreen: screenPoint)
                let viewPoint = rug.view.convert(windowPoint, from: nil)
                overFabric = rug.view.isPointOverCloth(viewPoint)
            } else {
                overFabric = false
            }
            if rug.window.ignoresMouseEvents == overFabric {
                rug.window.ignoresMouseEvents = !overFabric
            }
        }
    }

    private func resetAll() {
        rugs.forEach { $0.view.reset() }
    }

    private func toggleRug() {
        rugVisible.toggle()
        Settings.rugHidden = !rugVisible
        for rug in rugs {
            if rugVisible {
                rug.window.orderFrontRegardless()
                rug.view.resume()
            } else {
                rug.window.orderOut(nil)
            }
        }
        statusMenu?.setRugVisible(rugVisible)
    }

    /// Rebuild the rugs when their source or size changed. Textures are made off the main thread.
    @objc private func settingsChanged() {
        let source = Settings.rugSource
        let size = Settings.rugSize
        guard source != appliedSource || size != appliedSize else { return }
        appliedSource = source
        appliedSize = size
        assetQueue.async { [weak self] in
            let assets = RugAssets.current()
            DispatchQueue.main.async {
                guard let self else { return }
                // A failed image load falls back to the style; record that so we don't loop.
                self.appliedSource = assets.source
                for rug in self.rugs {
                    rug.view.apply(RugConfig(assets: assets, coverage: size.coverage))
                }
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

    // MARK: - Launch at login

    private static var isBundled: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static func launchAtLoginState() -> (enabled: Bool, available: Bool) {
        guard isBundled else { return (false, false) }
        return (SMAppService.mainApp.status == .enabled, true)
    }

    private func toggleLaunchAtLogin() {
        guard AppDelegate.isBundled else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Blanket: launch at login change failed: \(error.localizedDescription)")
        }
    }
}
