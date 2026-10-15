import AppKit
import QuartzCore
import SceneKit
import simd

/// Everything needed to (re)build a rug in a view.
struct RugConfig {
    var assets: RugAssets
    var coverage: Float
    /// Saved particle positions to restore, if their count matches the new grid.
    var restore: [SIMD3<Float>]? = nil
}

/// The simulation, geometry builders and materials for one rug. Replaced wholesale when the
/// style, image or size changes.
final class RugState {
    let sim: ClothSimulation
    let clothGeo: ClothGeometry
    let fringeGeo: FringeGeometry
    let edgeGeo: EdgeGeometry
    let rugMaterial: SCNMaterial
    let undersideMaterial: SCNMaterial
    let config: RugConfig

    init(config: RugConfig, viewSize: CGSize) {
        self.config = config
        let W = Float(viewSize.width), H = Float(viewSize.height)
        let aspect = Float(config.assets.aspect)
        let c = config.coverage
        let rugH = min(c * H, c * W / aspect)
        let rugW = rugH * aspect
        let cols = 72
        let spacing = rugW / Float(cols - 1)
        let rows = max(8, Int((rugH / spacing).rounded()) + 1)
        let origin = SIMD2<Float>((W - rugW) / 2, (H - Float(rows - 1) * spacing) / 2)

        sim = ClothSimulation(cols: cols, rows: rows, spacing: spacing, origin: origin)
        // Keep at least a hand's width of rug on screen.
        let fence: Float = 80
        sim.bounds = (SIMD2<Float>(-rugW + fence, -Float(rows - 1) * spacing + fence), SIMD2<Float>(W - fence, H - fence))
        if let saved = config.restore, saved.count == sim.count { sim.load(positions: saved) }

        clothGeo = ClothGeometry(cols: cols, rows: rows)
        fringeGeo = FringeGeometry(cols: cols, rows: rows, length: spacing * 1.7)
        edgeGeo = EdgeGeometry(cols: cols, rows: rows, depth: sim.thickness)
        rugMaterial = RugMaterial.makeRug(image: config.assets.top, rugAspect: config.assets.aspect)
        undersideMaterial = RugMaterial.makeUnderside(image: config.assets.underside, rugAspect: config.assets.aspect)
    }
}

/// Transparent SceneKit view that renders the rug and drives the cloth simulation.
final class RugView: SCNView, SCNSceneRendererDelegate {
    private struct Input {
        var grabIndices: [Int] = []
        var grabOffsets: [SIMD3<Float>] = []
        var grabGeneration = 0          // bumps on every new grab so the sim re-grabs
        var target = SIMD3<Float>(0, 0, 0)
        var releaseVelocity: SIMD3<Float>?
        var wantsReset = false
        var pendingConfig: RugConfig?
        var isGrabbing: Bool { !grabIndices.isEmpty }
    }

    /// Owned by the render thread; the reference itself is swapped under `inputLock`.
    private var rug: RugState
    private let selvedgeMaterial = RugMaterial.makeSelvedge()
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
    private let backNode = SCNNode()
    private let edgeNode = SCNNode()
    private let shadowNode = SCNNode()
    private let fringeShadowNode = SCNNode()
    private let fringeNode = SCNNode()
    private let cameraNode = SCNNode()
    private let keyLightNode = SCNNode()

    private let inputLock = NSLock()
    private var input = Input()
    private var snapshot: [SIMD3<Float>] = []
    private var lastTime: TimeInterval?

    /// Called on the main thread whenever the cloth falls asleep (used to persist its shape).
    var onSettle: (() -> Void)?

    // Interaction state (main thread only)
    private(set) var isDragging = false
    private var grabOffset = SIMD2<Float>(0, 0)
    private var lastDragPoint = SIMD2<Float>(0, 0)
    private var lastDragTime: TimeInterval = 0
    private var dragVelocity = SIMD2<Float>(0, 0)
    private var currentLift: Float = 0
    private var appliedGeneration = 0

    /// Base height a grabbed point is lifted off the desk, in points. A fast drag lifts higher,
    /// a slow one keeps the rug low so it slides instead of folding.
    var liftHeight: Float = 42
    /// Radius of an Option-drag wide grab, in grid spacings.
    var wideGrabRadius: Float = 3.2

    private func liftFor(speed: Float) -> Float {
        min(max(liftHeight * 0.5 + speed * 0.035, liftHeight * 0.5), liftHeight * 1.8)
    }
    /// Light travel direction; also used to project the fake floor shadow.
    private let lightDirection = simd_normalize(SIMD3<Float>(0.28, -0.22, -1))
    private let flatCamera = Settings.flatCamera
    private let perspectiveFOV: Float = 14

    init(frame: NSRect, config: RugConfig) {
        rug = RugState(config: config, viewSize: frame.size)
        super.init(frame: frame, options: nil)
        snapshot = rug.sim.pos
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
        camera.usesOrthographicProjection = flatCamera
        camera.projectionDirection = .vertical
        camera.fieldOfView = CGFloat(perspectiveFOV)
        camera.zNear = 10
        camera.zFar = 12000
        camera.wantsHDR = false
        // Contact shading where folded layers meet.
        camera.screenSpaceAmbientOcclusionIntensity = 1.1
        camera.screenSpaceAmbientOcclusionRadius = 18
        camera.screenSpaceAmbientOcclusionBias = 1
        camera.screenSpaceAmbientOcclusionDepthThreshold = 60
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)
        pointOfView = cameraNode

        let key = SCNLight()
        key.type = .directional
        key.intensity = 1150
        key.color = NSColor(calibratedRed: 1.0, green: 0.97, blue: 0.92, alpha: 1)
        key.castsShadow = true
        key.shadowMode = .forward
        key.shadowSampleCount = 16
        key.shadowRadius = 6
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
        backNode.renderingOrder = -1
        edgeNode.renderingOrder = -1
        clothNode.renderingOrder = 0

        scene.rootNode.addChildNode(shadowNode)
        scene.rootNode.addChildNode(fringeShadowNode)
        scene.rootNode.addChildNode(fringeNode)
        scene.rootNode.addChildNode(edgeNode)
        scene.rootNode.addChildNode(backNode)
        scene.rootNode.addChildNode(clothNode)

        // Shear-project everything onto the desk (z ≈ 0) along the light direction.
        let a = -lightDirection.x / lightDirection.z
        let b = -lightDirection.y / lightDirection.z
        let t = rug.sim.thickness
        var proj = matrix_identity_float4x4
        proj.columns.2 = SIMD4<Float>(a, b, 0.001, 0)
        proj.columns.3 = SIMD4<Float>(-a * t, -b * t, 0.6, 1)
        shadowNode.simdTransform = proj
        fringeShadowNode.simdTransform = proj

        rebuildGeometry()
    }

    func viewportChanged(to size: CGSize) {
        let W = Float(size.width), H = Float(size.height)
        // Distance at which the desk plane (z = 0) maps 1:1 onto screen points.
        let distance = flatCamera ? 2000 : (H / 2) / tan(perspectiveFOV * .pi / 360)
        cameraNode.simdPosition = SIMD3<Float>(W / 2, H / 2, distance)
        cameraNode.simdOrientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1))
        cameraNode.camera?.orthographicScale = Double(H / 2)
        keyLightNode.simdPosition = SIMD3<Float>(W / 2, H / 2, 1500)
        keyLightNode.simdLook(at: keyLightNode.simdPosition + lightDirection)
    }

    private func rebuildGeometry() {
        let r = rug
        let geo = r.clothGeo.makeGeometry(from: r.sim, material: r.rugMaterial)
        clothNode.geometry = geo
        let backGeo = geo.copy() as! SCNGeometry
        backGeo.materials = [r.undersideMaterial]
        backNode.geometry = backGeo
        edgeNode.geometry = r.edgeGeo.makeGeometry(from: r.sim, normals: r.clothGeo.normals, material: selvedgeMaterial)
        let shadowGeo = geo.copy() as! SCNGeometry
        shadowGeo.materials = [shadowMaterial]
        shadowNode.geometry = shadowGeo
        let fringe = r.fringeGeo.makeGeometry(from: r.sim, material: fringeMaterial)
        fringeNode.geometry = fringe
        let fringeShadow = fringe.copy() as! SCNGeometry
        fringeShadow.materials = [fringeShadowMaterial]
        fringeShadowNode.geometry = fringeShadow
    }

    // MARK: - Public controls (main thread)

    /// Replace the rug (style, image or size). Applied on the next simulation frame.
    func apply(_ config: RugConfig) {
        inputLock.lock()
        input.pendingConfig = config
        input.grabIndices = []
        input.grabOffsets = []
        inputLock.unlock()
        isDragging = false
        resume()
    }

    /// The configuration currently shown (or about to be).
    var currentConfig: RugConfig {
        inputLock.lock(); defer { inputLock.unlock() }
        return input.pendingConfig ?? rug.config
    }

    /// Current particle positions and grid, for persistence.
    func currentShape() -> (positions: [SIMD3<Float>], cols: Int, rows: Int) {
        inputLock.lock(); defer { inputLock.unlock() }
        return (snapshot, rug.sim.cols, rug.sim.rows)
    }

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
            let busy = self.input.isGrabbing || self.input.wantsReset || self.input.pendingConfig != nil
            self.inputLock.unlock()
            if !busy {
                self.isPlaying = false
                self.onSettle?()
            }
        }
    }

    func reset() {
        inputLock.lock()
        input.wantsReset = true
        input.grabIndices = []
        input.grabOffsets = []
        inputLock.unlock()
        isDragging = false
        resume()
    }

    /// Whether a point (in view coordinates) is over fabric, using the last published positions.
    func isPointOverCloth(_ p: CGPoint) -> Bool {
        inputLock.lock()
        let snap = snapshot
        let cols = rug.sim.cols, rows = rug.sim.rows
        inputLock.unlock()
        return ClothSimulation.contains(point: SIMD2(Float(p.x), Float(p.y)), positions: snap, cols: cols, rows: rows)
    }

    // MARK: - Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let q = SIMD2<Float>(Float(p.x), Float(p.y))
        let wide = event.modifierFlags.contains(.option)
        guard beginGrab(at: q, wide: wide, keepOffset: true) else { return }
        lastDragTime = event.timestamp
        NSCursor.closedHand.push()
    }

    /// Picks the particle(s) under `q` and starts a grab. Returns false if there is no fabric there.
    @discardableResult
    private func beginGrab(at q: SIMD2<Float>, wide: Bool, keepOffset: Bool) -> Bool {
        inputLock.lock()
        let snap = snapshot
        let sim = rug.sim
        inputLock.unlock()
        let pickRadius = sim.spacing * (wide ? 3 : 1.6)
        guard let center = ClothSimulation.nearestParticle(to: q, positions: snap, maxDistance: pickRadius) else { return false }
        let c = snap[center]
        grabOffset = keepOffset ? SIMD2(c.x, c.y) - q : .zero
        isDragging = true
        lastDragPoint = q
        dragVelocity = .zero
        currentLift = liftFor(speed: 0)

        var indices = [center]
        var offsets = [SIMD3<Float>(0, 0, 0)]
        if wide {
            let r = sim.spacing * wideGrabRadius
            indices = ClothSimulation.particles(within: r, of: center, positions: snap, layerTolerance: sim.thickness * 2)
            offsets = indices.map { k in
                let d = snap[k] - c
                let dist = (d.x * d.x + d.y * d.y).squareRoot()
                let dome = max(0, 1 - dist / r)
                // Rest offset in XY (keeps the patch rigid), lift tapering to the rim.
                return SIMD3<Float>(d.x, d.y, -(1 - dome) * currentLift * 0.8)
            }
        }
        let target = SIMD3<Float>(q.x + grabOffset.x, q.y + grabOffset.y, sim.thickness + currentLift)
        inputLock.lock()
        input.grabIndices = indices
        input.grabOffsets = offsets
        input.grabGeneration += 1
        input.target = target
        input.releaseVelocity = nil
        inputLock.unlock()
        resume()
        return true
    }

    private func setTarget(_ q: SIMD2<Float>) {
        inputLock.lock()
        let thickness = rug.sim.thickness
        input.target = SIMD3<Float>(q.x + grabOffset.x, q.y + grabOffset.y, thickness + currentLift)
        inputLock.unlock()
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
        let speed = simd_length(dragVelocity)
        currentLift = currentLift * 0.7 + liftFor(speed: speed) * 0.3
        setTarget(q)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        NSCursor.pop()
        // Stale velocity if the mouse paused before release.
        if event.timestamp - lastDragTime > 0.08 { dragVelocity = .zero }
        endGrab(velocity: dragVelocity)
    }

    private func endGrab(velocity: SIMD2<Float>) {
        inputLock.lock()
        input.grabIndices = []
        input.grabOffsets = []
        input.releaseVelocity = SIMD3<Float>(velocity.x, velocity.y, 0)
        inputLock.unlock()
    }

    // MARK: - Programmatic interaction (debug / tests)

    var debugIsAsleep: Bool { rug.sim.isAsleep }
    var debugMaxMove: Float { rug.sim.lastMaxMove }
    var debugProfileSolve: Double { rug.sim.profileSolve }
    var debugProfileStack: Double { rug.sim.profileStack }
    /// Particles that sit inside or within half a layer of a distant part of the cloth.
    func debugPenetrations() -> Int {
        inputLock.lock()
        let snap = snapshot
        let sim = rug.sim
        inputLock.unlock()
        return ClothSimulation.penetrations(positions: snap, cols: sim.cols, rows: sim.rows, separation: sim.layerSeparation)
    }
    func debugTopMovers(_ n: Int) -> String {
        let sim = rug.sim
        let b = sim.bounds.map { "fence x<\($0.max.x) y<\($0.max.y)" } ?? "no fence"
        let rows = sim.topMovers(n).map { m in
            String(format: "  #%d (i=%d,j=%d) pos=(%.1f, %.1f, %.1f) move=%.2f", m.index, m.i, m.j, m.pos.x, m.pos.y, m.pos.z, m.move)
        }
        return ([b] + rows).joined(separator: "\n")
    }

    /// Last published position of the particle at grid coordinates (i, j).
    func debugParticlePosition(i: Int, j: Int) -> SIMD3<Float> {
        inputLock.lock()
        let snap = snapshot
        let cols = rug.sim.cols
        inputLock.unlock()
        let k = j * cols + i
        return k >= 0 && k < snap.count ? snap[k] : .zero
    }

    var debugGrid: (cols: Int, rows: Int) {
        inputLock.lock(); defer { inputLock.unlock() }
        return (rug.sim.cols, rug.sim.rows)
    }

    /// Stretch ratio between the grabbed particle and the particle `cells` steps toward the rug
    /// centre along its row: 1.0 means inextensible, 1.3 means the rug stretched 30 % like rubber.
    func debugStretch(cells: Int) -> Float {
        inputLock.lock()
        let snap = snapshot
        let k = input.grabIndices.first
        let sim = rug.sim
        inputLock.unlock()
        guard let k, snap.count == sim.count else { return 0 }
        let i = k % sim.cols, j = k / sim.cols
        let dir = i < sim.cols / 2 ? 1 : -1
        let i2 = min(max(i + dir * cells, 0), sim.cols - 1)
        let d = simd_length(snap[j * sim.cols + i2] - snap[k])
        return d / (Float(abs(i2 - i)) * sim.spacing)
    }

    func debugBeginGrab(at q: SIMD2<Float>, wide: Bool = false) {
        beginGrab(at: q, wide: wide, keepOffset: false)
    }

    func debugMoveGrab(to q: SIMD2<Float>, speed: Float = 600) {
        currentLift = currentLift * 0.7 + liftFor(speed: speed) * 0.3
        setTarget(q)
    }

    func debugEndGrab(velocity: SIMD2<Float>) {
        isDragging = false
        endGrab(velocity: velocity)
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
        input.pendingConfig = nil
        inputLock.unlock()

        var rebuilt = false
        if let cfg = inp.pendingConfig {
            let next = RugState(config: cfg, viewSize: bounds.size)
            inputLock.lock()
            rug = next
            snapshot = next.sim.pos
            inputLock.unlock()
            appliedGeneration = 0
            rebuilt = true
        }
        let sim = rug.sim

        if inp.wantsReset { sim.reset() }

        if inp.isGrabbing {
            if appliedGeneration != inp.grabGeneration {
                appliedGeneration = inp.grabGeneration
                sim.grab(indices: inp.grabIndices, offsets: inp.grabOffsets, target: inp.target)
            } else {
                sim.moveGrab(to: inp.target)
            }
        } else if sim.isGrabbing {
            sim.release(velocity: inp.releaseVelocity ?? .zero, dt: dt / Float(sim.substeps))
        }

        let wasAsleep = sim.isAsleep
        let t0 = CACurrentMediaTime()
        let changed = sim.step(dt: dt) || inp.wantsReset || rebuilt
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
