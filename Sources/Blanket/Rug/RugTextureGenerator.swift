import CoreGraphics
import Foundation

/// Deterministic pseudo-random generator so the rug looks the same every launch.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> CGFloat { CGFloat(Double(next() >> 11) / Double(1 << 53)) }
    mutating func range(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat { lo + (hi - lo) * unit() }
}

/// Draws a traditional medallion-style Persian rug with Core Graphics.
enum RugTextureGenerator {
    struct Palette {
        static let red = CGColor(srgbRed: 0.56, green: 0.12, blue: 0.14, alpha: 1)
        static let darkRed = CGColor(srgbRed: 0.40, green: 0.07, blue: 0.10, alpha: 1)
        static let navy = CGColor(srgbRed: 0.11, green: 0.15, blue: 0.32, alpha: 1)
        static let deepNavy = CGColor(srgbRed: 0.07, green: 0.09, blue: 0.22, alpha: 1)
        static let cream = CGColor(srgbRed: 0.93, green: 0.87, blue: 0.74, alpha: 1)
        static let gold = CGColor(srgbRed: 0.82, green: 0.64, blue: 0.28, alpha: 1)
        static let teal = CGColor(srgbRed: 0.24, green: 0.44, blue: 0.42, alpha: 1)
        static let ink = CGColor(srgbRed: 0.09, green: 0.07, blue: 0.09, alpha: 1)
    }

    static func makeRugImage(width W: Int = 2048, height H: Int = 1412, seed: UInt64 = 7) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        var rng = SplitMix64(seed: seed)
        let w = CGFloat(W), h = CGFloat(H)

        // --- Field with abrash (dye-lot banding) ---
        ctx.setFillColor(Palette.red)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        var y: CGFloat = 0
        while y < h {
            let bh = rng.range(14, 36)
            let t = rng.range(-0.045, 0.045)
            ctx.setFillColor(CGColor(srgbRed: 0.56 + t, green: 0.12 + t * 0.4, blue: 0.14 + t * 0.4, alpha: 1))
            ctx.fill(CGRect(x: 0, y: y, width: w, height: bh + 1))
            y += bh
        }

        // --- Borders (drawn as bands around the perimeter) ---
        let outerGuard: CGFloat = 44
        let mainBorder: CGFloat = 150
        let innerGuard: CGFloat = 42
        let outline: CGFloat = 8
        let fieldInset = outerGuard + mainBorder + innerGuard + outline

        drawBand(ctx, inset: 0, thickness: outerGuard, size: CGSize(width: w, height: h)) { c, len, t in
            c.setFillColor(Palette.navy); c.fill(CGRect(x: 0, y: 0, width: len, height: t))
            // reciprocal cream/gold tooth pattern
            let step: CGFloat = 36
            var x: CGFloat = 0; var k = 0
            while x < len {
                c.setFillColor(k % 2 == 0 ? Palette.cream : Palette.gold)
                c.fill(CGRect(x: x + 8, y: 12, width: 16, height: t - 24))
                x += step; k += 1
            }
        }
        drawBand(ctx, inset: outerGuard, thickness: mainBorder, size: CGSize(width: w, height: h)) { c, len, t in
            c.setFillColor(Palette.deepNavy); c.fill(CGRect(x: 0, y: 0, width: len, height: t))
            // thin cream rails
            c.setFillColor(Palette.cream)
            c.fill(CGRect(x: 0, y: 6, width: len, height: 4))
            c.fill(CGRect(x: 0, y: t - 10, width: len, height: 4))
            // meandering vine
            let path = CGMutablePath()
            let mid = t / 2
            path.move(to: CGPoint(x: 0, y: mid))
            var x: CGFloat = 0
            let period: CGFloat = 170
            while x < len {
                path.addCurve(
                    to: CGPoint(x: x + period, y: mid),
                    control1: CGPoint(x: x + period * 0.35, y: mid + t * 0.32),
                    control2: CGPoint(x: x + period * 0.65, y: mid - t * 0.32)
                )
                x += period
            }
            c.setStrokeColor(Palette.cream); c.setLineWidth(5); c.addPath(path); c.strokePath()
            // motifs along the vine
            x = period / 2
            var k = 0
            while x < len - period / 4 {
                if k % 2 == 0 {
                    drawRosette(c, center: CGPoint(x: x, y: mid), radius: t * 0.33, petal: Palette.gold, core: Palette.red, outline: Palette.cream)
                } else {
                    drawPalmette(c, center: CGPoint(x: x, y: mid), size: t * 0.36, fill: Palette.cream, accent: Palette.red, outline: Palette.gold)
                }
                // small diamonds between motifs
                drawDiamond(c, center: CGPoint(x: x + period / 2, y: mid + t * 0.3), w: 16, h: 22, fill: Palette.red, outline: Palette.cream)
                drawDiamond(c, center: CGPoint(x: x + period / 2, y: mid - t * 0.3), w: 16, h: 22, fill: Palette.red, outline: Palette.cream)
                x += period; k += 1
            }
        }
        // corner squares of the main border
        for cx in [outerGuard + mainBorder / 2, w - outerGuard - mainBorder / 2] {
            for cy in [outerGuard + mainBorder / 2, h - outerGuard - mainBorder / 2] {
                ctx.setFillColor(Palette.deepNavy)
                ctx.fill(CGRect(x: cx - mainBorder / 2, y: cy - mainBorder / 2, width: mainBorder, height: mainBorder))
                drawDiamond(ctx, center: CGPoint(x: cx, y: cy), w: mainBorder * 0.7, h: mainBorder * 0.7, fill: Palette.red, outline: Palette.cream)
                drawRosette(ctx, center: CGPoint(x: cx, y: cy), radius: mainBorder * 0.22, petal: Palette.gold, core: Palette.navy, outline: Palette.cream)
            }
        }
        drawBand(ctx, inset: outerGuard + mainBorder, thickness: innerGuard, size: CGSize(width: w, height: h)) { c, len, t in
            c.setFillColor(Palette.cream); c.fill(CGRect(x: 0, y: 0, width: len, height: t))
            // S-chain in red and navy
            let step: CGFloat = 44
            var x: CGFloat = 0; var k = 0
            while x < len {
                drawDiamond(c, center: CGPoint(x: x + step / 2, y: t / 2), w: 22, h: t - 14,
                            fill: k % 2 == 0 ? Palette.red : Palette.navy, outline: nil)
                x += step; k += 1
            }
        }
        drawBand(ctx, inset: outerGuard + mainBorder + innerGuard, thickness: outline, size: CGSize(width: w, height: h)) { c, len, t in
            c.setFillColor(Palette.navy); c.fill(CGRect(x: 0, y: 0, width: len, height: t))
        }

        // --- Field contents ---
        let field = CGRect(x: fieldInset, y: fieldInset, width: w - 2 * fieldInset, height: h - 2 * fieldInset)
        let center = CGPoint(x: w / 2, y: h / 2)
        let medRX: CGFloat = 430, medRY: CGFloat = 300
        let spandrelRX: CGFloat = 400, spandrelRY: CGFloat = 310

        // Spandrels in the four field corners (quarter medallions)
        ctx.saveGState()
        ctx.clip(to: field)
        for cx in [field.minX, field.maxX] {
            for cy in [field.minY, field.maxY] {
                let cc = CGPoint(x: cx, y: cy)
                fillLobed(ctx, center: cc, rx: spandrelRX, ry: spandrelRY, lobes: 20, depth: 0.05, fill: Palette.navy, stroke: Palette.cream, lineWidth: 6)
                fillLobed(ctx, center: cc, rx: spandrelRX - 60, ry: spandrelRY - 50, lobes: 20, depth: 0.05, fill: nil, stroke: Palette.gold, lineWidth: 4)
                // small rosettes inside the spandrel along an arc
                let sx: CGFloat = cx == field.minX ? 1 : -1
                let sy: CGFloat = cy == field.minY ? 1 : -1
                for a in stride(from: CGFloat(0.18), through: 1.4, by: 0.4) {
                    let px = cx + sx * cos(a) * (spandrelRX - 150)
                    let py = cy + sy * sin(a) * (spandrelRY - 120)
                    drawRosette(ctx, center: CGPoint(x: px, y: py), radius: 26, petal: Palette.cream, core: Palette.gold, outline: nil)
                }
                drawPalmette(ctx, center: CGPoint(x: cx + sx * 110, y: cy + sy * 90), size: 48, fill: Palette.gold, accent: Palette.red, outline: Palette.cream)
            }
        }
        ctx.restoreGState()

        // Field filler lattice (herati-style sprigs), avoiding medallion and spandrels
        let dx: CGFloat = 128, dy: CGFloat = 112
        var row = 0
        var fy = field.minY + 60
        while fy < field.maxY - 40 {
            var fx = field.minX + 60 + (row % 2 == 0 ? 0 : dx / 2)
            while fx < field.maxX - 40 {
                let p = CGPoint(x: fx, y: fy)
                let inMed = ellipseDist(p, center, medRX + 90, medRY + 80) < 1
                var inSpan = false
                for cx in [field.minX, field.maxX] {
                    for cy in [field.minY, field.maxY] where ellipseDist(p, CGPoint(x: cx, y: cy), spandrelRX + 40, spandrelRY + 40) < 1 { inSpan = true }
                }
                if !inMed && !inSpan {
                    drawSprig(ctx, center: p, variant: (row + Int(fx / dx)) % 3)
                }
                fx += dx
            }
            fy += dy; row += 1
        }

        // Pendants on the long axis
        for s in [CGFloat(-1), 1] {
            let px = center.x + s * (medRX + 95)
            ctx.setFillColor(Palette.navy)
            ctx.fill(CGRect(x: min(center.x + s * medRX, px), y: center.y - 5, width: 95, height: 10))
            fillLobed(ctx, center: CGPoint(x: px + s * 10, y: center.y), rx: 78, ry: 60, lobes: 12, depth: 0.08, fill: Palette.navy, stroke: Palette.cream, lineWidth: 5)
            drawDiamond(ctx, center: CGPoint(x: px + s * 10, y: center.y), w: 60, h: 48, fill: Palette.gold, outline: Palette.cream)
            drawDiamond(ctx, center: CGPoint(x: px + s * 10, y: center.y), w: 26, h: 20, fill: Palette.red, outline: nil)
        }

        // Central medallion
        fillLobed(ctx, center: center, rx: medRX, ry: medRY, lobes: 16, depth: 0.07, fill: Palette.navy, stroke: Palette.cream, lineWidth: 7)
        fillLobed(ctx, center: center, rx: medRX - 48, ry: medRY - 36, lobes: 16, depth: 0.06, fill: Palette.cream, stroke: Palette.gold, lineWidth: 4)
        fillLobed(ctx, center: center, rx: medRX - 78, ry: medRY - 58, lobes: 16, depth: 0.05, fill: Palette.red, stroke: Palette.navy, lineWidth: 4)
        // ring of small rosettes in the cream band
        for k in 0..<16 {
            let a = CGFloat(k) / 16 * 2 * .pi
            let p = CGPoint(x: center.x + cos(a) * (medRX - 63), y: center.y + sin(a) * (medRY - 47))
            drawDiamond(ctx, center: p, w: 14, h: 14, fill: k % 2 == 0 ? Palette.navy : Palette.red, outline: nil)
        }
        fillStar(ctx, center: center, outer: 215, inner: 150, points: 8, rotation: .pi / 8, fill: Palette.navy, stroke: Palette.cream, lineWidth: 5)
        fillStar(ctx, center: center, outer: 170, inner: 118, points: 8, rotation: 0, fill: Palette.gold, stroke: Palette.cream, lineWidth: 3)
        ctx.setFillColor(Palette.red)
        ctx.fillEllipse(in: CGRect(x: center.x - 112, y: center.y - 112, width: 224, height: 224))
        ctx.setStrokeColor(Palette.cream); ctx.setLineWidth(4)
        ctx.strokeEllipse(in: CGRect(x: center.x - 112, y: center.y - 112, width: 224, height: 224))
        drawRosette(ctx, center: center, radius: 92, petal: Palette.navy, core: Palette.gold, outline: Palette.cream)
        drawRosette(ctx, center: center, radius: 40, petal: Palette.cream, core: Palette.red, outline: nil)
        for k in 0..<8 {
            let a = CGFloat(k) / 8 * 2 * .pi + .pi / 8
            let p = CGPoint(x: center.x + cos(a) * 190, y: center.y + sin(a) * 190)
            drawRosette(ctx, center: p, radius: 16, petal: Palette.cream, core: Palette.red, outline: nil)
        }

        // --- Fibre noise overlay for a woven, non-vector look ---
        if let noise = makeNoiseTile(size: 512, rng: &rng) {
            ctx.saveGState()
            ctx.setBlendMode(.softLight)
            ctx.setAlpha(0.55)
            ctx.draw(noise, in: CGRect(x: 0, y: 0, width: 512, height: 512), byTiling: true)
            ctx.restoreGState()
        }

        return ctx.makeImage()!
    }

    // MARK: - Drawing helpers

    /// Draws `body` four times, once per side, with the context transformed so the band runs
    /// along +X from 0...len and spans 0...thickness in Y (with Y pointing toward the center).
    private static func drawBand(_ ctx: CGContext, inset: CGFloat, thickness: CGFloat, size: CGSize,
                                 _ body: (CGContext, CGFloat, CGFloat) -> Void) {
        let w = size.width, h = size.height
        // bottom
        ctx.saveGState(); ctx.translateBy(x: inset, y: inset)
        body(ctx, w - 2 * inset, thickness); ctx.restoreGState()
        // top (flipped)
        ctx.saveGState(); ctx.translateBy(x: inset, y: h - inset); ctx.scaleBy(x: 1, y: -1)
        body(ctx, w - 2 * inset, thickness); ctx.restoreGState()
        // left (rotated so Y points to +X)
        ctx.saveGState(); ctx.translateBy(x: inset, y: h - inset); ctx.rotate(by: -.pi / 2)
        body(ctx, h - 2 * inset, thickness); ctx.restoreGState()
        // right
        ctx.saveGState(); ctx.translateBy(x: w - inset, y: inset); ctx.rotate(by: .pi / 2)
        body(ctx, h - 2 * inset, thickness); ctx.restoreGState()
    }

    private static func ellipseDist(_ p: CGPoint, _ c: CGPoint, _ rx: CGFloat, _ ry: CGFloat) -> CGFloat {
        let dx = (p.x - c.x) / rx, dy = (p.y - c.y) / ry
        return (dx * dx + dy * dy).squareRoot()
    }

    private static func lobedPath(center: CGPoint, rx: CGFloat, ry: CGFloat, lobes: Int, depth: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let n = 256
        for k in 0...n {
            let a = CGFloat(k) / CGFloat(n) * 2 * .pi
            let r = 1 + depth * cos(CGFloat(lobes) * a)
            let p = CGPoint(x: center.x + cos(a) * rx * r, y: center.y + sin(a) * ry * r)
            if k == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }

    private static func fillLobed(_ ctx: CGContext, center: CGPoint, rx: CGFloat, ry: CGFloat, lobes: Int, depth: CGFloat,
                                  fill: CGColor?, stroke: CGColor?, lineWidth: CGFloat) {
        let path = lobedPath(center: center, rx: rx, ry: ry, lobes: lobes, depth: depth)
        if let fill { ctx.setFillColor(fill); ctx.addPath(path); ctx.fillPath() }
        if let stroke { ctx.setStrokeColor(stroke); ctx.setLineWidth(lineWidth); ctx.addPath(path); ctx.strokePath() }
    }

    private static func fillStar(_ ctx: CGContext, center: CGPoint, outer: CGFloat, inner: CGFloat, points: Int, rotation: CGFloat,
                                 fill: CGColor, stroke: CGColor?, lineWidth: CGFloat) {
        let path = CGMutablePath()
        for k in 0..<(points * 2) {
            let a = rotation + CGFloat(k) / CGFloat(points * 2) * 2 * .pi
            let r = k % 2 == 0 ? outer : inner
            let p = CGPoint(x: center.x + cos(a) * r, y: center.y + sin(a) * r)
            if k == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        ctx.setFillColor(fill); ctx.addPath(path); ctx.fillPath()
        if let stroke { ctx.setStrokeColor(stroke); ctx.setLineWidth(lineWidth); ctx.addPath(path); ctx.strokePath() }
    }

    private static func drawDiamond(_ ctx: CGContext, center: CGPoint, w: CGFloat, h: CGFloat, fill: CGColor, outline: CGColor?) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: center.x, y: center.y + h / 2))
        path.addLine(to: CGPoint(x: center.x + w / 2, y: center.y))
        path.addLine(to: CGPoint(x: center.x, y: center.y - h / 2))
        path.addLine(to: CGPoint(x: center.x - w / 2, y: center.y))
        path.closeSubpath()
        ctx.setFillColor(fill); ctx.addPath(path); ctx.fillPath()
        if let outline { ctx.setStrokeColor(outline); ctx.setLineWidth(3); ctx.addPath(path); ctx.strokePath() }
    }

    private static func drawRosette(_ ctx: CGContext, center: CGPoint, radius: CGFloat, petal: CGColor, core: CGColor, outline: CGColor?) {
        let petals = 8
        for k in 0..<petals {
            let a = CGFloat(k) / CGFloat(petals) * 2 * .pi
            ctx.saveGState()
            ctx.translateBy(x: center.x, y: center.y)
            ctx.rotate(by: a)
            let rect = CGRect(x: radius * 0.25, y: -radius * 0.22, width: radius * 0.75, height: radius * 0.44)
            ctx.setFillColor(petal); ctx.fillEllipse(in: rect)
            if let outline { ctx.setStrokeColor(outline); ctx.setLineWidth(2); ctx.strokeEllipse(in: rect) }
            ctx.restoreGState()
        }
        let r = radius * 0.32
        ctx.setFillColor(core)
        ctx.fillEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        if let outline {
            ctx.setStrokeColor(outline); ctx.setLineWidth(2)
            ctx.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        }
    }

    /// Fan-shaped palmette: five petals over a small base, pointing +Y.
    private static func drawPalmette(_ ctx: CGContext, center: CGPoint, size: CGFloat, fill: CGColor, accent: CGColor, outline: CGColor?) {
        for k in -2...2 {
            let a = CGFloat(k) * 0.45
            ctx.saveGState()
            ctx.translateBy(x: center.x, y: center.y - size * 0.4)
            ctx.rotate(by: a)
            let rect = CGRect(x: -size * 0.16, y: size * 0.15, width: size * 0.32, height: size * 0.9)
            ctx.setFillColor(fill); ctx.fillEllipse(in: rect)
            if let outline { ctx.setStrokeColor(outline); ctx.setLineWidth(2); ctx.strokeEllipse(in: rect) }
            ctx.restoreGState()
        }
        drawDiamond(ctx, center: CGPoint(x: center.x, y: center.y - size * 0.4), w: size * 0.5, h: size * 0.45, fill: accent, outline: outline)
    }

    /// Small field sprig: a diamond with four leaves.
    private static func drawSprig(_ ctx: CGContext, center: CGPoint, variant: Int) {
        let leaf: CGColor = variant == 0 ? Palette.teal : (variant == 1 ? Palette.navy : Palette.gold)
        let core: CGColor = variant == 2 ? Palette.navy : Palette.cream
        for k in 0..<4 {
            let a = CGFloat(k) * .pi / 2 + .pi / 4
            ctx.saveGState()
            ctx.translateBy(x: center.x, y: center.y)
            ctx.rotate(by: a)
            ctx.setFillColor(leaf)
            ctx.fillEllipse(in: CGRect(x: 14, y: -7, width: 30, height: 14))
            ctx.restoreGState()
        }
        drawDiamond(ctx, center: center, w: 26, h: 26, fill: core, outline: Palette.ink)
        drawDiamond(ctx, center: center, w: 10, h: 10, fill: Palette.red, outline: nil)
    }

    private static func makeNoiseTile(size: Int, rng: inout SplitMix64) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let i = (y * size + x) * 4
                // Mostly neutral gray with fine thread-like streaks along X.
                let base = 118 + Int(rng.next() % 32)
                let streak = (x % 3 == 0) ? 8 : 0
                let v = UInt8(min(255, base + streak))
                bytes[i] = v; bytes[i + 1] = v; bytes[i + 2] = v; bytes[i + 3] = 255
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

    /// Tassel texture: a few cream strands with a knot at the top (v = 0), transparent between.
    static func makeFringeImage(size: Int = 128) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
        let s = CGFloat(size)
        let strands = 4
        var rng = SplitMix64(seed: 11)
        for k in 0..<strands {
            let x = s * (CGFloat(k) + 0.5) / CGFloat(strands)
            // knot at the top of the image (CG y is bottom-up, so top = s)
            ctx.setFillColor(Palette.cream)
            ctx.fillEllipse(in: CGRect(x: x - 9, y: s - 20, width: 18, height: 16))
            // wavy strand downward
            let path = CGMutablePath()
            path.move(to: CGPoint(x: x, y: s - 12))
            var y = s - 12
            while y > 4 {
                let ny = y - 30
                path.addQuadCurve(to: CGPoint(x: x + rng.range(-3, 3), y: ny), control: CGPoint(x: x + rng.range(-7, 7), y: (y + ny) / 2))
                y = ny
            }
            ctx.setStrokeColor(Palette.cream)
            ctx.setLineWidth(5)
            ctx.setLineCap(.round)
            ctx.addPath(path); ctx.strokePath()
            ctx.setStrokeColor(CGColor(srgbRed: 0.78, green: 0.70, blue: 0.56, alpha: 1))
            ctx.setLineWidth(1.5)
            ctx.addPath(path); ctx.strokePath()
        }
        return ctx.makeImage()!
    }
}
