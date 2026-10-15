import SceneKit
import simd

/// Builds an SCNGeometry for the cloth grid each frame from simulation positions.
final class ClothGeometry {
    let cols: Int
    let rows: Int
    private let element: SCNGeometryElement
    private let uvSource: SCNGeometrySource
    private(set) var normals: [SIMD3<Float>] = []

    init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows

        var uvs = [SIMD2<Float>]()
        uvs.reserveCapacity(cols * rows)
        for j in 0..<rows {
            for i in 0..<cols {
                uvs.append(SIMD2<Float>(Float(i) / Float(cols - 1), 1 - Float(j) / Float(rows - 1)))
            }
        }
        uvSource = ClothGeometry.source(uvs, semantic: .texcoord)

        var indices = [UInt32]()
        indices.reserveCapacity((cols - 1) * (rows - 1) * 6)
        for j in 0..<(rows - 1) {
            for i in 0..<(cols - 1) {
                let a = UInt32(j * cols + i), b = a + 1
                let d = UInt32((j + 1) * cols + i), c = d + 1
                indices += [a, b, c, a, c, d]
            }
        }
        element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
    }

    func makeGeometry(from sim: ClothSimulation, material: SCNMaterial) -> SCNGeometry {
        sim.computeNormals(into: &normals)
        let geo = SCNGeometry(
            sources: [
                ClothGeometry.source(sim.pos, semantic: .vertex),
                ClothGeometry.source(normals, semantic: .normal),
                uvSource,
            ],
            elements: [element]
        )
        geo.materials = [material]
        return geo
    }

    static func source(_ v: [SIMD3<Float>], semantic: SCNGeometrySource.Semantic) -> SCNGeometrySource {
        let data = v.withUnsafeBufferPointer { Data(buffer: $0) }
        return SCNGeometrySource(
            data: data, semantic: semantic, vectorCount: v.count,
            usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4,
            dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride
        )
    }

    static func source(_ v: [SIMD2<Float>], semantic: SCNGeometrySource.Semantic) -> SCNGeometrySource {
        let data = v.withUnsafeBufferPointer { Data(buffer: $0) }
        return SCNGeometrySource(
            data: data, semantic: semantic, vectorCount: v.count,
            usesFloatComponents: true, componentsPerVector: 2, bytesPerComponent: 4,
            dataOffset: 0, dataStride: MemoryLayout<SIMD2<Float>>.stride
        )
    }
}
