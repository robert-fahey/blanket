import SceneKit
import simd

/// A skirt of quads around the rug's perimeter, hanging one rug thickness below the top
/// surface along the inverted vertex normal, so the rug reads as a thick object.
final class EdgeGeometry {
    let cols: Int
    let rows: Int
    let depth: Float
    private let element: SCNGeometryElement
    private let uvSource: SCNGeometrySource
    private var verts: [SIMD3<Float>]
    private var norms: [SIMD3<Float>]
    private let ring: [Int]   // perimeter particle indices, counter-clockwise

    init(cols: Int, rows: Int, depth: Float) {
        self.cols = cols
        self.rows = rows
        self.depth = depth
        var ring: [Int] = []
        for i in 0..<cols { ring.append(i) }                                   // bottom row, left→right
        for j in 1..<rows { ring.append(j * cols + cols - 1) }                 // right column, up
        for i in stride(from: cols - 2, through: 0, by: -1) { ring.append((rows - 1) * cols + i) } // top row, right→left
        for j in stride(from: rows - 2, through: 1, by: -1) { ring.append(j * cols) }           // left column, down
        self.ring = ring
        let segs = ring.count
        verts = Array(repeating: .zero, count: segs * 4)
        norms = Array(repeating: SIMD3<Float>(0, 0, 1), count: segs * 4)
        var uvs = [SIMD2<Float>]()
        var indices = [UInt32]()
        for q in 0..<segs {
            uvs += [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]
            let b = UInt32(q * 4)
            indices += [b, b + 1, b + 2, b, b + 2, b + 3]
        }
        uvSource = ClothGeometry.source(uvs, semantic: .texcoord)
        element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
    }

    func makeGeometry(from sim: ClothSimulation, normals: [SIMD3<Float>], material: SCNMaterial) -> SCNGeometry {
        let p = sim.pos
        let segs = ring.count
        for q in 0..<segs {
            let a = ring[q], b = ring[(q + 1) % segs]
            let pa = p[a], pb = p[b]
            let na = normals[a], nb = normals[b]
            let da = pa - na * depth, db = pb - nb * depth
            let base = q * 4
            verts[base] = pa; verts[base + 1] = pb; verts[base + 2] = db; verts[base + 3] = da
            // Outward-facing normal: perpendicular to the edge and to the surface normal.
            var n = simd_cross(pb - pa, na)
            let l = simd_length(n)
            n = l > 1e-6 ? n / l : SIMD3(0, 0, 1)
            for k in 0..<4 { norms[base + k] = n }
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
