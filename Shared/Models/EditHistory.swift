import Foundation

// MARK: - Edit Action

/// An atomic edit action that can be undone/redone
enum EditAction: Sendable {
    case addPath(layerIndex: Int, path: VectorPath)
    case deletePath(layerIndex: Int, pathIndex: Int, path: VectorPath)
    case modifyPath(layerIndex: Int, pathIndex: Int, oldPath: VectorPath, newPath: VectorPath)
    case splitPath(layerIndex: Int, pathIndex: Int, original: VectorPath, results: [VectorPath])
    case addLayer(layer: VectorLayer)
    case deleteLayer(index: Int, layer: VectorLayer)
    
    /// Human-readable description for UI
    var description: String {
        switch self {
        case .addPath: return "Add Path"
        case .deletePath: return "Delete Path"
        case .modifyPath: return "Modify Path"
        case .splitPath: return "Split Path"
        case .addLayer: return "Add Layer"
        case .deleteLayer: return "Delete Layer"
        }
    }
}

// MARK: - Edit History

/// Manages undo/redo stack with configurable depth
@MainActor
final class EditHistory: ObservableObject {
    
    @Published private(set) var canUndo: Bool = false
    @Published private(set) var canRedo: Bool = false
    @Published private(set) var undoActionName: String?
    @Published private(set) var redoActionName: String?
    
    private var undoStack: [EditAction] = []
    private var redoStack: [EditAction] = []
    private let maxDepth: Int
    
    init(maxDepth: Int = 50) {
        self.maxDepth = maxDepth
    }
    
    // MARK: Recording
    
    func record(_ action: EditAction) {
        undoStack.append(action)
        redoStack.removeAll()
        
        if undoStack.count > maxDepth {
            undoStack.removeFirst()
        }
        
        updateState()
    }
    
    // MARK: Undo/Redo
    
    func popUndo() -> EditAction? {
        guard let action = undoStack.popLast() else { return nil }
        redoStack.append(action)
        updateState()
        return action
    }
    
    func popRedo() -> EditAction? {
        guard let action = redoStack.popLast() else { return nil }
        undoStack.append(action)
        updateState()
        return action
    }
    
    // MARK: State Management
    
    func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
        updateState()
    }
    
    private func updateState() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        undoActionName = undoStack.last?.description
        redoActionName = redoStack.last?.description
    }
}

// MARK: - Document + Undo Application

extension GlobeDocument {
    
    /// Apply an edit action (for redo)
    mutating func apply(_ action: EditAction) {
        switch action {
        case .addPath(let layerIndex, let path):
            guard layerIndex < layers.count else { return }
            layers[layerIndex].paths.append(path)
            
        case .deletePath(let layerIndex, let pathIndex, _):
            guard layerIndex < layers.count,
                  pathIndex < layers[layerIndex].paths.count else { return }
            layers[layerIndex].paths.remove(at: pathIndex)
            
        case .modifyPath(let layerIndex, let pathIndex, _, let newPath):
            guard layerIndex < layers.count,
                  pathIndex < layers[layerIndex].paths.count else { return }
            layers[layerIndex].paths[pathIndex] = newPath
            
        case .splitPath(let layerIndex, let pathIndex, _, let results):
            guard layerIndex < layers.count,
                  pathIndex < layers[layerIndex].paths.count else { return }
            layers[layerIndex].paths.remove(at: pathIndex)
            for (i, path) in results.enumerated() {
                layers[layerIndex].paths.insert(path, at: pathIndex + i)
            }
            
        case .addLayer(let layer):
            layers.append(layer)
            
        case .deleteLayer(let index, _):
            guard index < layers.count else { return }
            layers.remove(at: index)
        }
    }
    
    /// Reverse an edit action (for undo)
    mutating func reverse(_ action: EditAction) {
        switch action {
        case .addPath(let layerIndex, _):
            guard layerIndex < layers.count, !layers[layerIndex].paths.isEmpty else { return }
            layers[layerIndex].paths.removeLast()
            
        case .deletePath(let layerIndex, let pathIndex, let path):
            guard layerIndex < layers.count else { return }
            let insertIndex = min(pathIndex, layers[layerIndex].paths.count)
            layers[layerIndex].paths.insert(path, at: insertIndex)
            
        case .modifyPath(let layerIndex, let pathIndex, let oldPath, _):
            guard layerIndex < layers.count,
                  pathIndex < layers[layerIndex].paths.count else { return }
            layers[layerIndex].paths[pathIndex] = oldPath
            
        case .splitPath(let layerIndex, let pathIndex, let original, let results):
            guard layerIndex < layers.count else { return }
            // Remove the split results
            for _ in 0..<results.count {
                if pathIndex < layers[layerIndex].paths.count {
                    layers[layerIndex].paths.remove(at: pathIndex)
                }
            }
            // Restore original
            layers[layerIndex].paths.insert(original, at: pathIndex)
            
        case .addLayer(_):
            guard !layers.isEmpty else { return }
            layers.removeLast()
            
        case .deleteLayer(let index, let layer):
            let insertIndex = min(index, layers.count)
            layers.insert(layer, at: insertIndex)
        }
    }
}
