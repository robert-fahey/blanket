import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: OverlayWindow?
    private var rugView: RugView?
    private var statusMenu: StatusMenu?
    private var hoverTimer: Timer?
    private var rugVisible = true
    private var debugDriver: DebugDriver?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        let window = OverlayWindow(screen: screen)
        let rugView = RugView(frame: NSRect(origin: .zero, size: screen.frame.size))
        rugView.autoresizingMask = [.width, .height]
        window.contentView = rugView
        window.orderFrontRegardless()
        self.window = window
        self.rugView = rugView

        let menu = StatusMenu()
        menu.onReset = { [weak self] in self?.rugView?.reset() }
        menu.onToggle = { [weak self] in self?.toggleRug() }
        statusMenu = menu

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
        if rugVisible {
            window.orderFrontRegardless()
            rugView?.resume()
        } else {
            rugView?.isPlaying = false
            window.orderOut(nil)
        }
        statusMenu?.setRugVisible(rugVisible)
    }

    @objc private func screenParametersChanged() {
        guard let window, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        if window.frame != screen.frame {
            window.setFrame(screen.frame, display: true)
            rugView?.viewportChanged(to: screen.frame.size)
        }
    }
}
