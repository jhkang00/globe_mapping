import Foundation
import simd

// MARK: - Coordinate

/// A point on the globe in spherical coordinates [lat, lon]
/// Latitude: -90 (south pole) to +90 (north pole)
/// Longitude: -180 to +180 (wraps at antimeridian)
struct Coordinate: Codable, Equatable, Hashable, Sendable {
    var lat: Double
    var lon: Double
    
    init(lat: Double, lon: Double) {
        self.lat = lat.clamped(to: -90...90)
        self.lon = lon.wrapped(to: -180..<180)
    }
    
    /// Convert to 3D Cartesian point on sphere
    func toCartesian(radius: Float = 1.0) -> SIMD3<Float> {
        let latRad = Float(lat) * .pi / 180.0
        let lonRad = Float(lon) * .pi / 180.0
        return SIMD3<Float>(
            radius * cos(latRad) * cos(lonRad),
            radius * cos(latRad) * sin(lonRad),
            radius * sin(latRad)
        )
    }
    
    /// Create from 3D Cartesian point
    static func fromCartesian(_ point: SIMD3<Float>) -> Coordinate {
        let r = length(point)
        guard r > 0.0001 else { return Coordinate(lat: 0, lon: 0) }
        let lat = asin(point.z / r) * 180.0 / .pi
        let lon = atan2(point.y, point.x) * 180.0 / .pi
        return Coordinate(lat: Double(lat), lon: Double(lon))
    }
    
    /// Great circle distance to another coordinate (in degrees)
    func distance(to other: Coordinate) -> Double {
        let lat1 = lat * .pi / 180.0
        let lat2 = other.lat * .pi / 180.0
        let dLon = (other.lon - lon) * .pi / 180.0
        let cosD = sin(lat1) * sin(lat2) + cos(lat1) * cos(lat2) * cos(dLon)
        return acos(min(1.0, max(-1.0, cosD))) * 180.0 / .pi
    }
    
    // Compact JSON encoding: [lat, lon]
    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let lat = try container.decode(Double.self)
        let lon = try container.decode(Double.self)
        self.init(lat: lat, lon: lon)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode((lat * 10000).rounded() / 10000)
        try container.encode((lon * 10000).rounded() / 10000)
    }
}

// MARK: - Cubic Bézier Segment

/// A cubic Bézier curve segment with 4 control points
struct CubicSegment: Codable, Equatable, Sendable {
    var start: Coordinate
    var control1: Coordinate
    var control2: Coordinate
    var end: Coordinate
    
    /// Evaluate point on curve at parameter t ∈ [0, 1]
    func point(at t: Float) -> Coordinate {
        let t2 = t * t
        let t3 = t2 * t
        let mt = 1 - t
        let mt2 = mt * mt
        let mt3 = mt2 * mt
        
        let lat = Double(mt3) * start.lat + Double(3 * mt2 * t) * control1.lat +
                  Double(3 * mt * t2) * control2.lat + Double(t3) * end.lat
        let lon = Double(mt3) * start.lon + Double(3 * mt2 * t) * control1.lon +
                  Double(3 * mt * t2) * control2.lon + Double(t3) * end.lon
        
        return Coordinate(lat: lat, lon: lon)
    }
    
    /// Tessellate curve into linear points
    func tessellate(segments: Int = 8) -> [Coordinate] {
        (0...segments).map { i in
            point(at: Float(i) / Float(segments))
        }
    }
    
    // Compact JSON: [[lat,lon], [lat,lon], [lat,lon], [lat,lon]]
    init(start: Coordinate, control1: Coordinate, control2: Coordinate, end: Coordinate) {
        self.start = start
        self.control1 = control1
        self.control2 = control2
        self.end = end
    }
    
    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        start = try container.decode(Coordinate.self)
        control1 = try container.decode(Coordinate.self)
        control2 = try container.decode(Coordinate.self)
        end = try container.decode(Coordinate.self)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(start)
        try container.encode(control1)
        try container.encode(control2)
        try container.encode(end)
    }
}

// MARK: - Numeric Extensions

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
    
    func wrapped(to range: Range<Double>) -> Double {
        let width = range.upperBound - range.lowerBound
        var value = self
        while value >= range.upperBound { value -= width }
        while value < range.lowerBound { value += width }
        return value
    }
}
