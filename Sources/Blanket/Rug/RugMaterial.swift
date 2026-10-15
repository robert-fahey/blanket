import AppKit
import SceneKit

enum RugMaterial {
    /// Physically based wool material with the procedural Persian pattern and a tiled weave normal map.
    static func makeRug(rugAspect: CGFloat) -> SCNMaterial {
        makeRug(image: RugTextureGenerator.makeRugImage(), rugAspect: rugAspect)
    }

    /// Top surface: front faces only; the underside is a separate material on the back faces.
    static func makeRug(image diffuse: CGImage, rugAspect: CGFloat) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.isDoubleSided = false
        m.cullMode = .back
        m.diffuse.contents = NSImage(cgImage: diffuse, size: NSSize(width: diffuse.width, height: diffuse.height))
        m.diffuse.mipFilter = .linear
        m.diffuse.maxAnisotropy = 8
        m.roughness.contents = NSNumber(value: 0.92)
        m.metalness.contents = NSNumber(value: 0.0)
        if let normal = WeaveNormalMap.make() {
            m.normal.contents = NSImage(cgImage: normal, size: NSSize(width: normal.width, height: normal.height))
            m.normal.wrapS = .repeat
            m.normal.wrapT = .repeat
            m.normal.mipFilter = .linear
            let repeatsX: Float = 18
            m.normal.contentsTransform = SCNMatrix4MakeScale(CGFloat(repeatsX), CGFloat(repeatsX) / rugAspect, 1)
            m.normal.intensity = 0.55
        }
        return m
    }

    /// Underside: rendered on the back faces with flipped lighting, paler and rougher than the pile.
    static func makeUnderside(image: CGImage, rugAspect: CGFloat) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.isDoubleSided = true   // SceneKit flips normals for back faces
        m.cullMode = .front      // draw only the faces that point away from the camera
        m.diffuse.contents = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        m.diffuse.mipFilter = .linear
        m.roughness.contents = NSNumber(value: 1.0)
        m.metalness.contents = NSNumber(value: 0.0)
        if let normal = WeaveNormalMap.make() {
            m.normal.contents = NSImage(cgImage: normal, size: NSSize(width: normal.width, height: normal.height))
            m.normal.wrapS = .repeat
            m.normal.wrapT = .repeat
            let repeatsX: Float = 18
            m.normal.contentsTransform = SCNMatrix4MakeScale(CGFloat(repeatsX), CGFloat(repeatsX) / rugAspect, 1)
            m.normal.intensity = 0.3
        }
        return m
    }

    /// Dark bound edge (selvedge) that gives the rug visible thickness.
    static func makeSelvedge() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = NSColor(calibratedRed: 0.09, green: 0.11, blue: 0.24, alpha: 1)
        m.roughness.contents = NSNumber(value: 1.0)
        m.metalness.contents = NSNumber(value: 0.0)
        m.isDoubleSided = true
        return m
    }

    /// Flat, dark, semi-transparent material for the projected floor shadow.
    static func makeShadow(opacity: CGFloat = 0.32) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = NSColor.black
        m.transparency = opacity
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        m.blendMode = .alpha
        return m
    }

    static func makeFringe() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        let img = RugTextureGenerator.makeFringeImage()
        m.diffuse.contents = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
        m.diffuse.wrapS = .repeat
        m.diffuse.wrapT = .clamp
        m.roughness.contents = NSNumber(value: 0.95)
        m.metalness.contents = NSNumber(value: 0.0)
        m.isDoubleSided = true
        m.transparencyMode = .aOne
        m.writesToDepthBuffer = false
        return m
    }
}
