import AppKit
import CoreGraphics

enum RugSource: Equatable {
    case style(RugStyle)
    case image(URL)

    var cacheKey: String {
        switch self {
        case .style(let s): return "style:\(s.rawValue)"
        case .image(let url): return "image:\(url.path)"
        }
    }
}

/// Top and underside images for a rug source, generated or loaded once and cached, so several
/// displays (or repeated menu changes) never regenerate the same texture.
final class RugAssets {
    let source: RugSource
    let top: CGImage
    let underside: CGImage
    /// Width / height of the rug.
    let aspect: CGFloat

    private static var cache: [String: RugAssets] = [:]
    private static let lock = NSLock()
    static let maxTextureWidth = 2048

    /// Assets for the current settings; a missing or unreadable custom image falls back to the style.
    static func current() -> RugAssets {
        let source = Settings.rugSource
        if let a = load(source) { return a }
        NSLog("Blanket: could not load rug image for \(source.cacheKey); using the built-in rug")
        return load(.style(Settings.rugStyle))!
    }

    static func load(_ source: RugSource) -> RugAssets? {
        lock.lock()
        if let cached = cache[source.cacheKey] { lock.unlock(); return cached }
        lock.unlock()
        guard let made = RugAssets(source: source) else { return nil }
        lock.lock()
        cache[source.cacheKey] = made
        lock.unlock()
        return made
    }

    private init?(source: RugSource) {
        self.source = source
        switch source {
        case .style(let style):
            top = RugTextureGenerator.makeRugImage(style: style)
            aspect = CGFloat(top.width) / CGFloat(top.height)
        case .image(let url):
            guard let image = NSImage(contentsOf: url),
                  var cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            if cg.width > RugAssets.maxTextureWidth, let smaller = RugAssets.downscale(cg, toWidth: RugAssets.maxTextureWidth) {
                cg = smaller
            }
            top = cg
            aspect = min(max(CGFloat(cg.width) / CGFloat(cg.height), 0.6), 2.4)
        }
        underside = RugTextureGenerator.makeUndersideImage(from: top)
    }

    private static func downscale(_ image: CGImage, toWidth width: Int) -> CGImage? {
        let height = max(1, image.height * width / image.width)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}
