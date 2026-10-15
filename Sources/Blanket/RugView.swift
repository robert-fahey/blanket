import AppKit
import QuartzCore
import SceneKit
import simd

/// Transparent SceneKit view that renders the rug and drives the cloth simulation.
final class RugView: SCNView, SCNSceneRendererDelegate {
    private struct Input {
        var grabIndex: Int?
        var target = SIMD3<Float>(0, 0, 0)
        var releaseVelocity: SIMD3<Float>?
        var wantsReset = false
    }

    private let sim: ClothSimulation
    private let clothGeo: ClothGeometry
    private let fringeGeo: FringeGeometry
    private let rugMaterial: SCNMaterial
    private let shadowMaterial = RugMaterial.makeShadow()
    private let fringeMaterial = RugMaterial.makeFringe()
    private lazy var fringeShadowMaterial: SCNMaterial = {
        let fm = RugMaterial.makeShadow(opacity: 0.18)
        fm.diffuse.contents = fringeMaterial.diffuse.contents
        fm.diffuse.wrapS = .repeat
        fm.transparencyMode = .aOne
        fm.multiply.contents = NSColor.black
        return fm
    }()

    // Profiling (only reported when BLANKET_SNAPSHOT_DIR is set)
    private(set) var profileStepSeconds: Double = 0
    private(set) var profileGeometrySeconds: Double = 0
    private(set) var profileFrames = 0

    private let clothNode = SCNNode()
    private let shadowNode = SCNNode()
    private let fringeShadowNode = SCNNode()
    private let fringeNode = SCNNode()
    private let cameraNode = SCNNode()
    private let keyLightNode = SCNNode()

    private let inputLock = NSLock()
    private var input = Input()
    private var snapshot: [SIMD3<Float>] = []
    private var lastTime: TimeInterval?

    // Interaction state (main thread only)
    private(set) var isDragging = false
    private var grabOffset = SIMD2<Float>(0, 0)
    private var lastDragPoint = SIMD2<Float>(0, 0)
    private var lastDragTime: TimeInterval = 0
    private var dragVelocity = SIMD2<Float>(0, 0)

    /// How high a grabbed point is lifted off the desk, in points.
    var liftHeight: Float = 42
    /// Light travel direction; also used to project the fake floor shadow.
    private let lightDirection = simd_normalize(SIMD3<Float>(0.28, -0.22, -1))

    override init(frame: NSRect, options: [String: Any]? = nil) {
        // Rug ~1.45:1, covering most of the screen.
        let W = Float(frame.width), H = Float(frame.height)
        let aspect: Float = 1.45
        let rugH = min(0.84 * H, 0.84 * W / aspect)
        let rugW = rugH * aspect
        let cols = 72
        let spacing = rugW / Float(cols - 1)
        let rows = Int((rugH / spacing).rounded()) + 1
        let origin = SIMD2<Float>((W - rugW) / 2, (H - Float(rows - 1) * spacing) / 2)

        sim = ClothSimulation(cols: cols, rows: rows, spacing: spacing, origin: origin)
        clothGeo = ClothGeometry(cols: cols, rows: rows)
        fringeGeo = FringeGeometry(cols: cols, rows: rows, length: spacing * 1.7)
        rugMaterial = RugMaterial.makeRug(rugAspect: CGFloat(rugW / rugH))

        super.init(frame: frame, options: options)
        snapshot = sim.pos
        configureView()
        buildScene()
        viewportChanged(to: frame.size)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func configureView() {
        backgroundColor = .clear
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
        antialiasingMode = .multisampling2X
        preferredFramesPerSecond = 60
        rendersContinuously = false
        isPlaying = true
        allowsCameraControl = false
        autoenablesDefaultLighting = false
        delegate = self
    }

    private func buildScene() {
        let scene = SCNScene()
        scene.background.contents = nil
        self.scene = scene

        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.zNear = 1
        camera.zFar = 4000
        camera.wantsHDR = false
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)
        pointOfView = cameraNode

        let key = SCNLight()
        key.type = .directional
        key.intensity = 1150
        key.color = NSColor(calibratedRed: 1.0, green: 0.97, blue: 0.92, alpha: 1)
        key.castsShadow = true
        key.shadowMode = .forward
        key.shadowSampleCount = 8
        key.shadowRadius = 4
        key.shadowBias = 2
        key.shadowMapSize = CGSize(width: 2048, height: 2048)
        key.orthographicScale = 1600
        key.automaticallyAdjustsShadowProjection = true
        key.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.55)
        keyLightNode.light = key
        scene.rootNode.addChildNode(keyLightNode)

        let fill = SCNLight()
        fill.type = .ambient
        fill.intensity = 420
        fill.color = NSColor(calibratedRed: 0.86, green: 0.9, blue: 1.0, alpha: 1)
        let fillNode = SCNNode()
        fillNode.light = fill
        scene.rootNode.addChildNode(fillNode)

        shadowNode.renderingOrder = -20
        shadowNode.castsShadow = false
        fringeShadowNode.renderingOrder = -21
        fringeShadowNode.castsShadow = false
        fringeNode.renderingOrder = -5
        fringeNode.castsShadow = false
        clothNode.renderingOrder = 0

        scene.rootNode.addChildNode(shadowNode)
        scene.rootNode.addChildNode(fringeShadowNode)
        scene.rootNode.addChildNode(fringeNode)
        scene.rootNode.addChildNode(clothNode)

        // Shear-project everything onto the desk (z ≈ 0) along the light direction.
        let a = -lightDirection.x / lightDirection.z
        let b = -lightDirection.y / lightDirection.z
        let t = sim.thickness
        var proj = matrix_identity_float4x4
        proj.columns.2 = SIMD4<Float>(a, b, 0.001, 0)
        proj.columns.3 = SIMD4<Float>(-a * t, -b * t, 0.6, 1)
        shadowNode.simdTransform = proj
        fringeShadowNode.simdTransform = proj

        rebuildGeometry()
    }

    func viewportChanged(to size: CGSize) {
        let W = Float(size.width), H = Float(size.height)
        cameraNode.simdPosition = SIMD3<Float>(W / 2, H / 2, 2000)
        cameraNode.simdOrientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1))
        cameraNode.camera?.orthographicScale = Double(H / 2)
        keyLightNode.simdPosition = SIMD3<Float>(W / 2, H / 2, 1500)
        keyLightNode.simdLook(at: keyLightNode.simdPosition + lightDirection)
    }

    private func rebuildGeometry() {
        let geo = clothGeo.makeGeometry(from: sim, material: rugMaterial)
        clothNode.geometry = geo
        let shadowGeo = geo.copy() as! SCNGeometry
        shadowGeo.materials = [shadowMaterial]
        shadowNode.geometry = shadowGeo
        let fringe = fringeGeo.makeGeometry(from: sim, material: fringeMaterial)
        fringeNode.geometry = fringe
        let fringeShadow = fringe.copy() as! SCNGeometry
        fringeShadow.materials = [fringeShadowMaterial]
        fringeShadowNode.geometry = fringeShadow
    }

    // MARK: - Public controls (main thread)

    /// Restart the render/simulation loop (it pauses itself while the cloth sleeps).
    func resume() {
        if !isPlaying {
            lastTime = nil
            isPlaying = true
        }
    }

    /// Called from the render thread once the cloth has fallen asleep.
    private func pauseIfIdle() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isDragging else { return }
            self.inputLock.lock()
            let busy = self.input.grabIndex != nil || self.input.wantsReset
            self.inputLock.unlock()
            if !busy { self.isPlaying = false }
        }
    }

    func reset() {
        inputLock.lock()
        input.wantsReset = true
        input.grabIndex = nil
        inputLock.unlock()
        isDragging = false
        resume()
    }

    /// Whether a point (in view coordinates) is over fabric, using the last published positions.
    func isPointOverCloth(_ p: CGPoint) -> Bool {
        inputLock.lock()
        let snap = snapshot
        inputLock.unlock()
        return ClothSimulation.contains(point: SIMD2(Float(p.x), Float(p.y)), positions: snap, cols: sim.cols, rows: sim.rows)
    }

    // MARK: - Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let q = SIMD2<Float>(Float(p.x), Float(p.y))
        inputLock.lock()
        let snap = snapshot
        inputLock.unlock()
        guard let k = ClothSimulation.nearestParticle(to: q, positions: snap, maxDistance: sim.spacing * 1.6) else { return }
        let particle = snap[k]
        grabOffset = SIMD2(particle.x, particle.y) - q
        isDragging = true
        lastDragPoint = q
        lastDragTime = event.timestamp
        dragVelocity = .zero
        let target = SIMD3<Float>(q.x + grabOffset.x, q.y + grabOffset.y, sim.thickness + liftHeight)
        inputLock.lock()
        input.grabIndex = k
        input.target = target
        input.releaseVelocity = nil
        inputLock.unlock()
        resume()
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let p = convert(event.locationInWindow, from: nil)
        let q = SIMD2<Float>(Float(p.x), Float(p.y))
        let dt = Float(max(event.timestamp - lastDragTime, 1.0 / 240.0))
        let v = (q - lastDragPoint) / dt
        dragVelocity = dragVelocity * 0.6 + v * 0.4
        lastDragPoint = q
        lastDragTime = event.timestamp
        inputLock.lock()
        input.target = SIMD3<Float>(q.x + grabOffset.x, q.y + grabOffset.y, sim.thickness + liftHeight)
        inputLock.unlock()
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        NSCursor.pop()
        // Stale velocity if the mouse paused before release.
        if event.timestamp - lastDragTime > 0.08 { dragVelocity = .zero }
        inputLock.lock()
        input.grabIndex = nil
        input.releaseVelocity = SIMD3<Float>(dragVelocity.x, dragVelocity.y, 0)
        inputLock.unlock()
    }

    // MARK: - Programmatic interaction (debug / tests)

    var debugIsAsleep: Bool { sim.isAsleep }

    func debugBeginGrab(at q: SIMD2<Float>) {
        inputLock.lock()
        let snap = snapshot
        inputLock.unlock()
        guard let k = ClothSimulation.nearestParticle(to: q, positions: snap, maxDistance: sim.spacing * 3) else { return }
        grabOffset = .zero
        isDragging = true
        inputLock.lock()
        input.grabIndex = k
        input.target = SIMD3<Float>(q.x, q.y, sim.thickness + liftHeight)
        inputLock.unlock()
        resume()
    }

    func debugMoveGrab(to q: SIMD2<Float>) {
        inputLock.lock()
        input.target = SIMD3<Float>(q.x, q.y, sim.thickness + liftHeight)
        inputLock.unlock()
    }

    func debugEndGrab(velocity: SIMD2<Float>) {
        isDragging = false
        inputLock.lock()
        input.grabIndex = nil
        input.releaseVelocity = SIMD3<Float>(velocity.x, velocity.y, 0)
        inputLock.unlock()
    }

    // MARK: - SCNSceneRendererDelegate (render thread)

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        let dt: Float
        if let last = lastTime { dt = Float(time - last) } else { dt = 1.0 / 60.0 }
        lastTime = time

        inputLock.lock()
        let inp = input
        input.releaseVelocity = nil
        input.wantsReset = false
        inputLock.unlock()

        if inp.wantsReset { sim.reset() }

        if let k = inp.grabIndex {
            if sim.grabbedIndex != k { sim.grab(index: k, target: inp.target) } else { sim.moveGrab(to: inp.target) }
        } else if sim.grabbedIndex != nil {
            sim.release(velocity: inp.releaseVelocity ?? .zero, dt: dt / Float(sim.substeps))
        }

        let wasAsleep = sim.isAsleep
        let t0 = CACurrentMediaTime()
        let changed = sim.step(dt: dt) || inp.wantsReset
        let t1 = CACurrentMediaTime()
        if changed {
            rebuildGeometry()
            profileStepSeconds += t1 - t0
            profileGeometrySeconds += CACurrentMediaTime() - t1
            profileFrames += 1
            let snap = sim.pos
            inputLock.lock()
            snapshot = snap
            inputLock.unlock()
        }
        if sim.isAsleep && (!wasAsleep || !changed) {
            pauseIfIdle()
        }
    }
}
