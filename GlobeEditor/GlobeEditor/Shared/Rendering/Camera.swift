import Foundation
import simd
import Combine

// MARK: - Camera

/// Terrain-style camera orbiting a sphere (Z-up, stable horizon)
@MainActor
final class Camera: ObservableObject {
    
    // MARK: Published State
    
    @Published private(set) var position: SIMD3<Float> = .zero
    @Published private(set) var zoomLevel: Float = 5.0
    
    // MARK: Configuration
    
    /// Latitude of camera look-at point (-90 to 90)
    var latitude: Float = 20.0 {
        didSet { latitude = latitude.clamped(to: -89.5...89.5) }
    }
    
    /// Longitude of camera look-at point (-180 to 180)
    var longitude: Float = 0.0 {
        didSet { longitude = longitude.wrapped(to: -180..<180) }
    }
    
    /// Distance from globe center
    var distance: Float = 3.0 {
        didSet { distance = distance.clamped(to: 1.5...10.0) }
    }
    
    /// Aspect ratio (width / height)
    var aspectRatio: Float = 1.0
    
    // MARK: Zoom Levels
    
    /// Zoom level affects label visibility thresholds
    /// 0 = far (whole globe), 10 = close (regional detail)
    var computedZoomLevel: Float {
        // Map distance to zoom level
        let normalized = (10.0 - distance) / 8.5  // 1.5...10 → 1...0
        return (normalized * 10.0).clamped(to: 0...10)
    }
    
    // MARK: Matrices
    
    var viewMatrix: float4x4 {
        updatePosition()
        let target = SIMD3<Float>(0, 0, 0)
        
        // Stable up vector (Z-up world)
        var up = SIMD3<Float>(0, 0, 1)
        
        // Near poles, adjust up vector to prevent gimbal lock
        if abs(latitude) > 85 {
            let sign: Float = latitude > 0 ? -1 : 1
            up = SIMD3<Float>(cos(longitude * .pi / 180) * sign,
                              sin(longitude * .pi / 180) * sign,
                              0)
        }
        
        return float4x4.lookAt(eye: position, center: target, up: up)
    }
    
    var projectionMatrix: float4x4 {
        float4x4.perspective(
            fovyRadians: 45.0 * .pi / 180.0,
            aspect: aspectRatio,
            nearZ: 0.1,
            farZ: 100.0
        )
    }
    
    // MARK: Navigation
    
    func rotate(deltaLon: Float, deltaLat: Float) {
        // Reduce sensitivity at high zoom
        let sensitivity = 1.0 / (computedZoomLevel * 0.1 + 1.0)
        longitude += deltaLon * sensitivity
        latitude += deltaLat * sensitivity
        updatePosition()
    }
    
    func zoom(delta: Float) {
        distance += delta
        zoomLevel = computedZoomLevel
        updatePosition()
    }
    
    func setZoom(level: Float) {
        // Convert zoom level (0-10) to distance (10-1.5)
        let normalized = level / 10.0
        distance = 10.0 - normalized * 8.5
        zoomLevel = computedZoomLevel
        updatePosition()
    }
    
    /// Look at a specific coordinate
    func lookAt(_ coordinate: Coordinate) {
        latitude = Float(coordinate.lat)
        longitude = Float(coordinate.lon)
        updatePosition()
    }
    
    // MARK: Private
    
    private func updatePosition() {
        let latRad = latitude * .pi / 180.0
        let lonRad = longitude * .pi / 180.0
        
        // Position camera above the point we're looking at
        // Offset by 45° to look down at an angle
        let cameraLatOffset: Float = 30.0 * .pi / 180.0
        let effectiveLat = latRad + cameraLatOffset
        
        position = SIMD3<Float>(
            distance * cos(effectiveLat) * cos(lonRad),
            distance * cos(effectiveLat) * sin(lonRad),
            distance * sin(effectiveLat)
        )
        
        zoomLevel = computedZoomLevel
    }
}

// MARK: - Matrix Extensions

extension float4x4 {
    
    static var identity: float4x4 {
        float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
    }
    
    static func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> float4x4 {
        let z = normalize(eye - center)
        let x = normalize(cross(up, z))
        let y = cross(z, x)
        
        return float4x4(
            SIMD4<Float>(x.x, y.x, z.x, 0),
            SIMD4<Float>(x.y, y.y, z.y, 0),
            SIMD4<Float>(x.z, y.z, z.z, 0),
            SIMD4<Float>(-dot(x, eye), -dot(y, eye), -dot(z, eye), 1)
        )
    }
    
    static func perspective(fovyRadians: Float, aspect: Float, nearZ: Float, farZ: Float) -> float4x4 {
        let y = 1 / tan(fovyRadians * 0.5)
        let x = y / aspect
        let z = farZ / (nearZ - farZ)
        
        return float4x4(
            SIMD4<Float>(x, 0, 0, 0),
            SIMD4<Float>(0, y, 0, 0),
            SIMD4<Float>(0, 0, z, -1),
            SIMD4<Float>(0, 0, z * nearZ, 0)
        )
    }
    
    var inverse: float4x4 {
        simd_inverse(self)
    }
}

// MARK: - Float Extensions

extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
    
    func wrapped(to range: Range<Float>) -> Float {
        let width = range.upperBound - range.lowerBound
        var value = self
        while value >= range.upperBound { value -= width }
        while value < range.lowerBound { value += width }
        return value
    }
}
