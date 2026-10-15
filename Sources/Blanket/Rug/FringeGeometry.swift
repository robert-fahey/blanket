import SceneKit
import simd

/// Tassel strips hanging off the two short (left/right) edges of the rug.
/// Each edge segment gets one quad that follows the edge particles.
final class FringeGeometry {
    let cols: Int
    let rows: Int
    let length: Float
    private let element: SCNGeometryElement
    private let uvSource: SCNGeometrySource
    private var verts: [SIMD3<Float>]
    private var norms: [SIMD3<Float>]

    init(cols: Int, rows: Int, length: Float) {
        self.cols = cols
        self.rows = rows
        self.length = length
        let segs = rows - 1
        let quadCount = segs * 2
        verts = Array(repeating: .zero, count: quadCount * 4)
        norms = Array(repeating: SIMD3<Float>(0, 0, 1), count: quadCount * 4)

        var uvs = [SIMD2<Float>]()
        var indices = [UInt32]()
        for qd in 0..<quadCount {
            // v = 0 at the rug edge (knots), v = 1 at the loose tips.
            uvs += [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]
            let b = UInt32(qd * 4)
            indices += [b, b + 1, b + 2, b, b + 2, b + 3]
        }
        uvSource = ClothGeometry.source(uvs, semantic: .texcoord)
        element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
    }

    func makeGeometry(from sim: ClothSimulation, material: SCNMaterial) -> SCNGeometry {
        let p = sim.pos
        let cols = sim.cols
        var q = 0
        for side in 0..<2 {
            let edgeI = side == 0 ? 0 : cols - 1
            let innerI = side == 0 ? 1 : cols - 2
            for j in 0..<(rows - 1) {
                let e0 = p[j * cols + edgeI], e1 = p[(j + 1) * cols + edgeI]
                let i0 = p[j * cols + innerI], i1 = p[(j + 1) * cols + innerI]
                var out0 = e0 - i0, out1 = e1 - i1
                let l0 = simd_length(out0), l1 = simd_length(out1)
                out0 = l0 > 1e-5 ? out0 / l0 : SIMD3(side == 0 ? -1 : 1, 0, 0)
                out1 = l1 > 1e-5 ? out1 / l1 : SIMD3(side == 0 ? -1 : 1, 0, 0)
                // Tassels sag onto the desk: pull the tips toward the floor.
                var t0 = e0 + out0 * length, t1 = e1 + out1 * length
                t0.z = max(sim.thickness * 0.5, t0.z - length * 0.6)
                t1.z = max(sim.thickness * 0.5, t1.z - length * 0.6)
                let base = q * 4
                verts[base] = e0; verts[base + 1] = e1; verts[base + 2] = t1; verts[base + 3] = t0
                var n = simd_cross(e1 - e0, t0 - e0)
                let ln = simd_length(n)
                n = ln > 1e-6 ? n / ln : SIMD3(0, 0, 1)
                if n.z < 0 { n = -n }
                for k in 0..<4 { norms[base + k] = n }
                q += 1
            }
        }
        let geo = SCNGeometry(
            sources: [
                ClothGeometry.source(verts, semantic: .vertex),
                ClothGeometry.source(norms, semantic: .normal),
                uvSource,
            ],
            elements: [element]
        )
        geo.materials = [material]
        return geo
    }
}
