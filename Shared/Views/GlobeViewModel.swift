import SwiftUI
import Combine

// MARK: - Tool Mode

enum ToolMode: String, CaseIterable, Identifiable {
    case navigate
    case select
    case draw
    case erase
    
    var id: String { rawValue }
    
    var label: String {
        switch self {
        case .navigate: return "Navigate"
        case .select: return "Select"
        case .draw: return "Draw"
        case .erase: return "Erase"
        }
    }
    
    var systemImage: String {
        switch self {
        case .navigate: return "hand.point.up"
        case .select: return "cursorarrow"
        case .draw: return "pencil"
        case .erase: return "eraser"
        }
    }
    
    var activeColor: Color {
        switch self {
        case .navigate: return .blue
        case .select: return .yellow
        case .draw: return .green
        case .erase: return .red
        }
    }
}

// MARK: - Selection State

struct PathSelection: Equatable {
    var layerIndex: Int
    var pathIndex: Int
    var path: VectorPath
}

// MARK: - Globe View Model

@MainActor
final class GlobeViewModel: ObservableObject {
    
    // MARK: Document
    
    @Published var document: GlobeDocument {
        didSet { updateRenderer() }
    }
    
    // MARK: Tool State
    
    @Published var toolMode: ToolMode = .navigate {
        didSet {
            if toolMode != .select { selection = nil }
            if toolMode != .erase { renderer?.eraserPosition = nil }
        }
    }
    
    @Published var selectedLayerIndex: Int = 0
    @Published var selection: PathSelection?
    @Published var isDrawing: Bool = false
    
    // MARK: Eraser
    
    @Published var eraserRadius: Float = 2.0
    
    // MARK: History
    
    let editHistory = EditHistory()
    
    // MARK: Renderer
    
    private(set) var renderer: GlobeRenderer?
    
    // MARK: Pencil
    
    let pencilManager = PencilInteractionManager()
    
    // MARK: UI State
    
    @Published var showToolPalette: Bool = false
    @Published var toolPalettePosition: CGPoint = .zero
    
    // MARK: Transform State (for dragging)
    
    private var dragStartCoordinate: Coordinate?
    private var originalPath: VectorPath?
    
    // MARK: Initialization
    
    init(document: GlobeDocument = GlobeDocument()) {
        self.document = document
        setupPencilCallbacks()
    }
    
    private func setupPencilCallbacks() {
        pencilManager.onSqueeze = { [weak self] action in
            self?.handlePencilSqueeze(action)
        }
    }
    
    func setupRenderer(mtkView: MTKView) {
        renderer = GlobeRenderer(mtkView: mtkView)
        updateRenderer()
    }
    
    // MARK: Renderer Updates
    
    private func updateRenderer() {
        let paths = document.allVisiblePaths
        let sel: (Int, Int, VectorPath)? = selection.map { ($0.layerIndex, $0.pathIndex, $0.path) }
        renderer?.updatePaths(paths, selection: sel)
    }
    
    // MARK: Drawing
    
    func beginStroke(at coordinate: Coordinate) {
        guard toolMode == .draw else { return }
        isDrawing = true
        renderer?.currentStroke = [coordinate]
    }
    
    func continueStroke(to coordinate: Coordinate) {
        guard isDrawing, let renderer = renderer else { return }
        
        if let last = renderer.currentStroke.last {
            let distance = last.distance(to: coordinate)
            if distance > 0.5 {  // Minimum spacing in degrees
                renderer.currentStroke.append(coordinate)
            }
        }
    }
    
    func endStroke() {
        guard isDrawing, let renderer = renderer, renderer.currentStroke.count >= 2 else {
            cancelStroke()
            return
        }
        
        let path = VectorPath(linearPoints: renderer.currentStroke)
        
        guard selectedLayerIndex < document.layers.count else {
            cancelStroke()
            return
        }
        
        document.addPath(path, toLayerAt: selectedLayerIndex)
        editHistory.record(.addPath(layerIndex: selectedLayerIndex, path: path))
        
        pencilManager.pathCompleteFeedback()
        
        isDrawing = false
        renderer.currentStroke = []
        updateRenderer()
    }
    
    func cancelStroke() {
        isDrawing = false
        renderer?.currentStroke = []
    }
    
    // MARK: Selection
    
    func selectPath(at coordinate: Coordinate) {
        let hitRadius: Double = 2.0
        
        for (layerIndex, layer) in document.layers.enumerated() {
            guard layer.isVisible else { continue }
            
            for (pathIndex, path) in layer.paths.enumerated() {
                let tessellated = path.tessellate()
                
                for point in tessellated {
                    if coordinate.distance(to: point) < hitRadius {
                        selection = PathSelection(
                            layerIndex: layerIndex,
                            pathIndex: pathIndex,
                            path: path
                        )
                        updateRenderer()
                        return
                    }
                }
            }
        }
        
        // No hit - clear selection
        selection = nil
        updateRenderer()
    }
    
    func clearSelection() {
        selection = nil
        updateRenderer()
    }
    
    // MARK: Move Selected
    
    func beginMove(at coordinate: Coordinate) {
        guard let sel = selection else { return }
        dragStartCoordinate = coordinate
        originalPath = sel.path
    }
    
    func continueMove(to coordinate: Coordinate) {
        guard let sel = selection,
              let start = dragStartCoordinate,
              let original = originalPath else { return }
        
        let deltaLat = coordinate.lat - start.lat
        let deltaLon = coordinate.lon - start.lon
        
        let moved = original.offset(deltaLat: deltaLat, deltaLon: deltaLon)
        document.layers[sel.layerIndex].paths[sel.pathIndex] = moved
        
        selection = PathSelection(
            layerIndex: sel.layerIndex,
            pathIndex: sel.pathIndex,
            path: moved
        )
        
        updateRenderer()
    }
    
    func endMove() {
        guard let sel = selection,
              let original = originalPath else {
            dragStartCoordinate = nil
            originalPath = nil
            return
        }
        
        let newPath = document.layers[sel.layerIndex].paths[sel.pathIndex]
        
        editHistory.record(.modifyPath(
            layerIndex: sel.layerIndex,
            pathIndex: sel.pathIndex,
            oldPath: original,
            newPath: newPath
        ))
        
        dragStartCoordinate = nil
        originalPath = nil
    }
    
    // MARK: Scale Selected
    
    func scaleSelected(factor: Double) {
        guard let sel = selection else { return }
        
        let original = sel.path
        let scaled = original.scaled(by: factor)
        
        document.layers[sel.layerIndex].paths[sel.pathIndex] = scaled
        
        editHistory.record(.modifyPath(
            layerIndex: sel.layerIndex,
            pathIndex: sel.pathIndex,
            oldPath: original,
            newPath: scaled
        ))
        
        selection = PathSelection(
            layerIndex: sel.layerIndex,
            pathIndex: sel.pathIndex,
            path: scaled
        )
        
        updateRenderer()
    }
    
    // MARK: Delete Selected
    
    func deleteSelected() {
        guard let sel = selection else { return }
        
        document.removePath(at: sel.pathIndex, fromLayerAt: sel.layerIndex)
        editHistory.record(.deletePath(
            layerIndex: sel.layerIndex,
            pathIndex: sel.pathIndex,
            path: sel.path
        ))
        
        selection = nil
        updateRenderer()
    }
    
    // MARK: Eraser
    
    func updateEraserPosition(_ coordinate: Coordinate?) {
        renderer?.eraserPosition = coordinate
    }
    
    func erase(at coordinate: Coordinate) {
        let radius = Double(eraserRadius)
        
        for (layerIndex, layer) in document.layers.enumerated() {
            guard layer.isVisible && !layer.isLocked else { continue }
            
            var pathIndex = 0
            while pathIndex < document.layers[layerIndex].paths.count {
                let path = document.layers[layerIndex].paths[pathIndex]
                
                if let splitResult = splitPath(path, at: coordinate, radius: radius) {
                    let original = document.layers[layerIndex].paths.remove(at: pathIndex)
                    
                    for (i, newPath) in splitResult.enumerated() {
                        document.layers[layerIndex].paths.insert(newPath, at: pathIndex + i)
                    }
                    
                    editHistory.record(.splitPath(
                        layerIndex: layerIndex,
                        pathIndex: pathIndex,
                        original: original,
                        results: splitResult
                    ))
                    
                    if let sel = selection, sel.layerIndex == layerIndex && sel.pathIndex == pathIndex {
                        selection = nil
                    }
                    
                    pathIndex += splitResult.count
                } else {
                    pathIndex += 1
                }
            }
        }
        
        updateRenderer()
    }
    
    private func splitPath(_ path: VectorPath, at point: Coordinate, radius: Double) -> [VectorPath]? {
        let tessellated = path.tessellate()
        
        var eraseIndices = Set<Int>()
        for (i, coord) in tessellated.enumerated() {
            if point.distance(to: coord) < radius {
                eraseIndices.insert(i)
            }
        }
        
        guard !eraseIndices.isEmpty else { return nil }
        
        var segments: [[Coordinate]] = []
        var current: [Coordinate] = []
        
        for (i, coord) in tessellated.enumerated() {
            if eraseIndices.contains(i) {
                if current.count >= 2 {
                    segments.append(current)
                }
                current = []
            } else {
                current.append(coord)
            }
        }
        
        if current.count >= 2 {
            segments.append(current)
        }
        
        return segments.map { points in
            VectorPath(linearPoints: points, isClosed: false, style: path.style, terrain: path.terrain)
        }
    }
    
    // MARK: Undo/Redo
    
    func undo() {
        guard let action = editHistory.popUndo() else { return }
        document.reverse(action)
        selection = nil
        updateRenderer()
    }
    
    func redo() {
        guard let action = editHistory.popRedo() else { return }
        document.apply(action)
        selection = nil
        updateRenderer()
    }
    
    // MARK: Layer Management
    
    func addLayer(name: String) {
        let layer = VectorLayer(name: name)
        document.layers.append(layer)
        editHistory.record(.addLayer(layer: layer))
    }
    
    func toggleLayerVisibility(at index: Int) {
        guard index < document.layers.count else { return }
        document.layers[index].isVisible.toggle()
        updateRenderer()
    }
    
    func deleteLayer(at index: Int) {
        guard index < document.layers.count, document.layers.count > 1 else { return }
        let layer = document.layers.remove(at: index)
        editHistory.record(.deleteLayer(index: index, layer: layer))
        
        if selectedLayerIndex >= document.layers.count {
            selectedLayerIndex = document.layers.count - 1
        }
        
        updateRenderer()
    }
    
    // MARK: Pencil Squeeze Handler
    
    private func handlePencilSqueeze(_ action: PencilSqueezeAction) {
        switch action {
        case .showToolPalette:
            showToolPalette = true
            
        case .toggleDrawMode:
            toolMode = toolMode == .draw ? .navigate : .draw
            
        case .undo:
            undo()
            
        case .switchLayer:
            selectedLayerIndex = (selectedLayerIndex + 1) % document.layers.count
        }
    }
}
