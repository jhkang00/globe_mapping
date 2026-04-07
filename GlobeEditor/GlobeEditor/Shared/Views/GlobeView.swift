import SwiftUI
import MetalKit

#if os(iOS)
import UIKit

// MARK: - iOS Globe View

struct GlobeView: UIViewRepresentable {
    @ObservedObject var viewModel: GlobeViewModel
    
    func makeUIView(context: Context) -> GlobeMTKView {
        let mtkView = GlobeMTKView(frame: .zero)
        mtkView.viewModel = viewModel
        viewModel.setupRenderer(mtkView: mtkView)
        return mtkView
    }
    
    func updateUIView(_ uiView: GlobeMTKView, context: Context) {
        // Updates handled via viewModel
    }
}

/// Custom MTKView with gesture and pencil handling
class GlobeMTKView: MTKView {
    weak var viewModel: GlobeViewModel?
    
    private var lastPanLocation: CGPoint?
    private var isDragging = false
    private var isPencilDrawing = false
    
    override init(frame frameRect: CGRect, device: MTLDevice? = nil) {
        super.init(frame: frameRect, device: device)
        setupGestures()
    }
    
    required init(coder: NSCoder) {
        super.init(coder: coder)
        setupGestures()
    }
    
    private func setupGestures() {
        // Pan for navigation
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.allowedScrollTypesMask = .all
        addGestureRecognizer(pan)
        
        // Pinch for zoom
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)
        
        // Tap for selection
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
        
        // Hover for pencil preview
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        addGestureRecognizer(hover)
        
        isMultipleTouchEnabled = true
    }
    
    // MARK: Gesture Handlers
    
    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let viewModel = viewModel else { return }

        let location = gesture.location(in: self)

        if viewModel.toolMode == .select {
            if let coord = viewModel.renderer?.hitTest(screenPoint: location, viewSize: bounds.size) {
                viewModel.selectPath(at: coord)
            }
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: self)

        switch gesture.state {
        case .began:
            handleDragBegan(at: location, isPencil: false)

        case .changed:
            handleDragChanged(to: location, isPencil: false)

        case .ended, .cancelled:
            handleDragEnded(isPencil: false)

        default:
            break
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard let viewModel = viewModel,
              viewModel.toolMode == .navigate || viewModel.toolMode == .select || viewModel.toolMode == .terrain else {
            return
        }

        if gesture.state == .changed {
            // Capture before resetting — previously this read happened inside a
            // Task body that ran after `gesture.scale = 1.0`, which made
            // `zoomDelta` always 0 and silently broke pinch-to-zoom on iPad.
            let zoomDelta = Float(1.0 - gesture.scale) * 2.0
            gesture.scale = 1.0
            viewModel.renderer?.camera.zoom(delta: zoomDelta)
        }
    }

    @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
        guard let viewModel = viewModel else { return }

        let location = gesture.location(in: self)

        switch gesture.state {
        case .began, .changed:
            if viewModel.toolMode == .erase {
                if let coord = viewModel.renderer?.hitTest(screenPoint: location, viewSize: bounds.size) {
                    viewModel.updateEraserPosition(coord)
                }
            }

        case .ended, .cancelled:
            viewModel.updateEraserPosition(nil)

        default:
            break
        }
    }
    
    // MARK: Touch Handling (for Apple Pencil)

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard viewModel != nil else {
            super.touchesBegan(touches, with: event)
            return
        }

        for touch in touches {
            if touch.type == .pencil {
                let location = touch.location(in: self)
                let pressure = Float(touch.force / max(touch.maximumPossibleForce, 0.001))
                isPencilDrawing = true
                handleDragBegan(at: location, isPencil: true, pressure: pressure)
                return
            }
        }

        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard viewModel != nil, isPencilDrawing else {
            super.touchesMoved(touches, with: event)
            return
        }

        for touch in touches {
            if touch.type == .pencil {
                let location = touch.location(in: self)
                let pressure = Float(touch.force / max(touch.maximumPossibleForce, 0.001))
                handleDragChanged(to: location, isPencil: true, pressure: pressure)
                return
            }
        }

        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isPencilDrawing else {
            super.touchesEnded(touches, with: event)
            return
        }

        // Order matters: commit the stroke (handleDragEnded → endStroke) before
        // clearing the in-flight flag. Previously this was wrapped in a Task,
        // so isPencilDrawing flipped to false synchronously while the commit
        // ran on the next runloop turn — a latent ordering bug with no current
        // observable symptom (nothing reads the flag from inside the commit
        // path), but a footgun for any future code that does.
        handleDragEnded(isPencil: true)
        isPencilDrawing = false
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if isPencilDrawing {
            handleDragEnded(isPencil: true)
            isPencilDrawing = false
        }

        super.touchesCancelled(touches, with: event)
    }
    
    // MARK: Unified Drag Handling

    @MainActor
    private func handleDragBegan(at location: CGPoint, isPencil: Bool, pressure: Float = 0.5) {
        guard let viewModel = viewModel else { return }

        lastPanLocation = location

        guard let coord = viewModel.renderer?.hitTest(screenPoint: location, viewSize: bounds.size) else {
            return
        }

        switch viewModel.toolMode {
        case .navigate:
            break  // Handled in changed

        case .draw, .terrain:
            isDragging = true
            viewModel.beginStroke(at: coord, pressure: pressure)

        case .erase:
            isDragging = true
            viewModel.erase(at: coord)

        case .select:
            if viewModel.selection != nil {
                isDragging = true
                viewModel.beginMove(at: coord)
            }
        }
    }

    @MainActor
    private func handleDragChanged(to location: CGPoint, isPencil: Bool, pressure: Float = 0.5) {
        guard let viewModel = viewModel else { return }

        switch viewModel.toolMode {
        case .navigate:
            if let lastLocation = lastPanLocation {
                let delta = CGPoint(x: location.x - lastLocation.x, y: location.y - lastLocation.y)
                let sensitivity: Float = 0.3
                viewModel.renderer?.camera.rotate(
                    deltaLon: -Float(delta.x) * sensitivity,
                    deltaLat: Float(delta.y) * sensitivity
                )
            }
            lastPanLocation = location

        case .draw, .terrain:
            if isDragging {
                if let coord = viewModel.renderer?.hitTest(screenPoint: location, viewSize: bounds.size) {
                    viewModel.continueStroke(to: coord, pressure: pressure)
                }
            }

        case .erase:
            if isDragging {
                if let coord = viewModel.renderer?.hitTest(screenPoint: location, viewSize: bounds.size) {
                    viewModel.erase(at: coord)
                    viewModel.updateEraserPosition(coord)
                }
            }

        case .select:
            if isDragging && viewModel.selection != nil {
                if let coord = viewModel.renderer?.hitTest(screenPoint: location, viewSize: bounds.size) {
                    viewModel.continueMove(to: coord)
                }
            } else if let lastLocation = lastPanLocation {
                // Allow navigation when nothing selected
                let delta = CGPoint(x: location.x - lastLocation.x, y: location.y - lastLocation.y)
                let sensitivity: Float = 0.3
                viewModel.renderer?.camera.rotate(
                    deltaLon: -Float(delta.x) * sensitivity,
                    deltaLat: Float(delta.y) * sensitivity
                )
                lastPanLocation = location
            }
        }
    }
    
    @MainActor
    private func handleDragEnded(isPencil: Bool) {
        guard let viewModel = viewModel else { return }

        switch viewModel.toolMode {
        case .navigate:
            break

        case .draw, .terrain:
            if isDragging {
                viewModel.endStroke()
            }

        case .erase:
            viewModel.updateEraserPosition(nil)

        case .select:
            if isDragging {
                viewModel.endMove()
            }
        }

        isDragging = false
        lastPanLocation = nil
    }
}

#else

// MARK: - macOS Globe View

struct GlobeView: NSViewRepresentable {
    @ObservedObject var viewModel: GlobeViewModel
    
    func makeNSView(context: Context) -> GlobeMTKView {
        let mtkView = GlobeMTKView(frame: .zero)
        mtkView.viewModel = viewModel
        
        Task { @MainActor in
            viewModel.setupRenderer(mtkView: mtkView)
        }
        
        return mtkView
    }
    
    func updateNSView(_ nsView: GlobeMTKView, context: Context) {}
}

class GlobeMTKView: MTKView {
    weak var viewModel: GlobeViewModel?
    
    private var lastPanLocation: CGPoint?
    private var isDragging = false
    
    override var acceptsFirstResponder: Bool { true }
    
    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let flipped = CGPoint(x: location.x, y: bounds.height - location.y)
        
        Task { @MainActor in
            handleDragBegan(at: flipped)
        }
    }
    
    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let flipped = CGPoint(x: location.x, y: bounds.height - location.y)
        
        Task { @MainActor in
            handleDragChanged(to: flipped)
        }
    }
    
    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let flipped = CGPoint(x: location.x, y: bounds.height - location.y)
        
        Task { @MainActor in
            // Check for click (selection)
            if let viewModel = viewModel, viewModel.toolMode == .select && !isDragging {
                if let coord = viewModel.renderer?.hitTest(screenPoint: flipped, viewSize: bounds.size) {
                    viewModel.selectPath(at: coord)
                }
            }
            
            handleDragEnded()
        }
    }
    
    override func scrollWheel(with event: NSEvent) {
        guard let viewModel = viewModel,
              viewModel.toolMode == .navigate || viewModel.toolMode == .select else {
            return
        }
        
        Task { @MainActor in
            let zoomDelta = Float(event.deltaY) * 0.1
            viewModel.renderer?.camera.zoom(delta: zoomDelta)
        }
    }
    
    override func keyDown(with event: NSEvent) {
        guard let viewModel = viewModel else {
            super.keyDown(with: event)
            return
        }
        
        Task { @MainActor in
            // Delete key
            if event.keyCode == 51 || event.keyCode == 117 {
                if viewModel.selection != nil {
                    viewModel.deleteSelected()
                }
            }
            // Cmd+Z / Cmd+Shift+Z
            else if event.modifierFlags.contains(.command) && event.keyCode == 6 {
                if event.modifierFlags.contains(.shift) {
                    viewModel.redo()
                } else {
                    viewModel.undo()
                }
            }
            else {
                // Let other keys pass through
            }
        }
    }
    
    @MainActor
    private func handleDragBegan(at location: CGPoint) {
        guard let viewModel = viewModel else { return }

        lastPanLocation = location

        guard let coord = viewModel.renderer?.hitTest(screenPoint: location, viewSize: bounds.size) else {
            return
        }

        switch viewModel.toolMode {
        case .navigate:
            break

        case .draw, .terrain:
            isDragging = true
            viewModel.beginStroke(at: coord)

        case .erase:
            isDragging = true
            viewModel.erase(at: coord)

        case .select:
            if viewModel.selection != nil {
                isDragging = true
                viewModel.beginMove(at: coord)
            }
        }
    }

    @MainActor
    private func handleDragChanged(to location: CGPoint) {
        guard let viewModel = viewModel else { return }

        switch viewModel.toolMode {
        case .navigate:
            if let lastLocation = lastPanLocation {
                let delta = CGPoint(x: location.x - lastLocation.x, y: location.y - lastLocation.y)
                let sensitivity: Float = 0.3
                viewModel.renderer?.camera.rotate(
                    deltaLon: -Float(delta.x) * sensitivity,
                    deltaLat: Float(delta.y) * sensitivity
                )
            }
            lastPanLocation = location

        case .draw, .terrain:
            if isDragging {
                if let coord = viewModel.renderer?.hitTest(screenPoint: location, viewSize: bounds.size) {
                    viewModel.continueStroke(to: coord)
                }
            }

        case .erase:
            if isDragging {
                if let coord = viewModel.renderer?.hitTest(screenPoint: location, viewSize: bounds.size) {
                    viewModel.erase(at: coord)
                }
            }

        case .select:
            if isDragging && viewModel.selection != nil {
                if let coord = viewModel.renderer?.hitTest(screenPoint: location, viewSize: bounds.size) {
                    viewModel.continueMove(to: coord)
                }
            } else if let lastLocation = lastPanLocation {
                let delta = CGPoint(x: location.x - lastLocation.x, y: location.y - lastLocation.y)
                let sensitivity: Float = 0.3
                viewModel.renderer?.camera.rotate(
                    deltaLon: -Float(delta.x) * sensitivity,
                    deltaLat: Float(delta.y) * sensitivity
                )
                lastPanLocation = location
            }
        }
    }

    @MainActor
    private func handleDragEnded() {
        guard let viewModel = viewModel else { return }

        switch viewModel.toolMode {
        case .navigate:
            break

        case .draw, .terrain:
            if isDragging {
                viewModel.endStroke()
            }

        case .erase:
            break

        case .select:
            if isDragging {
                viewModel.endMove()
            }
        }

        isDragging = false
        lastPanLocation = nil
    }
}

#endif
