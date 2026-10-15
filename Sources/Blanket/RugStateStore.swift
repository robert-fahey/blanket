import Foundation
import simd

/// Saves and restores the rug's shape so it comes back the way you left it.
/// One file per screen size in ~/Library/Application Support/Blanket.
enum RugStateStore {
    private static let magic: UInt32 = 0x424C4B54  // "BLKT"

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Blanket", isDirectory: true)
    }

    static func key(for screenSize: CGSize) -> String {
        "\(Int(screenSize.width))x\(Int(screenSize.height))"
    }

    private static func url(for key: String) -> URL {
        directory.appendingPathComponent("state-\(key).bin")
    }

    static func save(positions: [SIMD3<Float>], cols: Int, rows: Int, key: String) {
        guard positions.count == cols * rows, !positions.isEmpty else { return }
        var data = Data()
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { data.append(contentsOf: $0) } }
        put(magic)
        put(UInt32(cols))
        put(UInt32(rows))
        for p in positions { put(p.x); put(p.y); put(p.z) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url(for: key), options: .atomic)
        } catch {
            NSLog("Blanket: could not save rug state: \(error.localizedDescription)")
        }
    }

    /// Saved positions, if any. The caller checks the count against its own grid.
    static func load(key: String) -> [SIMD3<Float>]? {
        guard let data = try? Data(contentsOf: url(for: key)) else { return nil }
        let header = 12
        guard data.count >= header else { return nil }
        var ok = true
        var n = 0
        data.withUnsafeBytes { raw in
            guard raw.load(as: UInt32.self) == magic else { ok = false; return }
            n = Int(raw.load(fromByteOffset: 4, as: UInt32.self)) * Int(raw.load(fromByteOffset: 8, as: UInt32.self))
        }
        guard ok, n > 0, data.count == header + n * 12 else { return nil }
        var out = [SIMD3<Float>](repeating: .zero, count: n)
        data.withUnsafeBytes { raw in
            for k in 0..<n {
                let o = header + k * 12
                out[k] = SIMD3<Float>(
                    raw.load(fromByteOffset: o, as: Float.self),
                    raw.load(fromByteOffset: o + 4, as: Float.self),
                    raw.load(fromByteOffset: o + 8, as: Float.self)
                )
            }
        }
        guard ok, out.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { return nil }
        return out
    }

    static func clear(key: String) {
        try? FileManager.default.removeItem(at: url(for: key))
    }
}
