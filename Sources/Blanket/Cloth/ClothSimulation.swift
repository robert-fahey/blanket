import simd

/// Position-based-dynamics cloth lying on the z = 0 "desk" plane.
/// Units are screen points. +Z points toward the viewer (out of the screen).
final class ClothSimulation {
    struct Constraint {
        var a: Int32
        var b: Int32
        var rest: Float
        var stiffness: Float
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
    var substeps = 6
    var iterations = 2
    var grabFollow: Float = 0.45       // how quickly the grabbed point chases its target per substep
    var sleepThreshold: Float = 0.015  // max per-substep displacement under which the cloth sleeps

    private(set) var isAsleep = false
    private(set) var grabbedIndex: Int?
    private var grabTarget: SIMD3<Float> = .zero

    var count: Int { cols * rows }

    init(cols: Int, rows: Int, spacing: Float, origin: SIMD2<Float>) {
        self.cols = cols
        self.rows = rows
        self.spacing = spacing
        self.origin = origin
        let n = cols * rows
        pos = Array(repeating: .zero, count: n)
        prev = Array(repeating: .zero, count: n)
        invMass = Array(repeating: 1, count: n)
        buildConstraints()
        reset()
    }

    @inline(__always) func index(_ i: Int, _ j: Int) -> Int { j * cols + i }

    private func buildConstraints() {
        constraints.removeAll(keepingCapacity: true)
        func add(_ i0: Int, _ j0: Int, _ i1: Int, _ j1: Int, _ stiffness: Float) {
            guard i1 >= 0, i1 < cols, j1 >= 0, j1 < rows else { return }
            let dx = Float(i1 - i0) * spacing
            let dy = Float(j1 - j0) * spacing
            constraints.append(Constraint(
                a: Int32(index(i0, j0)), b: Int32(index(i1, j1)),
                rest: (dx * dx + dy * dy).squareRoot(), stiffness: stiffness
            ))
        }
        // Structural
        for j in 0..<rows {
            for i in 0..<cols {
                add(i, j, i + 1, j, 1.0)
                add(i, j, i, j + 1, 1.0)
            }
        }
        // Shear
        for j in 0..<rows {
            for i in 0..<cols {
                add(i, j, i + 1, j + 1, 0.9)
                add(i, j, i - 1, j + 1, 0.9)
            }
        }
        // Bend (a thick rug resists sharp folding)
        for j in 0..<rows {
            for i in 0..<cols {
                add(i, j, i + 2, j, 0.35)
                add(i, j, i, j + 2, 0.35)
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
        grabbedIndex = nil
        isAsleep = false
    }

    func grab(index k: Int, target: SIMD3<Float>) {
        guard k >= 0, k < count else { return }
        if let old = grabbedIndex { invMass[old] = 1 }
        grabbedIndex = k
        invMass[k] = 0
        grabTarget = target
        wake()
    }

    func moveGrab(to target: SIMD3<Float>) {
        grabTarget = target
    }

    func release(velocity: SIMD3<Float>, dt: Float) {
        guard let k = grabbedIndex else { return }
        invMass[k] = 1
        prev[k] = pos[k] - velocity * dt
        grabbedIndex = nil
        wake()
    }

    func wake() {
        if isAsleep {
            isAsleep = false
            for k in 0..<count { prev[k] = pos[k] }
        }
    }

    /// Advance the simulation by `dt` seconds (clamped). Returns true if positions changed.
    @discardableResult
    func step(dt rawDt: Float) -> Bool {
        if isAsleep && grabbedIndex == nil { return false }
        let dt = min(max(rawDt, 1.0 / 240.0), 1.0 / 30.0)
        let h = dt / Float(substeps)
        let g = SIMD3<Float>(0, 0, -gravity * h * h)
        let floorZ = thickness
        var maxMove: Float = 0

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
                            // Grabbed point chases its target (slight lag = weight)
                            if let gk = grabbedIndex {
                                let x = p[gk]
                                let nx = x + (grabTarget - x) * grabFollow
                                q[gk] = x
                                p[gk] = nx
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
                                    let corr = d * ((len - c.rest) / len * c.stiffness / wsum)
                                    p[a] += corr * wa
                                    p[b] -= corr * wb
                                }
                            }
                            // Floor collision + friction
                            for k in 0..<p.count where w[k] > 0 {
                                var x = p[k]
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
                            if s == substeps - 1 {
                                for k in 0..<p.count {
                                    let m = simd_length_squared(p[k] - q[k])
                                    if m > maxMove { maxMove = m }
                                }
                            }
                        }
                    }
                }
            }
        }

        if grabbedIndex == nil && maxMove.squareRoot() < sleepThreshold {
            isAsleep = true
            for k in 0..<count { prev[k] = pos[k] }
        }
        return true
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
        // Quick bounding-box reject
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
            let score = d2 - v.z * 0.5   // small bonus for lifted fabric
            if score < bestScore { bestScore = score; best = k }
        }
        return best
    }
}
