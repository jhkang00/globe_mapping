import SwiftUI
import UniformTypeIdentifiers

// MARK: - Globe Document

/// The main document model conforming to FileDocument for SwiftUI integration
struct GlobeDocument: FileDocument, Equatable, Sendable {
    
    // MARK: FileDocument Requirements
    
    static var readableContentTypes: [UTType] { [.globeDocument, .json] }
    static var writableContentTypes: [UTType] { [.globeDocument] }
    
    // MARK: Document Content
    
    var formatVersion: String = "2.0"
    var meta: Metadata
    var layers: [VectorLayer]
    
    struct Metadata: Codable, Equatable, Sendable {
        var name: String
        var created: Date
        var modified: Date
        var author: String?
        var description: String?
    }
    
    // MARK: Initialization
    
    init(name: String = "Untitled World") {
        self.meta = Metadata(
            name: name,
            created: Date(),
            modified: Date(),
            author: nil,
            description: nil
        )
        self.layers = [
            VectorLayer(name: "Coastlines")
        ]
    }
    
    // MARK: FileDocument Implementation
    
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        let decoded = try decoder.decode(DocumentCodable.self, from: data)
        
        self.formatVersion = decoded.formatVersion
        self.meta = decoded.meta
        self.layers = decoded.layers
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        var doc = self
        doc.meta.modified = Date()
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]  // Consistent output, compact
        
        let codable = DocumentCodable(
            formatVersion: doc.formatVersion,
            meta: doc.meta,
            layers: doc.layers
        )
        
        let data = try encoder.encode(codable)
        return FileWrapper(regularFileWithContents: data)
    }
    
    // MARK: Layer Management
    
    var allVisiblePaths: [VectorPath] {
        layers.filter(\.isVisible).flatMap(\.paths)
    }
    
    mutating func addPath(_ path: VectorPath, toLayerAt index: Int) {
        guard index >= 0 && index < layers.count else { return }
        layers[index].paths.append(path)
    }
    
    mutating func removePath(at pathIndex: Int, fromLayerAt layerIndex: Int) {
        guard layerIndex >= 0 && layerIndex < layers.count,
              pathIndex >= 0 && pathIndex < layers[layerIndex].paths.count else { return }
        layers[layerIndex].paths.remove(at: pathIndex)
    }
    
    mutating func addLayer(name: String) {
        layers.append(VectorLayer(name: name))
    }
    
    // MARK: Statistics
    
    var totalPaths: Int {
        layers.reduce(0) { $0 + $1.paths.count }
    }
    
    var totalSegments: Int {
        layers.flatMap(\.paths).reduce(0) { count, path in
            switch path.pathType {
            case .cubic: return count + (path.cubicSegments?.count ?? 0)
            case .linear: return count + max(0, (path.linearPoints?.count ?? 0) - 1)
            }
        }
    }
}

// MARK: - Codable Helper

/// Internal codable representation (keeps FileDocument conformance clean)
private struct DocumentCodable: Codable {
    var formatVersion: String
    var meta: GlobeDocument.Metadata
    var layers: [VectorLayer]
}
