import Foundation
import simd

/// Position-based-dynamics cloth lying on the z = 0 "desk" plane.
/// Units are screen points. +Z points toward the viewer (out of the screen).
final class ClothSimulation {
    struct Constraint {
        var a: Int32
        var b: Int32
        var rest: Float
        var stiffness: Float
        /// Multiplier applied when the constraint is shorter than rest. 0 = goes slack like a rope.
        var compression: Float
    }

    struct Grab {
        var index: Int
        var offset: SIMD3<Float>
    }

    let cols: Int
    let rows: Int
    let spacing: Float
    /// Height of the rug's underside above the desk. Keeps it from z-fighting the floor.
    let thickness: Float = 4

    private(set) var pos: [SIMD3<Float>]
    private var prev: [SIMD3<Float>]
    private var invMass: [Float]
    private var constraints: [Constraint] = []

    var origin: SIMD2<Float>

    // Tunables
    var gravity: Float = 3500          // points / s²
    var airDamping: Float = 0.995      // per substep
    var floorFriction: Float = 0.16    // fraction of tangential motion removed per contact substep
    var substeps = 8
    var iterations = 1
    var grabFollow: Float = 0.45       // how quickly grabbed points chase their targets per substep
    var sleepThreshold: Float = 0.03   // max per-substep displacement under which the cloth sleeps
    var drowsyThreshold: Float = 0.12  // ... or under this for `drowsyFrames` frames in a row
    var drowsyFrames = 45
    private var drowsyCount = 0
    private(set) var lastMaxMove: Float = 0
    /// Fabric buckles rather than resisting in-plane compression: constraints push back on
    /// compression with this fraction of their stretch stiffness.
    var compressionStiffness: Float = 0.25
    /// Compression corrections are capped per substep, so they act as gentle pressure rather than
    /// a stiff spring that rings against the layer stacking in a tight fold.
    var maxCompressionStep: Float = 0.1
    // Macro-stillness: if the cloth's extent and centroid have not moved for a while, it is only
    // vibrating in place (e.g. crumpled against the fence) and can sleep.
    private var stillFrames = 0
    private var lastExtent = SIMD4<Float>(0, 0, 0, 0)
    private var lastCentroid = SIMD3<Float>(0, 0, 0)
    var stillCheckInterval = 30
    var stillChecksToSleep = 3
    private var stillChecks = 0
    /// Safety net: a cloth nobody is holding sleeps after this many frames no matter what.
    /// A heap of fabric can "boil" indefinitely at sub-point amplitude otherwise.
    var maxAwakeFrames = 300
    /// Fraction of the required stacking separation applied per pass (relaxation).
    var stackRelaxation: Float = 0.5
    var layerSeparation: Float { thickness * 1.5 }
    /// Particles are kept inside this XY rectangle so the rug can never be dragged out of reach.
    var bounds: (min: SIMD2<Float>, max: SIMD2<Float>)?

    private(set) var isAsleep = false
    private(set) var grabs: [Grab] = []
    private var grabTarget: SIMD3<Float> = .zero
    private var maxZ: Float = 0

    // Spatial hash and accumulation scratch space for layer stacking
    private var cellHead: [Int32] = []
    private var cellNext: [Int32]
    private var stackDelta: [Float]
    private var stackCount: [Int32]
    private var stackDrag: [SIMD2<Float>]
    /// Friction between stacked layers, as a fraction of relative tangential motion removed per contact.
    var layerFriction: Float = 0.2

    var count: Int { cols * rows }
    var isGrabbing: Bool { !grabs.isEmpty }

    init(cols: Int, rows: Int, spacing: Float, origin: SIMD2<Float>) {
        self.cols = cols
        self.rows = rows
        self.spacing = spacing
        self.origin = origin
        let n = cols * rows
        pos = Array(repeating: .zero, count: n)
        prev = Array(repeating: .zero, count: n)
        invMass = Array(repeating: 1, count: n)
        cellNext = Array(repeating: -1, count: n)
        stackDelta = Array(repeating: 0, count: n)
        stackCount = Array(repeating: 0, count: n)
        stackDrag = Array(repeating: .zero, count: n)
        buildConstraints()
        reset()
    }

    @inline(__always) func index(_ i: Int, _ j: Int) -> Int { j * cols + i }

    private func buildConstraints() {
        constraints.removeAll(keepingCapacity: true)
        func add(_ i0: Int, _ j0: Int, _ i1: Int, _ j1: Int, _ stiffness: Float, compression: Float) {
            guard i1 >= 0, i1 < cols, j1 >= 0, j1 < rows else { return }
            let dx = Float(i1 - i0) * spacing
            let dy = Float(j1 - j0) * spacing
            constraints.append(Constraint(
                a: Int32(index(i0, j0)), b: Int32(index(i1, j1)),
                rest: (dx * dx + dy * dy).squareRoot(), stiffness: stiffness, compression: compression
            ))
        }
        // Long-range "cables" first: they carry a yank across the rug in a few sweeps
        // instead of letting it stretch like rubber.
        for skip in [8, 4] {
            for j in stride(from: 0, to: rows, by: skip) {
                for i in stride(from: 0, to: cols, by: skip) {
                    add(i, j, i + skip, j, 0.8, compression: 0)        // ropes: slack when folded
                    add(i, j, i, j + skip, 0.8, compression: 0)
                }
            }
        }
        // Structural
        for j in 0..<rows {
            for i in 0..<cols {
                add(i, j, i + 1, j, 1.0, compression: compressionStiffness)
                add(i, j, i, j + 1, 1.0, compression: compressionStiffness)
            }
        }
        // Shear
        for j in 0..<rows {
            for i in 0..<cols {
                add(i, j, i + 1, j + 1, 0.9, compression: compressionStiffness)
                add(i, j, i - 1, j + 1, 0.9, compression: compressionStiffness)
            }
        }
        // Bend (a thick rug resists sharp folding)
        for j in 0..<rows {
            for i in 0..<cols {
                add(i, j, i + 2, j, 0.35, compression: 1)              // bending stiffness works both ways
                add(i, j, i, j + 2, 0.35, compression: 1)
            }
        }
    }

    /// Lay the rug flat and centered at its rest position.
    func reset() {
        for j in 0..<rows {
            for i in 0..<cols {
                let p = SIMD3<Float>(origin.x + Float(i) * spacing, origin.y + Float(j) * spacing, thickness)
                pos[index(i, j)] = p
                prev[index(i, j)] = p
            }
        }
        for k in 0..<count { invMass[k] = 1 }
        grabs = []
        isAsleep = false
    }

    /// Load externally saved positions (same grid dimensions required).
    func load(positions: [SIMD3<Float>]) {
        guard positions.count == count else { return }
        pos = positions
        prev = positions
        for k in 0..<count { invMass[k] = 1 }
        grabs = []
        isAsleep = false
    }

    /// Grab one or more particles. Each grabbed particle chases `target + offset`.
    func grab(indices: [Int], offsets: [SIMD3<Float>], target: SIMD3<Float>) {
        for g in grabs { invMass[g.index] = 1 }
        grabs = []
        for (k, off) in zip(indices, offsets) where k >= 0 && k < count {
            grabs.append(Grab(index: k, offset: off))
            invMass[k] = 0
        }
        grabTarget = target
        wake()
    }

    func moveGrab(to target: SIMD3<Float>) {
        grabTarget = target
    }

    func release(velocity: SIMD3<Float>, dt: Float) {
        guard isGrabbing else { return }
        for g in grabs {
            invMass[g.index] = 1
            prev[g.index] = pos[g.index] - velocity * dt
        }
        grabs = []
        wake()
    }

    static let logTransitions = ProcessInfo.processInfo.environment["BLANKET_LOG"] != nil || Bundle.main.bundleURL.pathExtension == "app"

    func wake() {
        if isAsleep {
            if ClothSimulation.logTransitions { NSLog("Blanket: cloth awake") }
            isAsleep = false
            for k in 0..<count { prev[k] = pos[k] }
        }
    }

    /// Advance the simulation by `dt` seconds (clamped). Returns true if positions changed.
    @discardableResult
    func step(dt rawDt: Float) -> Bool {
        if isAsleep && !isGrabbing { return false }
        let dt = min(max(rawDt, 1.0 / 240.0), 1.0 / 30.0)
        let h = dt / Float(substeps)
        let g = SIMD3<Float>(0, 0, -gravity * h * h)
        let floorZ = thickness
        var maxMove: Float = 0
        var highest: Float = 0

        pos.withUnsafeMutableBufferPointer { p in
            prev.withUnsafeMutableBufferPointer { q in
                invMass.withUnsafeBufferPointer { w in
                    constraints.withUnsafeBufferPointer { cs in
                        for s in 0..<substeps {
                            // Integrate
                            for k in 0..<p.count where w[k] > 0 {
                                let x = p[k]
                                let v = (x - q[k]) * airDamping
                                q[k] = x
                                p[k] = x + v + g
                            }
                            // Grabbed points chase their targets (slight lag = weight)
                            for gr in grabs {
                                let x = p[gr.index]
                                let nx = x + (grabTarget + gr.offset - x) * grabFollow
                                q[gr.index] = x
                                p[gr.index] = nx
                            }
                            // Solve constraints, alternating sweep direction so corrections
                            // propagate equally fast both ways across the grid.
                            for it in 0..<iterations {
                                let forward = ((s + it) & 1) == 0
                                let n = cs.count
                                for idx in 0..<n {
                                    let c = cs[forward ? idx : n - 1 - idx]
                                    let a = Int(c.a), b = Int(c.b)
                                    let wa = w[a], wb = w[b]
                                    let wsum = wa + wb
                                    if wsum == 0 { continue }
                                    let d = p[b] - p[a]
                                    let len = simd_length(d)
                                    if len < 1e-5 { continue }
                                    var amount = (len - c.rest) * c.stiffness / wsum
                                    if len < c.rest {
                                        if c.compression == 0 { continue }
                                        amount = max(amount * c.compression, -maxCompressionStep)
                                    }
                                    let corr = d * (amount / len)
                                    p[a] += corr * wa
                                    p[b] -= corr * wb
                                }
                            }
                            // Floor collision + friction, and the screen fence
                            for k in 0..<p.count where w[k] > 0 {
                                var x = p[k]
                                if let b = bounds {
                                    if x.x < b.min.x { x.x = b.min.x } else if x.x > b.max.x { x.x = b.max.x }
                                    if x.y < b.min.y { x.y = b.min.y } else if x.y > b.max.y { x.y = b.max.y }
                                    p[k] = x
                                }
                                if x.z < floorZ {
                                    x.z = floorZ
                                    // Coulomb-ish: remove a fraction of tangential motion while touching.
                                    let dx = x.x - q[k].x
                                    let dy = x.y - q[k].y
                                    x.x -= dx * floorFriction
                                    x.y -= dy * floorFriction
                                    p[k] = x
                                }
                            }
                            var lifted = false
                            for k in 0..<p.count where p[k].z > floorZ + 0.5 { lifted = true; break }
                            if lifted && (s & 1) == 1 { stackLayers(p, q, w) }
                            if s == substeps - 1 {
                                for k in 0..<p.count {
                                    let m = simd_length_squared(p[k] - q[k])
                                    if m > maxMove { maxMove = m }
                                    if p[k].z > highest { highest = p[k].z }
                                }
                            }
                        }
                    }
                }
            }
        }
        maxZ = highest
        let move = maxMove.squareRoot()
        lastMaxMove = move

        if !isGrabbing {
            drowsyCount = move < drowsyThreshold ? drowsyCount + 1 : 0
            stillFrames += 1
            var macroStill = false
            if stillFrames % stillCheckInterval == 0 {
                var lo = SIMD2<Float>(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
                var hi = -lo
                var sum = SIMD3<Float>(0, 0, 0)
                for v in pos {
                    lo = simd_min(lo, SIMD2(v.x, v.y)); hi = simd_max(hi, SIMD2(v.x, v.y)); sum += v
                }
                let extent = SIMD4<Float>(lo.x, lo.y, hi.x, hi.y)
                let centroid = sum / Float(count)
                let unchanged = simd_length(extent - lastExtent) < 1.0 && simd_length(centroid - lastCentroid) < 0.5
                lastExtent = extent
                lastCentroid = centroid
                stillChecks = unchanged ? stillChecks + 1 : 0
                macroStill = stillChecks >= stillChecksToSleep
            }
            let exhausted = stillFrames >= maxAwakeFrames
            if move < sleepThreshold || drowsyCount >= drowsyFrames || macroStill || exhausted {
                if ClothSimulation.logTransitions {
                    NSLog("Blanket: cloth asleep (move %.3f, drowsy %d, still %d, exhausted %d)", move, drowsyCount >= drowsyFrames ? 1 : 0, macroStill ? 1 : 0, exhausted ? 1 : 0)
                }
                isAsleep = true
                drowsyCount = 0
                stillFrames = 0
                stillChecks = 0
                for k in 0..<count { prev[k] = pos[k] }
            }
        } else {
            drowsyCount = 0
            stillFrames = 0
            stillChecks = 0
        }
        return true
    }

    /// Approximate self-collision: particles that overlap in XY but are far apart on the grid
    /// are kept at least one rug thickness apart vertically, so folded layers stack instead of
    /// passing through each other. Acts like a contact: the supported particle loses its vertical velocity.
    private func stackLayers(_ p: UnsafeMutableBufferPointer<SIMD3<Float>>,
                             _ q: UnsafeMutableBufferPointer<SIMD3<Float>>,
                             _ w: UnsafeBufferPointer<Float>) {
        let n = p.count
        var minX = Float.greatestFiniteMagnitude, minY = minX
        var maxX = -Float.greatestFiniteMagnitude, maxY = maxX
        for k in 0..<n {
            let v = p[k]
            if v.x < minX { minX = v.x }; if v.x > maxX { maxX = v.x }
            if v.y < minY { minY = v.y }; if v.y > maxY { maxY = v.y }
        }
        let cell = spacing
        let nx = Int((maxX - minX) / cell) + 2
        let ny = Int((maxY - minY) / cell) + 2
        let cellCount = nx * ny
        if cellHead.count < cellCount { cellHead = Array(repeating: -1, count: cellCount) }
        for c in 0..<cellCount { cellHead[c] = -1 }

        @inline(__always) func cellOf(_ v: SIMD3<Float>) -> (Int, Int) {
            (Int((v.x - minX) / cell), Int((v.y - minY) / cell))
        }
        for k in 0..<n {
            let (cx, cy) = cellOf(p[k])
            let c = cy * nx + cx
            cellNext[k] = cellHead[c]
            cellHead[c] = Int32(k)
        }

        let sep = layerSeparation
        let touchSq = (0.8 * spacing) * (0.8 * spacing)
        let floorZ = thickness
        let maxStep: Float = 1.0
        for k in 0..<n { stackDelta[k] = 0; stackCount[k] = 0; stackDrag[k] = .zero }
        let mu = layerFriction
        var any = false
        for a in 0..<n {
            let pa = p[a]
            let ia = a % cols, ja = a / cols
            let (cx, cy) = cellOf(pa)
            for oy in -1...1 {
                let yy = cy + oy
                if yy < 0 || yy >= ny { continue }
                for ox in -1...1 {
                    let xx = cx + ox
                    if xx < 0 || xx >= nx { continue }
                    var b = Int(cellHead[yy * nx + xx])
                    while b >= 0 {
                        defer { b = Int(cellNext[b]) }
                        if b <= a { continue }
                        let ib = b % cols, jb = b / cols
                        if abs(ia - ib) <= 2 && abs(ja - jb) <= 2 { continue }
                        let pb = p[b]
                        let dx = pa.x - pb.x, dy = pa.y - pb.y
                        if dx * dx + dy * dy > touchSq { continue }
                        let dz = pa.z - pb.z
                        let adz = abs(dz)
                        if adz >= sep { continue }
                        if pa.z <= floorZ + 0.01 && pb.z <= floorZ + 0.01 { continue }
                        let wa = w[a], wb = w[b]
                        let wsum = wa + wb
                        if wsum == 0 { continue }
                        let push = sep - adz
                        let upper = dz >= 0 ? a : b
                        let lower = dz >= 0 ? b : a
                        stackDelta[upper] += push * w[upper] / wsum
                        stackDelta[lower] -= push * w[lower] / wsum
                        stackCount[upper] += 1
                        stackCount[lower] += 1
                        // Friction: pull the two layers' tangential motion toward each other.
                        let va = SIMD2(p[a].x - q[a].x, p[a].y - q[a].y)
                        let vb = SIMD2(p[b].x - q[b].x, p[b].y - q[b].y)
                        let rel = (va - vb) * mu
                        stackDrag[a] -= rel * (wa / wsum)
                        stackDrag[b] += rel * (wb / wsum)
                        any = true
                    }
                }
            }
        }
        guard any else { return }
        // Jacobi update: average the requested corrections and take at most half a layer per substep,
        // so a crumple with many overlapping layers converges instead of exploding.
        for k in 0..<n where stackCount[k] > 0 {
            let c = Float(stackCount[k])
            var dz = stackDelta[k] / c * stackRelaxation
            dz = min(max(dz, -maxStep), maxStep)
            var z = p[k].z + dz
            if z < floorZ { z = floorZ }
            p[k].z = z
            // Contact: no vertical velocity carried into the next substep.
            q[k].z = z
            let drag = stackDrag[k] / c
            p[k].x += drag.x
            p[k].y += drag.y
        }
    }

    /// Debug: the particles that moved most in the last substep, with grid coords and height.
    func topMovers(_ n: Int) -> [(index: Int, i: Int, j: Int, pos: SIMD3<Float>, move: Float)] {
        var all: [(Int, Float)] = []
        all.reserveCapacity(count)
        for k in 0..<count { all.append((k, simd_length(pos[k] - prev[k]))) }
        all.sort { $0.1 > $1.1 }
        return all.prefix(n).map { (k, m) in (k, k % cols, k / cols, pos[k], m) }
    }

    /// Smooth per-vertex normals via central differences across the grid.
    func computeNormals(into normals: inout [SIMD3<Float>]) {
        if normals.count != count { normals = Array(repeating: SIMD3<Float>(0, 0, 1), count: count) }
        pos.withUnsafeBufferPointer { p in
            normals.withUnsafeMutableBufferPointer { n in
                for j in 0..<rows {
                    let jm = max(j - 1, 0), jp = min(j + 1, rows - 1)
                    for i in 0..<cols {
                        let im = max(i - 1, 0), ip = min(i + 1, cols - 1)
                        let dx = p[j * cols + ip] - p[j * cols + im]
                        let dy = p[jp * cols + i] - p[jm * cols + i]
                        var nn = simd_cross(dx, dy)
                        let l = simd_length(nn)
                        nn = l > 1e-6 ? nn / l : SIMD3<Float>(0, 0, 1)
                        n[j * cols + i] = nn
                    }
                }
            }
        }
    }

    // MARK: - Static queries on a snapshot (safe to call from any thread with a copied array)

    /// True if the 2D point lies inside any quad of the given cloth positions.
    static func contains(point q: SIMD2<Float>, positions p: [SIMD3<Float>], cols: Int, rows: Int) -> Bool {
        guard p.count == cols * rows else { return false }
        var minX = Float.greatestFiniteMagnitude, minY = minX
        var maxX = -Float.greatestFiniteMagnitude, maxY = maxX
        for v in p {
            if v.x < minX { minX = v.x }; if v.x > maxX { maxX = v.x }
            if v.y < minY { minY = v.y }; if v.y > maxY { maxY = v.y }
        }
        if q.x < minX || q.x > maxX || q.y < minY || q.y > maxY { return false }

        @inline(__always) func inTri(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Bool {
            let d1 = (q.x - b.x) * (a.y - b.y) - (a.x - b.x) * (q.y - b.y)
            let d2 = (q.x - c.x) * (b.y - c.y) - (b.x - c.x) * (q.y - c.y)
            let d3 = (q.x - a.x) * (c.y - a.y) - (c.x - a.x) * (q.y - a.y)
            let hasNeg = d1 < 0 || d2 < 0 || d3 < 0
            let hasPos = d1 > 0 || d2 > 0 || d3 > 0
            return !(hasNeg && hasPos)
        }
        for j in 0..<(rows - 1) {
            for i in 0..<(cols - 1) {
                let a = p[j * cols + i], b = p[j * cols + i + 1]
                let c = p[(j + 1) * cols + i + 1], d = p[(j + 1) * cols + i]
                if inTri(a, b, c) || inTri(a, c, d) { return true }
            }
        }
        return false
    }

    /// Nearest particle to a 2D point, preferring higher (top-most) fabric when folds overlap.
    static func nearestParticle(to q: SIMD2<Float>, positions p: [SIMD3<Float>], maxDistance: Float) -> Int? {
        var best: Int?
        var bestScore = Float.greatestFiniteMagnitude
        let maxSq = maxDistance * maxDistance
        for (k, v) in p.enumerated() {
            let dx = v.x - q.x, dy = v.y - q.y
            let d2 = dx * dx + dy * dy
            if d2 > maxSq { continue }
            let score = d2 - v.z * 0.5
            if score < bestScore { bestScore = score; best = k }
        }
        return best
    }

    /// Particles within `radius` (in XY) of a centre particle that are also close to it in height,
    /// so a wide grab picks one layer of a fold, not both.
    static func particles(within radius: Float, of center: Int, positions p: [SIMD3<Float>], layerTolerance: Float) -> [Int] {
        guard center >= 0, center < p.count else { return [] }
        let c = p[center]
        let r2 = radius * radius
        var out: [Int] = []
        for (k, v) in p.enumerated() {
            let dx = v.x - c.x, dy = v.y - c.y
            if dx * dx + dy * dy <= r2 && abs(v.z - c.z) <= layerTolerance { out.append(k) }
        }
        return out
    }
}
