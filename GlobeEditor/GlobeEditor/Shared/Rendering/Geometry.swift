import Metal
import simd

// MARK: - Vertex Structures

struct SphereVertex {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var texCoord: SIMD2<Float>
    
    static var descriptor: MTLVertexDescriptor {
        let desc = MTLVertexDescriptor()
        
        // Position
        desc.attributes[0].format = .float3
        desc.attributes[0].offset = 0
        desc.attributes[0].bufferIndex = 0
        
        // Normal
        desc.attributes[1].format = .float3
        desc.attributes[1].offset = MemoryLayout<SIMD3<Float>>.stride
        desc.attributes[1].bufferIndex = 0
        
        // TexCoord
        desc.attributes[2].format = .float2
        desc.attributes[2].offset = MemoryLayout<SIMD3<Float>>.stride * 2
        desc.attributes[2].bufferIndex = 0
        
        desc.layouts[0].stride = MemoryLayout<SphereVertex>.stride
        
        return desc
    }
}

struct LineVertex {
    var position: SIMD3<Float>
    var color: SIMD4<Float>
    
    static var descriptor: MTLVertexDescriptor {
        let desc = MTLVertexDescriptor()
        
        desc.attributes[0].format = .float3
        desc.attributes[0].offset = 0
        desc.attributes[0].bufferIndex = 0
        
        desc.attributes[1].format = .float4
        desc.attributes[1].offset = MemoryLayout<SIMD3<Float>>.stride
        desc.attributes[1].bufferIndex = 0
        
        desc.layouts[0].stride = MemoryLayout<LineVertex>.stride
        
        return desc
    }
}

// MARK: - Sphere Geometry

/// UV sphere mesh
final class SphereGeometry: @unchecked Sendable {
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexCount: Int
    
    init(device: MTLDevice, latSegments: Int = 64, lonSegments: Int = 128) {
        var vertices: [SphereVertex] = []
        var indices: [UInt32] = []
        
        // Generate vertices
        for lat in 0...latSegments {
            let theta = Float(lat) * .pi / Float(latSegments)
            let sinTheta = sin(theta)
            let cosTheta = cos(theta)
            
            for lon in 0...lonSegments {
                let phi = Float(lon) * 2.0 * .pi / Float(lonSegments)
                let sinPhi = sin(phi)
                let cosPhi = cos(phi)
                
                let x = cosPhi * sinTheta
                let y = sinPhi * sinTheta
                let z = cosTheta
                
                let position = SIMD3<Float>(x, y, z)
                let normal = normalize(position)
                let texCoord = SIMD2<Float>(
                    Float(lon) / Float(lonSegments),
                    Float(lat) / Float(latSegments)
                )
                
                vertices.append(SphereVertex(position: position, normal: normal, texCoord: texCoord))
            }
        }
        
        // Generate indices
        for lat in 0..<latSegments {
            for lon in 0..<lonSegments {
                let first = UInt32(lat * (lonSegments + 1) + lon)
                let second = first + UInt32(lonSegments + 1)
                
                indices.append(first)
                indices.append(second)
                indices.append(first + 1)
                
                indices.append(second)
                indices.append(second + 1)
                indices.append(first + 1)
            }
        }
        
        self.vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: vertices.count * MemoryLayout<SphereVertex>.stride,
            options: .storageModeShared
        )!
        
        self.indexBuffer = device.makeBuffer(
            bytes: indices,
            length: indices.count * MemoryLayout<UInt32>.stride,
            options: .storageModeShared
        )!
        
        self.indexCount = indices.count
    }
}

// MARK: - Grid Geometry

/// Latitude/longitude grid lines
final class GridGeometry: @unchecked Sendable {
    private(set) var vertexBuffer: MTLBuffer?
    private(set) var vertexCount: Int = 0
    
    private let device: MTLDevice
    
    init(device: MTLDevice) {
        self.device = device
        rebuild()
    }
    
    func rebuild(latSpacing: Int = 15, lonSpacing: Int = 15) {
        var vertices: [LineVertex] = []
        
        let meridianColor = SIMD4<Float>(0.3, 0.3, 0.3, 0.4)
        let parallelColor = SIMD4<Float>(0.4, 0.4, 0.3, 0.4)
        let equatorColor = SIMD4<Float>(0.5, 0.3, 0.3, 0.6)
        let primeMeridianColor = SIMD4<Float>(0.3, 0.5, 0.3, 0.6)
        
        // Parallels (latitude lines)
        for lat in stride(from: -90, through: 90, by: latSpacing) {
            let color = lat == 0 ? equatorColor : parallelColor
            
            for lon in stride(from: -180, through: 180, by: 2) {
                let coord = Coordinate(lat: Double(lat), lon: Double(lon))
                let pos = coord.toCartesian()
                vertices.append(LineVertex(position: pos, color: color))
            }
            vertices.append(LineVertex(position: .zero, color: .zero))  // Break
        }
        
        // Meridians (longitude lines)
        for lon in stride(from: -180, to: 180, by: lonSpacing) {
            let color = lon == 0 ? primeMeridianColor : meridianColor
            
            for lat in stride(from: -90, through: 90, by: 2) {
                let coord = Coordinate(lat: Double(lat), lon: Double(lon))
                let pos = coord.toCartesian()
                vertices.append(LineVertex(position: pos, color: color))
            }
            vertices.append(LineVertex(position: .zero, color: .zero))  // Break
        }
        
        if !vertices.isEmpty {
            vertexBuffer = device.makeBuffer(
                bytes: vertices,
                length: vertices.count * MemoryLayout<LineVertex>.stride,
                options: .storageModeShared
            )
            vertexCount = vertices.count
        }
    }
}

// MARK: - Path Geometry

/// Dynamic line geometry for vector paths
final class PathGeometry: @unchecked Sendable {
    private let device: MTLDevice
    
    private(set) var vertexBuffer: MTLBuffer?
    private(set) var vertexCount: Int = 0
    
    private(set) var selectionBuffer: MTLBuffer?
    private(set) var selectionVertexCount: Int = 0
    
    var tessellationQuality: Int = 8
    
    init(device: MTLDevice) {
        self.device = device
    }
    
    func update(paths: [VectorPath], selection: (layerIndex: Int, pathIndex: Int, path: VectorPath)? = nil) {
        var vertices: [LineVertex] = []
        
        for path in paths {
            let color = path.style.strokeColor.simd
            let coords = path.tessellate(segmentsPerCurve: tessellationQuality)
            
            guard coords.count >= 2 else { continue }
            
            for coord in coords {
                let pos = coord.toCartesian()
                vertices.append(LineVertex(position: pos, color: color))
            }
            
            if path.isClosed, let first = coords.first {
                vertices.append(LineVertex(position: first.toCartesian(), color: color))
            }
            
            vertices.append(LineVertex(position: .zero, color: .zero))  // Break
        }
        
        if !vertices.isEmpty {
            vertexBuffer = device.makeBuffer(
                bytes: vertices,
                length: vertices.count * MemoryLayout<LineVertex>.stride,
                options: .storageModeShared
            )
            vertexCount = vertices.count
        } else {
            vertexBuffer = nil
            vertexCount = 0
        }
        
        // Selection highlight
        if let sel = selection {
            var selVerts: [LineVertex] = []
            let highlightColor = SIMD4<Float>(1.0, 0.9, 0.3, 1.0)
            let coords = sel.path.tessellate(segmentsPerCurve: tessellationQuality)
            
            for coord in coords {
                selVerts.append(LineVertex(position: coord.toCartesian(), color: highlightColor))
            }
            
            if sel.path.isClosed, let first = coords.first {
                selVerts.append(LineVertex(position: first.toCartesian(), color: highlightColor))
            }
            
            if !selVerts.isEmpty {
                selectionBuffer = device.makeBuffer(
                    bytes: selVerts,
                    length: selVerts.count * MemoryLayout<LineVertex>.stride,
                    options: .storageModeShared
                )
                selectionVertexCount = selVerts.count
            } else {
                selectionBuffer = nil
                selectionVertexCount = 0
            }
        } else {
            selectionBuffer = nil
            selectionVertexCount = 0
        }
    }
}

// MARK: - Stroke Geometry

/// Real-time stroke being drawn
final class StrokeGeometry: @unchecked Sendable {
    private let device: MTLDevice
    
    private(set) var vertexBuffer: MTLBuffer?
    private(set) var vertexCount: Int = 0
    
    init(device: MTLDevice) {
        self.device = device
    }
    
    func update(points: [Coordinate]) {
        guard points.count >= 2 else {
            vertexBuffer = nil
            vertexCount = 0
            return
        }
        
        let color = SIMD4<Float>(1.0, 1.0, 1.0, 1.0)
        var vertices: [LineVertex] = []
        
        for coord in points {
            vertices.append(LineVertex(position: coord.toCartesian(), color: color))
        }
        
        vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: vertices.count * MemoryLayout<LineVertex>.stride,
            options: .storageModeShared
        )
        vertexCount = vertices.count
    }
}

// MARK: - Eraser Geometry

/// Visual indicator for eraser tool
final class EraserGeometry: @unchecked Sendable {
    private let device: MTLDevice
    
    private(set) var vertexBuffer: MTLBuffer?
    private(set) var vertexCount: Int = 0
    
    init(device: MTLDevice) {
        self.device = device
    }
    
    func update(center: Coordinate, radiusDegrees: Double) {
        var vertices: [LineVertex] = []
        let segments = 32
        
        for i in 0...segments {
            let angle = Double(i) / Double(segments) * 2.0 * .pi
            let lat = center.lat + radiusDegrees * sin(angle)
            let lon = center.lon + radiusDegrees * cos(angle) / cos(center.lat * .pi / 180.0)
            
            let coord = Coordinate(lat: lat, lon: lon)
            let pos = coord.toCartesian()
            // Store angle in color for shader effect
            let color = SIMD4<Float>(Float(cos(angle)), Float(sin(angle)), 0, 1)
            vertices.append(LineVertex(position: pos, color: color))
        }
        
        if !vertices.isEmpty {
            vertexBuffer = device.makeBuffer(
                bytes: vertices,
                length: vertices.count * MemoryLayout<LineVertex>.stride,
                options: .storageModeShared
            )
            vertexCount = vertices.count
        }
    }
    
    func clear() {
        vertexBuffer = nil
        vertexCount = 0
    }
}
