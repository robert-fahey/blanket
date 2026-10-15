import CoreGraphics
import Foundation

/// Procedural tangent-space normal map of a plain weave with a little pile noise.
enum WeaveNormalMap {
    static func make(size: Int = 256, period: Int = 8, strength: Float = 1.6, seed: UInt64 = 3) -> CGImage? {
        var rng = SplitMix64(seed: seed)
        var height = [Float](repeating: 0, count: size * size)
        let p = Float(period)
        for y in 0..<size {
            for x in 0..<size {
                let fx = Float(x), fy = Float(y)
                let cell = ((x / period) + (y / period)) & 1
                let sx = sin(.pi * fx / p), sy = sin(.pi * fy / p)
                let hx = sx * sx, hy = sy * sy
                var h = cell == 0 ? hx * (0.7 + 0.3 * hy) : hy * (0.7 + 0.3 * hx)
                h += Float(rng.unit()) * 0.18
                height[y * size + x] = h
            }
        }
        var bytes = [UInt8](repeating: 255, count: size * size * 4)
        @inline(__always) func H(_ x: Int, _ y: Int) -> Float {
            height[((y + size) % size) * size + ((x + size) % size)]
        }
        for y in 0..<size {
            for x in 0..<size {
                let dx = (H(x + 1, y) - H(x - 1, y)) * strength
                let dy = (H(x, y + 1) - H(x, y - 1)) * strength
                var n = SIMD3<Float>(-dx, -dy, 1)
                n /= (n.x * n.x + n.y * n.y + n.z * n.z).squareRoot()
                let i = (y * size + x) * 4
                bytes[i] = UInt8((n.x * 0.5 + 0.5) * 255)
                bytes[i + 1] = UInt8((n.y * 0.5 + 0.5) * 255)
                bytes[i + 2] = UInt8((n.z * 0.5 + 0.5) * 255)
                bytes[i + 3] = 255
            }
        }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
            space: cs, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}
