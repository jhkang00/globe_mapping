import MetalKit
import simd

// MARK: - Uniforms

/// Uniforms structure must match Metal shader layout exactly.
/// Using SIMD4 for float3 to ensure proper 16-byte alignment.
struct Uniforms {
    var modelMatrix: float4x4        // 64 bytes, offset 0
    var viewMatrix: float4x4         // 64 bytes, offset 64
    var projectionMatrix: float4x4   // 64 bytes, offset 128
    var cameraPosition: SIMD4<Float> // 16 bytes, offset 192 (use .xyz in shader)
    var lightDirection: SIMD4<Float> // 16 bytes, offset 208 (use .xyz in shader)
    var time: Float                  // 4 bytes, offset 224
    var zoomLevel: Float             // 4 bytes, offset 228
    var _padding: SIMD2<Float> = .zero // 8 bytes padding for 16-byte alignment
}

// MARK: - Globe Renderer

@MainActor
final class GlobeRenderer: NSObject, MTKViewDelegate {
    
    // MARK: Metal State
    
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    
    // Pipelines
    private let spherePipeline: MTLRenderPipelineState
    private let linePipeline: MTLRenderPipelineState
    private let gridPipeline: MTLRenderPipelineState
    private let selectionPipeline: MTLRenderPipelineState
    private let strokePipeline: MTLRenderPipelineState
    private let eraserPipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    
    // Geometry
    private let sphereGeometry: SphereGeometry
    private let gridGeometry: GridGeometry
    let pathGeometry: PathGeometry
    let strokeGeometry: StrokeGeometry
    let eraserGeometry: EraserGeometry
    
    // MARK: Public State
    
    let camera = Camera()
    private let startTime = Date()
    
    // Current drawing stroke
    var currentStroke: [Coordinate] = [] {
        didSet { strokeGeometry.update(points: currentStroke) }
    }
    
    // Eraser position
    var eraserPosition: Coordinate? {
        didSet {
            if let pos = eraserPosition {
                eraserGeometry.update(center: pos, radiusDegrees: Double(eraserRadius))
            } else {
                eraserGeometry.clear()
            }
        }
    }
    var eraserRadius: Float = 2.0
    
    // MARK: Initialization
    
    init?(mtkView: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }
        
        self.device = device
        self.commandQueue = commandQueue
        
        mtkView.device = device
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.depthStencilPixelFormat = .depth32Float
        mtkView.clearColor = MTLClearColor(red: 0.05, green: 0.08, blue: 0.12, alpha: 1.0)
        mtkView.preferredFramesPerSecond = 60
        
        // Create geometry
        sphereGeometry = SphereGeometry(device: device)
        gridGeometry = GridGeometry(device: device)
        pathGeometry = PathGeometry(device: device)
        strokeGeometry = StrokeGeometry(device: device)
        eraserGeometry = EraserGeometry(device: device)
        
        // Create shader library
        guard let library = device.makeDefaultLibrary() else {
            print("Failed to create shader library")
            return nil
        }
        
        // Sphere pipeline
        let sphereDesc = MTLRenderPipelineDescriptor()
        sphereDesc.vertexFunction = library.makeFunction(name: "sphereVertex")
        sphereDesc.fragmentFunction = library.makeFunction(name: "sphereFragment")
        sphereDesc.vertexDescriptor = SphereVertex.descriptor
        sphereDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        sphereDesc.depthAttachmentPixelFormat = .depth32Float
        
        guard let spherePipeline = try? device.makeRenderPipelineState(descriptor: sphereDesc) else {
            print("Failed to create sphere pipeline")
            return nil
        }
        self.spherePipeline = spherePipeline
        
        // Line pipeline
        let lineDesc = MTLRenderPipelineDescriptor()
        lineDesc.vertexFunction = library.makeFunction(name: "lineVertex")
        lineDesc.fragmentFunction = library.makeFunction(name: "lineFragment")
        lineDesc.vertexDescriptor = LineVertex.descriptor
        lineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        lineDesc.colorAttachments[0].isBlendingEnabled = true
        lineDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        lineDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        lineDesc.depthAttachmentPixelFormat = .depth32Float
        
        guard let linePipeline = try? device.makeRenderPipelineState(descriptor: lineDesc) else {
            print("Failed to create line pipeline")
            return nil
        }
        self.linePipeline = linePipeline
        
        // Grid pipeline
        let gridDesc = MTLRenderPipelineDescriptor()
        gridDesc.vertexFunction = library.makeFunction(name: "gridVertex")
        gridDesc.fragmentFunction = library.makeFunction(name: "gridFragment")
        gridDesc.vertexDescriptor = LineVertex.descriptor
        gridDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        gridDesc.colorAttachments[0].isBlendingEnabled = true
        gridDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        gridDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        gridDesc.depthAttachmentPixelFormat = .depth32Float
        
        guard let gridPipeline = try? device.makeRenderPipelineState(descriptor: gridDesc) else {
            print("Failed to create grid pipeline")
            return nil
        }
        self.gridPipeline = gridPipeline
        
        // Selection pipeline
        let selDesc = MTLRenderPipelineDescriptor()
        selDesc.vertexFunction = library.makeFunction(name: "selectionVertex")
        selDesc.fragmentFunction = library.makeFunction(name: "selectionFragment")
        selDesc.vertexDescriptor = LineVertex.descriptor
        selDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        selDesc.colorAttachments[0].isBlendingEnabled = true
        selDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        selDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        selDesc.depthAttachmentPixelFormat = .depth32Float
        
        guard let selectionPipeline = try? device.makeRenderPipelineState(descriptor: selDesc) else {
            print("Failed to create selection pipeline")
            return nil
        }
        self.selectionPipeline = selectionPipeline
        
        // Stroke pipeline
        let strokeDesc = MTLRenderPipelineDescriptor()
        strokeDesc.vertexFunction = library.makeFunction(name: "lineVertex")
        strokeDesc.fragmentFunction = library.makeFunction(name: "strokeFragment")
        strokeDesc.vertexDescriptor = LineVertex.descriptor
        strokeDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        strokeDesc.depthAttachmentPixelFormat = .depth32Float
        
        guard let strokePipeline = try? device.makeRenderPipelineState(descriptor: strokeDesc) else {
            print("Failed to create stroke pipeline")
            return nil
        }
        self.strokePipeline = strokePipeline
        
        // Eraser pipeline
        let eraserDesc = MTLRenderPipelineDescriptor()
        eraserDesc.vertexFunction = library.makeFunction(name: "eraserVertex")
        eraserDesc.fragmentFunction = library.makeFunction(name: "eraserFragment")
        eraserDesc.vertexDescriptor = LineVertex.descriptor
        eraserDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        eraserDesc.colorAttachments[0].isBlendingEnabled = true
        eraserDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        eraserDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        eraserDesc.depthAttachmentPixelFormat = .depth32Float
        
        guard let eraserPipeline = try? device.makeRenderPipelineState(descriptor: eraserDesc) else {
            print("Failed to create eraser pipeline")
            return nil
        }
        self.eraserPipeline = eraserPipeline
        
        // Depth state
        let depthDesc = MTLDepthStencilDescriptor()
        depthDesc.depthCompareFunction = .less
        depthDesc.isDepthWriteEnabled = true
        
        guard let depthState = device.makeDepthStencilState(descriptor: depthDesc) else {
            print("Failed to create depth state")
            return nil
        }
        self.depthState = depthState
        
        super.init()
        
        mtkView.delegate = self
    }
    
    // MARK: MTKViewDelegate
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        camera.aspectRatio = Float(size.width / size.height)
    }
    
    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }
        
        var uniforms = Uniforms(
            modelMatrix: .identity,
            viewMatrix: camera.viewMatrix,
            projectionMatrix: camera.projectionMatrix,
            cameraPosition: SIMD4<Float>(camera.position, 0),
            lightDirection: SIMD4<Float>(normalize(SIMD3<Float>(0.5, 0.3, 1.0)), 0),
            time: Float(-startTime.timeIntervalSinceNow),
            zoomLevel: camera.zoomLevel
        )
        
        encoder.setDepthStencilState(depthState)
        
        // Draw sphere
        encoder.setRenderPipelineState(spherePipeline)
        encoder.setVertexBuffer(sphereGeometry.vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: sphereGeometry.indexCount,
            indexType: .uint32,
            indexBuffer: sphereGeometry.indexBuffer,
            indexBufferOffset: 0
        )
        
        // Draw grid
        if let gridBuffer = gridGeometry.vertexBuffer {
            encoder.setRenderPipelineState(gridPipeline)
            encoder.setVertexBuffer(gridBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
            encoder.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: gridGeometry.vertexCount)
        }
        
        // Draw paths
        if let pathBuffer = pathGeometry.vertexBuffer, pathGeometry.vertexCount > 0 {
            encoder.setRenderPipelineState(linePipeline)
            encoder.setVertexBuffer(pathBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
            encoder.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: pathGeometry.vertexCount)
        }
        
        // Draw selection highlight
        if let selBuffer = pathGeometry.selectionBuffer, pathGeometry.selectionVertexCount > 0 {
            encoder.setRenderPipelineState(selectionPipeline)
            encoder.setVertexBuffer(selBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
            encoder.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: pathGeometry.selectionVertexCount)
        }
        
        // Draw current stroke
        if let strokeBuffer = strokeGeometry.vertexBuffer, strokeGeometry.vertexCount > 0 {
            encoder.setRenderPipelineState(strokePipeline)
            encoder.setVertexBuffer(strokeBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
            encoder.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: strokeGeometry.vertexCount)
        }
        
        // Draw eraser preview
        if let eraserBuffer = eraserGeometry.vertexBuffer, eraserGeometry.vertexCount > 0 {
            encoder.setRenderPipelineState(eraserPipeline)
            encoder.setVertexBuffer(eraserBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
            encoder.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: eraserGeometry.vertexCount)
        }
        
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
    
    // MARK: Hit Testing
    
    /// Convert screen point to globe coordinate via ray casting
    func hitTest(screenPoint: CGPoint, viewSize: CGSize) -> Coordinate? {
        // Convert to normalized device coordinates (-1 to 1)
        let ndcX = Float(screenPoint.x / viewSize.width) * 2.0 - 1.0
        let ndcY = 1.0 - Float(screenPoint.y / viewSize.height) * 2.0
        
        // Unproject near and far points
        let invProj = camera.projectionMatrix.inverse
        let invView = camera.viewMatrix.inverse
        
        let nearNDC = SIMD4<Float>(ndcX, ndcY, 0, 1)
        let farNDC = SIMD4<Float>(ndcX, ndcY, 1, 1)
        
        var nearView = invProj * nearNDC
        nearView /= nearView.w
        
        var farView = invProj * farNDC
        farView /= farView.w
        
        let nearWorld = invView * nearView
        let farWorld = invView * farView
        
        let rayOrigin = SIMD3<Float>(nearWorld.x, nearWorld.y, nearWorld.z)
        let rayEnd = SIMD3<Float>(farWorld.x, farWorld.y, farWorld.z)
        let rayDir = normalize(rayEnd - rayOrigin)
        
        // Ray-sphere intersection
        let sphereRadius: Float = 1.0
        let oc = rayOrigin
        let a = dot(rayDir, rayDir)
        let b = 2.0 * dot(oc, rayDir)
        let c = dot(oc, oc) - sphereRadius * sphereRadius
        let discriminant = b * b - 4 * a * c
        
        guard discriminant >= 0 else { return nil }
        
        let t = (-b - sqrt(discriminant)) / (2.0 * a)
        guard t > 0 else { return nil }
        
        let hitPoint = rayOrigin + t * rayDir
        return Coordinate.fromCartesian(hitPoint)
    }
    
    // MARK: Update Methods
    
    func updatePaths(_ paths: [VectorPath], selection: (layerIndex: Int, pathIndex: Int, path: VectorPath)? = nil) {
        pathGeometry.update(paths: paths, selection: selection)
    }
}
