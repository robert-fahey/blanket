import Foundation
import QuartzCore
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
        /// Largest compression correction per substep (points).
        var cap: Float
    }

    struct Grab {
        var index: Int
        var offset: SIMD3<Float>
    }

    let cols: Int
    let rows: Int
    let spacing: Float
    /// Height of the rug's underside above the desk. Keeps it from z-fighting the floor.
    let thickness: Float = 8

    private(set) var pos: [SIMD3<Float>]
    private var prev: [SIMD3<Float>]
    private var invMass: [Float]
    private var constraints: [Constraint] = []

    var origin: SIMD2<Float>

    // Tunables
    var gravity: Float = 3500          // points / s²
    var airDamping: Float = 0.995      // per substep
    var floorFriction: Float = 0.16    // fraction of tangential motion removed per contact substep
    var substeps = 6
    var iterations = 1
    var grabFollow: Float = 0.45       // how quickly grabbed points chase their targets per substep
    var sleepThreshold: Float = 0.03   // max per-substep displacement under which the cloth sleeps
    var drowsyThreshold: Float = 0.12  // ... or under this for `drowsyFrames` frames in a row
    var drowsyFrames = 45
    private var drowsyCount = 0
    private(set) var lastMaxMove: Float = 0
    // Profiling accumulators (seconds)
    private(set) var profileSolve: Double = 0
    private(set) var profileStack: Double = 0
    private(set) var profileOther: Double = 0
    /// Fabric buckles rather than resisting in-plane compression: constraints push back on
    /// compression with this fraction of their stretch stiffness.
    var compressionStiffness: Float = 0.25
    /// Compression corrections are capped per substep, so they act as gentle pressure rather than
    /// a stiff spring that rings against the layer stacking in a tight fold.
    var maxCompressionStep: Float = 0.1
    /// Bend constraints may push harder, so a crease keeps a radius instead of becoming a knife edge.
    var maxBendStep: Float = 0.35
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
    /// Every particle carries a collision sphere of this diameter (in grid spacings). At 1.0 the
    /// spheres of a sheet overlap enough that nothing, points or edges, can thread between them.
    var contactDiameter: Float = 1.0
    /// Particles are kept inside this XY rectangle so the rug can never be dragged out of reach.
    var bounds: (min: SIMD2<Float>, max: SIMD2<Float>)?

    private(set) var isAsleep = false
    private(set) var grabs: [Grab] = []
    private var grabTarget: SIMD3<Float> = .zero
    private var maxZ: Float = 0

    // Spatial hash and accumulation scratch space for layer stacking
    private var cellHead: [Int32] = []
    private var cellNext: [Int32]
    private var stackDelta: [SIMD3<Float>]
    private var stackCount: [Int32]
    private var stackNormal: [SIMD3<Float>]
    private var stackOtherVel: [SIMD3<Float>]
    /// Particles that had a distant neighbour on the first substep of the frame; only these are
    /// probed on the remaining substeps (positions move far less than a cell within one frame).
    private var probe: [Bool]
    private var hashMinX: Float = 0, hashMinY: Float = 0
    private var hashNX = 1, hashNY = 1
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
        stackDelta = Array(repeating: .zero, count: n)
        stackCount = Array(repeating: 0, count: n)
        stackNormal = Array(repeating: .zero, count: n)
        stackOtherVel = Array(repeating: .zero, count: n)
        probe = Array(repeating: true, count: n)
        buildConstraints()
        reset()
    }

    @inline(__always) func index(_ i: Int, _ j: Int) -> Int { j * cols + i }

    private func buildConstraints() {
        constraints.removeAll(keepingCapacity: true)
        func add(_ i0: Int, _ j0: Int, _ i1: Int, _ j1: Int, _ stiffness: Float, compression: Float, cap: Float) {
            guard i1 >= 0, i1 < cols, j1 >= 0, j1 < rows else { return }
            let dx = Float(i1 - i0) * spacing
            let dy = Float(j1 - j0) * spacing
            constraints.append(Constraint(
                a: Int32(index(i0, j0)), b: Int32(index(i1, j1)),
                rest: (dx * dx + dy * dy).squareRoot(), stiffness: stiffness, compression: compression, cap: cap
            ))
        }
        // Long-range "cables" first: they carry a yank across the rug in a few sweeps
        // instead of letting it stretch like rubber.
        for skip in [8, 4] {
            for j in stride(from: 0, to: rows, by: skip) {
                for i in stride(from: 0, to: cols, by: skip) {
                    add(i, j, i + skip, j, 0.8, compression: 0, cap: 0)        // ropes: slack when folded
                    add(i, j, i, j + skip, 0.8, compression: 0, cap: 0)
                }
            }
        }
        // Structural
        for j in 0..<rows {
            for i in 0..<cols {
                add(i, j, i + 1, j, 1.0, compression: compressionStiffness, cap: maxCompressionStep)
                add(i, j, i, j + 1, 1.0, compression: compressionStiffness, cap: maxCompressionStep)
            }
        }
        // Shear
        for j in 0..<rows {
            for i in 0..<cols {
                add(i, j, i + 1, j + 1, 0.9, compression: compressionStiffness, cap: maxCompressionStep)
                add(i, j, i - 1, j + 1, 0.9, compression: compressionStiffness, cap: maxCompressionStep)
            }
        }
        // Bend (a thick rug resists sharp folding). Skip-2 and skip-3 together hold a crease
        // radius of about three cells, which is the zone the layer contact leaves alone.
        for j in 0..<rows {
            for i in 0..<cols {
                add(i, j, i + 2, j, 0.5, compression: 1, cap: maxBendStep)
                add(i, j, i, j + 2, 0.5, compression: 1, cap: maxBendStep)
            }
        }
        for j in stride(from: 0, to: rows, by: 2) {
            for i in stride(from: 0, to: cols, by: 2) {
                add(i, j, i + 3, j, 0.3, compression: 1, cap: maxBendStep)
                add(i, j, i, j + 3, 0.3, compression: 1, cap: maxBendStep)
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
                            let tSolve = CACurrentMediaTime()
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
                                        amount = max(amount * c.compression, -c.cap)
                                    }
                                    let corr = d * (amount / len)
                                    p[a] += corr * wa
                                    p[b] -= corr * wb
                                }
                            }
                            profileSolve += CACurrentMediaTime() - tSolve
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
                            if lifted {
                                let tStack = CACurrentMediaTime()
                                stackLayers(p, q, w, fullScan: s == 0)
                                profileStack += CACurrentMediaTime() - tStack
                            }
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

    /// Self-collision: every particle carries a sphere of diameter `contactDiameter` spacings, and
    /// spheres of particles that are not grid neighbours may not overlap. Because the spheres of
    /// one sheet overlap each other, neither points nor edges of another sheet can pass through.
    /// Contacts are inelastic (approaching velocity along the contact normal is removed) and have
    /// friction, so stacked layers rest on each other and move together.
    private func stackLayers(_ p: UnsafeMutableBufferPointer<SIMD3<Float>>,
                             _ q: UnsafeMutableBufferPointer<SIMD3<Float>>,
                             _ w: UnsafeBufferPointer<Float>, fullScan: Bool) {
        let n = p.count
        let cell = spacing
        @inline(__always) func cellOf(_ v: SIMD3<Float>) -> (Int, Int) {
            (min(max(Int((v.x - hashMinX) / cell), 0), hashNX - 1), min(max(Int((v.y - hashMinY) / cell), 0), hashNY - 1))
        }
        // The hash is rebuilt once per frame; within a frame nothing moves more than a fraction
        // of a cell, and the 3 x 3 cell scan has a full cell of margin.
        if fullScan {
            var minX = Float.greatestFiniteMagnitude, minY = minX
            var maxX = -Float.greatestFiniteMagnitude, maxY = maxX
            for k in 0..<n {
                let v = p[k]
                if v.x < minX { minX = v.x }; if v.x > maxX { maxX = v.x }
                if v.y < minY { minY = v.y }; if v.y > maxY { maxY = v.y }
            }
            hashMinX = minX - cell; hashMinY = minY - cell
            hashNX = Int((maxX - hashMinX) / cell) + 3
            hashNY = Int((maxY - hashMinY) / cell) + 3
            let cellCount = hashNX * hashNY
            if cellHead.count < cellCount { cellHead = Array(repeating: -1, count: cellCount) }
            for c in 0..<cellCount { cellHead[c] = -1 }
            for k in 0..<n {
                let (cx, cy) = cellOf(p[k])
                let c = cy * hashNX + cx
                cellNext[k] = cellHead[c]
                cellHead[c] = Int32(k)
            }
        }
        let nx = hashNX, ny = hashNY
        let D = spacing * contactDiameter
        let D2 = D * D
        let floorZ = thickness
        let mu = layerFriction
        for k in 0..<n { stackDelta[k] = .zero; stackCount[k] = 0; stackNormal[k] = .zero; stackOtherVel[k] = .zero }
        var any = false

        for a in 0..<n {
            if !fullScan && !probe[a] { continue }
            let wa = w[a]
            let pa = p[a]
            let ia = a % cols, ja = a / cols
            let (cx, cy) = cellOf(pa)
            var sawFar = false
            for oy in -1...1 {
                let yy = cy + oy
                if yy < 0 || yy >= ny { continue }
                for ox in -1...1 {
                    let xx = cx + ox
                    if xx < 0 || xx >= nx { continue }
                    var b = Int(cellHead[yy * nx + xx])
                    while b >= 0 {
                        defer { b = Int(cellNext[b]) }
                        if b == a { continue }
                        let ib = b % cols, jb = b / cols
                        if abs(ia - ib) <= 1 && abs(ja - jb) <= 1 { continue }
                        sawFar = true
                        let d = p[b] - pa
                        let d2 = simd_length_squared(d)
                        if d2 >= D2 { continue }
                        let wb = w[b]
                        let wsum = wa + wb
                        if wsum == 0 || wa == 0 { continue }
                        let dist = d2.squareRoot()
                        // Degenerate: coincident particles separate vertically.
                        let nrm = dist > 1e-4 ? d / dist : SIMD3<Float>(0, 0, 1)
                        let push = (D - dist) * (wa / wsum)
                        stackDelta[a] -= nrm * push
                        stackNormal[a] -= nrm
                        stackOtherVel[a] += p[b] - q[b]
                        stackCount[a] += 1
                        any = true
                    }
                }
            }
            if fullScan { probe[a] = sawFar }
        }
        guard any else { return }

        // Jacobi update: average the corrections, then make the contact inelastic with friction.
        for k in 0..<n where stackCount[k] > 0 {
            let c = Float(stackCount[k])
            var x = p[k] + stackDelta[k] / c
            if x.z < floorZ { x.z = floorZ }
            var v = x - q[k]
            let nl = simd_length(stackNormal[k])
            if nl > 1e-6 {
                let nrm = stackNormal[k] / nl          // points away from the other layer
                let vOther = stackOtherVel[k] / c
                var rel = v - vOther
                let vn = simd_dot(rel, nrm)
                if vn < 0 { rel -= nrm * vn }          // stop approaching
                let tangential = rel - nrm * simd_dot(rel, nrm)
                rel -= tangential * mu                 // friction against the other layer
                v = vOther + rel
            }
            p[k] = x
            q[k] = x - v
        }
    }

    /// Debug metric: particles closer than half a layer to (or inside) a distant part of the cloth.
    static func penetrations(positions p: [SIMD3<Float>], cols: Int, rows: Int, separation: Float) -> Int {
        guard p.count == cols * rows else { return 0 }
        var count = 0
        let limit = separation * 0.5
        for a in 0..<p.count {
            let pa = p[a]
            let ia = a % cols, ja = a / cols
            var hit = false
            for qj in 0..<(rows - 1) where !hit {
                if ja >= qj - 2 && ja <= qj + 3 { continue }
                for qi in 0..<(cols - 1) {
                    if ia >= qi - 2 && ia <= qi + 3 { continue }
                    let c0 = qj * cols + qi, c1 = c0 + 1, c3 = c0 + cols, c2 = c3 + 1
                    let A = p[c0], B = p[c1], C = p[c2], D = p[c3]
                    let lo = min(min(A.x, B.x), min(C.x, D.x)), hi = max(max(A.x, B.x), max(C.x, D.x))
                    if pa.x < lo || pa.x > hi { continue }
                    let loy = min(min(A.y, B.y), min(C.y, D.y)), hiy = max(max(A.y, B.y), max(C.y, D.y))
                    if pa.y < loy || pa.y > hiy { continue }
                    for tri in [(A, B, C), (A, C, D)] {
                        let (T0, T1, T2) = tri
                        let v0x = T1.x - T0.x, v0y = T1.y - T0.y, v1x = T2.x - T0.x, v1y = T2.y - T0.y
                        let v2x = pa.x - T0.x, v2y = pa.y - T0.y
                        let d00 = v0x * v0x + v0y * v0y, d01 = v0x * v1x + v0y * v1y, d11 = v1x * v1x + v1y * v1y
                        let d20 = v2x * v0x + v2y * v0y, d21 = v2x * v1x + v2y * v1y
                        let denom = d00 * d11 - d01 * d01
                        if abs(denom) < 1e-6 { continue }
                        let b1 = (d11 * d20 - d01 * d21) / denom, b2 = (d00 * d21 - d01 * d20) / denom, b0 = 1 - b1 - b2
                        if b0 < 0 || b1 < 0 || b2 < 0 { continue }
                        let zs = b0 * T0.z + b1 * T1.z + b2 * T2.z
                        if abs(pa.z - zs) < limit { count += 1; hit = true }
                        break
                    }
                    if hit { break }
                }
            }
        }
        return count
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
