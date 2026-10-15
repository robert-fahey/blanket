import AppKit
import simd

/// Headless-ish verification: when BLANKET_SNAPSHOT_DIR is set, run a scripted pull on the rug,
/// save SceneKit snapshots to that directory, then quit. Used for development only.
final class DebugDriver {
    private let view: RugView
    private let dir: URL
    private var timers: [Timer] = []

    static var isEnabled: Bool {
        !(ProcessInfo.processInfo.environment["BLANKET_SNAPSHOT_DIR"] ?? "").isEmpty
    }

    init?(view: RugView) {
        guard DebugDriver.isEnabled, let path = ProcessInfo.processInfo.environment["BLANKET_SNAPSHOT_DIR"] else { return nil }
        self.view = view
        dir = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func start() {
        // BLANKET_SNAPSHOT_MODE=rest: just capture whatever state was restored, then quit.
        if ProcessInfo.processInfo.environment["BLANKET_SNAPSHOT_MODE"] == "rest" {
            schedule(1.0) { self.snapshot("restored") }
            for t in stride(from: 2.0, through: 6.0, by: 1.0) {
                schedule(t) { self.log(String(format: "t=%.0fs asleep=%d maxMove=%.4f", t, self.view.debugIsAsleep ? 1 : 0, self.view.debugMaxMove)) }
            }
            schedule(1.3) { self.log(self.view.debugTopMovers(10)) }
            schedule(6.2) { NSApp.terminate(nil) }
            return
        }
        schedule(0.1) { self.view.reset() }
        let size = view.bounds.size
        let W = Float(size.width), H = Float(size.height)
        // Grab just inside the rug's lower-right corner and pull it up-left across the screen.
        let grid = view.debugGrid
        // Corner position is read after the reset above has been applied.
        var start = SIMD2<Float>(0, 0)
        let end = SIMD2<Float>(W * 0.45, H * 0.55)

        schedule(1.0) { self.snapshot("1-rest") }
        schedule(1.2) {
            let corner = self.view.debugParticlePosition(i: grid.cols - 2, j: 1)
            start = SIMD2<Float>(corner.x, corner.y)
            self.view.debugBeginGrab(at: start)
        }
        let steps = 45
        for s in 1...steps {
            let f = Float(s) / Float(steps)
            schedule(1.2 + 1.5 * Double(f)) { self.view.debugMoveGrab(to: start + (end - start) * f) }
        }
        schedule(1.5) {
            self.log(String(format: "stretch at 12 cells during the yank: %.3f (1.0 = inextensible)", self.view.debugStretch(cells: 12)))
        }
        schedule(1.9) {
            self.snapshot("2-pulling")
            let mid = self.view.debugParticlePosition(i: grid.cols / 2, j: grid.rows / 2)
            self.log(String(format: "stretch at 12 cells mid-pull: %.3f; rug centre now at (%.0f, %.0f)",
                            self.view.debugStretch(cells: 12), mid.x, mid.y))
        }
        schedule(2.7) { self.snapshot("3-pulled") }
        schedule(2.75) { self.view.debugEndGrab(velocity: SIMD2<Float>(-600, 500)) }
        schedule(3.6) { self.snapshot("4-settled") }
        schedule(3.7) { self.view.reset() }
        schedule(4.3) { self.snapshot("5-reset") }

        // Wide (Option-drag) grab from the middle of the rug, pulled right.
        let wStart = SIMD2<Float>(W * 0.5, H * 0.5)
        let wEnd = SIMD2<Float>(W * 0.72, H * 0.42)
        schedule(4.4) { self.view.debugBeginGrab(at: wStart, wide: true) }
        for s in 1...steps {
            let f = Float(s) / Float(steps)
            let p = wStart + (wEnd - wStart) * f
            schedule(4.4 + 1.2 * Double(f)) { self.view.debugMoveGrab(to: p, speed: 250) }
        }
        schedule(5.2) { self.snapshot("6-wide-pull") }
        schedule(5.65) { self.view.debugEndGrab(velocity: .zero) }
        schedule(6.5) { self.snapshot("7-wide-settled") }

        // Double fold: fold the corner all the way over, then fold the new top corner back.
        schedule(6.6) { self.view.reset() }
        var c1 = SIMD2<Float>(0, 0), far = SIMD2<Float>(0, 0), centre = SIMD2<Float>(0, 0)
        schedule(6.9) {
            let a = self.view.debugParticlePosition(i: grid.cols - 2, j: 1)
            let b = self.view.debugParticlePosition(i: 1, j: grid.rows - 2)
            let m = self.view.debugParticlePosition(i: grid.cols / 2, j: grid.rows / 2)
            c1 = SIMD2(a.x, a.y); far = SIMD2(b.x, b.y); centre = SIMD2(m.x, m.y)
            self.view.debugBeginGrab(at: c1)
        }
        for s in 1...steps {
            let f = Float(s) / Float(steps)
            schedule(6.9 + 1.6 * Double(f)) { self.view.debugMoveGrab(to: c1 + (far - c1) * f, speed: 500) }
        }
        schedule(8.6) { self.view.debugEndGrab(velocity: .zero) }
        schedule(9.4) { self.snapshot("8-folded-over") }
        schedule(9.5) { self.view.debugBeginGrab(at: far) }
        for s in 1...steps {
            let f = Float(s) / Float(steps)
            schedule(9.5 + 1.3 * Double(f)) { self.view.debugMoveGrab(to: far + (centre - far) * f, speed: 500) }
        }
        schedule(10.9) { self.view.debugEndGrab(velocity: .zero) }
        schedule(11.8) {
            self.snapshot("9-double-fold")
            let n = max(self.view.profileFrames, 1)
            self.log(String(format: "profile: %d active frames, step %.2f ms (solve %.2f, stack %.2f), geometry %.2f ms (avg per frame)",
                            n, self.view.profileStepSeconds / Double(n) * 1000,
                            self.view.debugProfileSolve / Double(n) * 1000, self.view.debugProfileStack / Double(n) * 1000,
                            self.view.profileGeometrySeconds / Double(n) * 1000))
            NSApp.terminate(nil)
        }
    }

    private func log(_ line: String) {
        FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
    }

    private func schedule(_ t: TimeInterval, _ block: @escaping () -> Void) {
        timers.append(Timer.scheduledTimer(withTimeInterval: t, repeats: false) { _ in block() })
    }

    private func snapshot(_ name: String) {
        let image = view.snapshot()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: dir.appendingPathComponent("\(name).png"))
        log(String(format: "snapshot %@ asleep=%d maxMove=%.4f penetrations=%d", name, view.debugIsAsleep ? 1 : 0, view.debugMaxMove, view.debugPenetrations()))
    }
}
