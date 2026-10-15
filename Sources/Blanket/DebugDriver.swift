import AppKit
import simd

/// Headless-ish verification: when BLANKET_SNAPSHOT_DIR is set, run a scripted pull on the rug,
/// save SceneKit snapshots to that directory, then quit. Used for development only.
final class DebugDriver {
    private let view: RugView
    private let dir: URL
    private var timers: [Timer] = []

    init?(view: RugView) {
        guard let path = ProcessInfo.processInfo.environment["BLANKET_SNAPSHOT_DIR"], !path.isEmpty else { return nil }
        self.view = view
        dir = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func start() {
        let size = view.bounds.size
        let W = Float(size.width), H = Float(size.height)
        // Grab near the lower-right corner of the rug and pull it up-left across the screen.
        let start = SIMD2<Float>(W * 0.88, H * 0.12)
        let end = SIMD2<Float>(W * 0.45, H * 0.55)
        let grid = view.debugGrid

        schedule(1.0) { self.snapshot("1-rest") }
        schedule(1.2) { self.view.debugBeginGrab(at: start) }
        let steps = 45
        for s in 1...steps {
            let f = Float(s) / Float(steps)
            let p = start + (end - start) * f
            schedule(1.2 + 1.5 * Double(f)) { self.view.debugMoveGrab(to: p) }
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
        schedule(6.5) {
            self.snapshot("7-wide-settled")
            let n = max(self.view.profileFrames, 1)
            self.log(String(format: "profile: %d active frames, step %.2f ms, geometry %.2f ms (avg per frame)",
                            n, self.view.profileStepSeconds / Double(n) * 1000, self.view.profileGeometrySeconds / Double(n) * 1000))
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
        log("snapshot \(name) asleep=\(view.debugIsAsleep)")
    }
}
