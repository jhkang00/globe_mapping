# Globe Editor

A native SwiftUI + Metal application for drawing vector maps directly on a 3D globe.

**Built with:** Swift 6.2 · Metal 4 · SwiftUI DocumentGroup · Apple Pencil Pro

## Features

### Core
- Metal-rendered 3D globe with lighting and grid overlay
- Terrain-style camera navigation (Z-up, stable horizon)
- Native `.globe` document format with iCloud sync support
- Bézier curve preservation from SVG imports

### Drawing & Editing
- Draw paths directly on the globe surface
- Point eraser that splits paths (preserves coastline integrity)
- Select paths to move, scale, or delete
- Full undo/redo history (50 levels)

### Apple Pencil Pro
- **Squeeze** → Quick tool palette at pencil position
- **Hover** → Eraser preview before touching
- **Haptics** → Feedback on path completion and grid snapping
- **Barrel Roll** → (Future) Brush angle control

### Layer System
- Multiple layers with visibility toggles
- Lock layers to prevent accidental edits
- Per-layer path organization

## Requirements

- **Xcode 16+** with Swift 6.2
- **iOS 26+ / macOS 26+** (requires DocumentGroup APIs)
- **Metal-compatible device** (M1 or later for best performance)
- **Apple Pencil Pro** (optional, for squeeze/hover/haptics)

## Project Setup

### 1. Create Xcode Project

1. Open Xcode → File → New → Project
2. Select **Multiplatform → Document App**
3. Configure:
   - Product Name: `GlobeEditor`
   - Organization Identifier: `com.yourname`
   - Interface: SwiftUI
   - Storage: None (we handle our own)

### 2. Add Source Files

1. Delete the auto-generated `ContentView.swift` and document files
2. Drag all files from `Shared/` into the project
3. Ensure "Copy items if needed" is checked
4. Add to both iOS and macOS targets

### 3. Configure Info.plist

Copy the contents of `Resources/Info.plist` into your project's Info.plist, or merge the UTType declarations:

```xml
<key>UTExportedTypeDeclarations</key>
<array>
    <dict>
        <key>UTTypeIdentifier</key>
        <string>com.globeeditor.globe</string>
        <key>UTTypeDescription</key>
        <string>Globe World Map</string>
        <key>UTTypeConformsTo</key>
        <array>
            <string>public.json</string>
        </array>
        <key>UTTypeTagSpecification</key>
        <dict>
            <key>public.filename-extension</key>
            <array>
                <string>globe</string>
            </array>
        </dict>
    </dict>
</array>
```

### 4. Build & Run

- Select iOS Simulator or My Mac
- Press ⌘R

## File Structure

```
GlobeEditor/
├── Shared/
│   ├── Models/
│   │   ├── GlobeUTType.swift      # UTType for .globe files
│   │   ├── Coordinate.swift       # Spherical coordinates, Bézier
│   │   ├── VectorPath.swift       # Paths, layers, styles
│   │   ├── GlobeDocument.swift    # FileDocument implementation
│   │   └── EditHistory.swift      # Undo/redo system
│   ├── Rendering/
│   │   ├── Shaders.metal          # GPU shaders
│   │   ├── Geometry.swift         # Mesh generation
│   │   ├── Camera.swift           # Navigation
│   │   └── GlobeRenderer.swift    # Metal rendering
│   ├── Input/
│   │   └── PencilInteraction.swift # Apple Pencil Pro
│   ├── Views/
│   │   ├── GlobeView.swift        # Metal view wrapper
│   │   ├── GlobeViewModel.swift   # State management
│   │   └── ContentView.swift      # Main UI
│   └── GlobeEditorApp.swift       # App entry point
├── Resources/
│   └── Info.plist                 # UTType registration
└── Tools/
    └── svg_to_globe.py            # SVG converter
```

## Controls

### iPad (with Apple Pencil Pro)

| Action | Input |
|--------|-------|
| Rotate globe | Drag with finger |
| Zoom | Pinch with two fingers |
| Draw | Draw with Pencil (in Draw mode) |
| Quick palette | Squeeze Pencil |
| Erase | Draw with Pencil (in Erase mode) |
| Select path | Tap path (in Select mode) |
| Move selected | Drag selected path |

### Mac

| Action | Input |
|--------|-------|
| Rotate globe | Click + drag |
| Zoom | Scroll wheel |
| Draw | Click + drag (in Draw mode) |
| Delete selected | Delete key |
| Undo | ⌘Z |
| Redo | ⌘⇧Z |

## File Format (.globe)

JSON document with compact coordinate encoding:

```json
{
  "formatVersion": "2.0",
  "meta": {
    "name": "My World",
    "created": "2025-12-13T...",
    "modified": "2025-12-13T..."
  },
  "layers": [{
    "id": "...",
    "name": "Coastlines",
    "isVisible": true,
    "isLocked": false,
    "paths": [{
      "id": "...",
      "pathType": "cubic",
      "cubicSegments": [
        [[34.05, -118.24], [34.08, -118.22], [34.11, -118.22], [34.14, -118.24]]
      ],
      "isClosed": false,
      "style": {
        "strokeColor": {"r": 0.9, "g": 0.9, "b": 0.9, "a": 1.0},
        "strokeWidth": 1.5
      }
    }]
  }]
}
```

### Coordinate Format
- `[lat, lon]` arrays with 4 decimal places (~11m precision)
- Bézier segments: `[start, control1, control2, end]`

## Converting SVG Maps

```bash
python Tools/svg_to_globe.py \
    --inner InnerWorld.svg \
    --outer OuterWorld.svg \
    --name "Suric Ocean" \
    -o suric.globe
```

The converter:
- Preserves cubic Bézier curves
- Handles M, C, c, L, l, Z commands
- Applies hemisphere coordinate shifts
- Outputs compact JSON

## Architecture Notes

### Swift 6.2 Concurrency
- `@MainActor` isolation for all UI-related classes
- `Sendable` conformance for data models
- Explicit `Task { @MainActor in }` for cross-isolation calls

### Metal Rendering
- 60fps on M-series chips
- Separate pipelines for sphere, grid, paths, selection, stroke, eraser
- Z-fighting prevented via surface offsets
- Selection uses animated pulsing shader

### Document System
- `FileDocument` protocol for SwiftUI integration
- Automatic iCloud sync via `NSUbiquitousContainers`
- Native file browser on both platforms

## Future Phases

### Phase 2: Terrain
- Region polygons with terrain types
- Fill colors/textures
- Elevation data support

### Phase 3: Labels
- Text placement at coordinates
- Zoom-dependent visibility
- Curved text for large features

### Phase 4: AI Features (M5+)
- Intelligent coastline suggestions
- Automatic terrain fills
- Style transfer for map aesthetics

## License

MIT
