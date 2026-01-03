import Foundation
import SwiftUI

// MARK: - Path Style

/// Visual style for a vector path
struct PathStyle: Codable, Equatable, Sendable {
    var strokeColor: CodableColor
    var strokeWidth: Float
    var fillColor: CodableColor?
    
    static let `default` = PathStyle(
        strokeColor: CodableColor(r: 0.9, g: 0.9, b: 0.9, a: 1.0),
        strokeWidth: 1.5,
        fillColor: nil
    )
    
    static let coastline = PathStyle(
        strokeColor: CodableColor(r: 0.8, g: 0.85, b: 0.9, a: 1.0),
        strokeWidth: 1.5,
        fillColor: nil
    )
    
    static let border = PathStyle(
        strokeColor: CodableColor(r: 0.6, g: 0.6, b: 0.6, a: 1.0),
        strokeWidth: 1.0,
        fillColor: nil
    )
}

/// RGBA color that survives JSON encoding
struct CodableColor: Codable, Equatable, Sendable {
    var r: Float
    var g: Float
    var b: Float
    var a: Float
    
    var simd: SIMD4<Float> { SIMD4(r, g, b, a) }
    
    var swiftUI: Color {
        Color(red: Double(r), green: Double(g), blue: Double(b), opacity: Double(a))
    }
    
    init(r: Float, g: Float, b: Float, a: Float = 1.0) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }
    
    init(_ color: Color) {
        // Default fallback - proper extraction requires UIColor/NSColor
        self.r = 0.5
        self.g = 0.5
        self.b = 0.5
        self.a = 1.0
    }
}

// MARK: - Terrain Type (Future)

/// Terrain classification for regions
enum TerrainType: String, Codable, CaseIterable, Sendable {
    case ocean
    case land
    case forest
    case desert
    case mountain
    case ice
    case lake
    case river
    
    var defaultColor: CodableColor {
        switch self {
        case .ocean: return CodableColor(r: 0.2, g: 0.4, b: 0.7)
        case .land: return CodableColor(r: 0.6, g: 0.7, b: 0.5)
        case .forest: return CodableColor(r: 0.2, g: 0.5, b: 0.3)
        case .desert: return CodableColor(r: 0.85, g: 0.75, b: 0.5)
        case .mountain: return CodableColor(r: 0.5, g: 0.45, b: 0.4)
        case .ice: return CodableColor(r: 0.9, g: 0.95, b: 1.0)
        case .lake: return CodableColor(r: 0.3, g: 0.5, b: 0.8)
        case .river: return CodableColor(r: 0.25, g: 0.45, b: 0.75)
        }
    }
}

// MARK: - Vector Path

/// A path on the globe - either linear points or Bézier curves
struct VectorPath: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var pathType: PathType
    var cubicSegments: [CubicSegment]?
    var linearPoints: [Coordinate]?
    var isClosed: Bool
    var style: PathStyle
    var terrain: TerrainType?
    
    enum PathType: String, Codable, Sendable {
        case linear
        case cubic
    }
    
    // MARK: Initializers
    
    /// Create a cubic Bézier path (for imported SVG)
    init(id: UUID = UUID(), cubicSegments: [CubicSegment], isClosed: Bool = false, 
         style: PathStyle = .default, terrain: TerrainType? = nil) {
        self.id = id
        self.pathType = .cubic
        self.cubicSegments = cubicSegments
        self.linearPoints = nil
        self.isClosed = isClosed
        self.style = style
        self.terrain = terrain
    }
    
    /// Create a linear path (for hand-drawn strokes)
    init(id: UUID = UUID(), linearPoints: [Coordinate], isClosed: Bool = false, 
         style: PathStyle = .default, terrain: TerrainType? = nil) {
        self.id = id
        self.pathType = .linear
        self.cubicSegments = nil
        self.linearPoints = linearPoints
        self.isClosed = isClosed
        self.style = style
        self.terrain = terrain
    }
    
    // MARK: Tessellation
    
    /// Convert to linear points for rendering
    func tessellate(segmentsPerCurve: Int = 8) -> [Coordinate] {
        switch pathType {
        case .linear:
            return linearPoints ?? []
            
        case .cubic:
            guard let segments = cubicSegments, !segments.isEmpty else { return [] }
            var points: [Coordinate] = []
            for (i, segment) in segments.enumerated() {
                let segmentPoints = segment.tessellate(segments: segmentsPerCurve)
                if i == 0 {
                    points.append(contentsOf: segmentPoints)
                } else {
                    points.append(contentsOf: segmentPoints.dropFirst())
                }
            }
            return points
        }
    }
    
    /// Bounding box in lat/lon
    var bounds: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)? {
        let coords = tessellate()
        guard let first = coords.first else { return nil }
        
        var minLat = first.lat, maxLat = first.lat
        var minLon = first.lon, maxLon = first.lon
        
        for coord in coords.dropFirst() {
            minLat = min(minLat, coord.lat)
            maxLat = max(maxLat, coord.lat)
            minLon = min(minLon, coord.lon)
            maxLon = max(maxLon, coord.lon)
        }
        
        return (minLat, maxLat, minLon, maxLon)
    }
    
    // MARK: Transformations
    
    /// Offset all points by delta
    func offset(deltaLat: Double, deltaLon: Double) -> VectorPath {
        var copy = self
        
        switch pathType {
        case .linear:
            copy.linearPoints = linearPoints?.map {
                Coordinate(lat: $0.lat + deltaLat, lon: $0.lon + deltaLon)
            }
        case .cubic:
            copy.cubicSegments = cubicSegments?.map { seg in
                CubicSegment(
                    start: Coordinate(lat: seg.start.lat + deltaLat, lon: seg.start.lon + deltaLon),
                    control1: Coordinate(lat: seg.control1.lat + deltaLat, lon: seg.control1.lon + deltaLon),
                    control2: Coordinate(lat: seg.control2.lat + deltaLat, lon: seg.control2.lon + deltaLon),
                    end: Coordinate(lat: seg.end.lat + deltaLat, lon: seg.end.lon + deltaLon)
                )
            }
        }
        
        return copy
    }
    
    /// Scale from center
    func scaled(by factor: Double) -> VectorPath {
        guard let bounds = bounds else { return self }
        let centerLat = (bounds.minLat + bounds.maxLat) / 2
        let centerLon = (bounds.minLon + bounds.maxLon) / 2
        
        func scale(_ coord: Coordinate) -> Coordinate {
            Coordinate(
                lat: centerLat + (coord.lat - centerLat) * factor,
                lon: centerLon + (coord.lon - centerLon) * factor
            )
        }
        
        var copy = self
        
        switch pathType {
        case .linear:
            copy.linearPoints = linearPoints?.map(scale)
        case .cubic:
            copy.cubicSegments = cubicSegments?.map { seg in
                CubicSegment(
                    start: scale(seg.start),
                    control1: scale(seg.control1),
                    control2: scale(seg.control2),
                    end: scale(seg.end)
                )
            }
        }
        
        return copy
    }
}

// MARK: - Vector Layer

/// A layer containing vector features
struct VectorLayer: Identifiable, Codable, Sendable {
    let id: UUID
    var name: String
    var isVisible: Bool
    var isLocked: Bool
    var paths: [VectorPath]

    init(id: UUID = UUID(), name: String, paths: [VectorPath] = []) {
        self.id = id
        self.name = name
        self.isVisible = true
        self.isLocked = false
        self.paths = paths
    }

    // Explicit nonisolated Equatable conformance for Swift 6 compatibility
    nonisolated static func == (lhs: VectorLayer, rhs: VectorLayer) -> Bool {
        lhs.id == rhs.id &&
        lhs.name == rhs.name &&
        lhs.isVisible == rhs.isVisible &&
        lhs.isLocked == rhs.isLocked &&
        lhs.paths == rhs.paths
    }
}

extension VectorLayer: Equatable {}
