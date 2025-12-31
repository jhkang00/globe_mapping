import SwiftUI

// MARK: - Content View

struct ContentView: View {
    @Binding var document: GlobeDocument
    @StateObject private var viewModel: GlobeViewModel
    
    @State private var showLayerPanel = false
    @State private var showSaveConfirmation = false
    
    init(document: Binding<GlobeDocument>) {
        self._document = document
        self._viewModel = StateObject(wrappedValue: GlobeViewModel(document: document.wrappedValue))
    }
    
    var body: some View {
        ZStack {
            // Globe
            GlobeView(viewModel: viewModel)
                .ignoresSafeArea()
                .onPencilSqueeze(manager: viewModel.pencilManager) { action in
                    handlePencilSqueeze(action)
                }
            
            // Selection controls
            if viewModel.selection != nil {
                selectionOverlay
            }
            
            // Tool palette (shown on squeeze)
            if viewModel.showToolPalette {
                toolPaletteOverlay
            }
            
            // Main UI
            VStack(spacing: 0) {
                topToolbar
                Spacer()
                bottomToolbar
            }
            .padding()
            
            // Layer panel
            if showLayerPanel {
                layerPanel
            }
        }
        .onChange(of: viewModel.document) { _, newValue in
            document = newValue
        }
        .onChange(of: document) { _, newValue in
            if viewModel.document != newValue {
                viewModel.document = newValue
            }
        }
        #if os(iOS)
        .statusBarHidden()
        #endif
    }
    
    // MARK: - Top Toolbar
    
    private var topToolbar: some View {
        HStack {
            // Document info
            VStack(alignment: .leading, spacing: 2) {
                Text(document.meta.name)
                    .font(.headline)
                    .foregroundStyle(.white)
                
                Text("\(document.totalPaths) paths · \(document.totalSegments) segments")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            }
            
            Spacer()
            
            // Undo/Redo
            HStack(spacing: 12) {
                Button {
                    viewModel.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .foregroundStyle(viewModel.editHistory.canUndo ? .white : .gray)
                }
                .disabled(!viewModel.editHistory.canUndo)
                .keyboardShortcut("z", modifiers: .command)
                
                Button {
                    viewModel.redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                        .foregroundStyle(viewModel.editHistory.canRedo ? .white : .gray)
                }
                .disabled(!viewModel.editHistory.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            .font(.title3)
            
            Spacer()
            
            // Layers button
            Button {
                withAnimation(.spring(response: 0.3)) {
                    showLayerPanel.toggle()
                }
            } label: {
                Image(systemName: "square.3.layers.3d")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
    
    // MARK: - Bottom Toolbar
    
    private var bottomToolbar: some View {
        HStack(spacing: 20) {
            // Tool buttons
            ForEach(ToolMode.allCases) { mode in
                toolButton(mode: mode)
            }
            
            Spacer()
            
            // Mode indicator
            modeIndicator
            
            Spacer()
            
            // Zoom level
            Text(String(format: "%.1f×", viewModel.renderer?.camera.zoomLevel ?? 0))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
                .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
    
    private func toolButton(mode: ToolMode) -> some View {
        Button {
            withAnimation(.spring(response: 0.2)) {
                viewModel.toolMode = mode
            }
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    if viewModel.toolMode == mode {
                        Circle()
                            .fill(mode.activeColor.opacity(0.2))
                            .frame(width: 36, height: 36)
                    }
                    Image(systemName: mode.systemImage)
                        .font(.title2)
                        .foregroundStyle(viewModel.toolMode == mode ? mode.activeColor : .white)
                }
                .frame(width: 40, height: 40)
                
                Text(mode.label)
                    .font(.caption2)
                    .foregroundStyle(viewModel.toolMode == mode ? mode.activeColor : .white.opacity(0.7))
            }
        }
        .buttonStyle(.plain)
    }
    
    private var modeIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(viewModel.toolMode.activeColor)
                .frame(width: 8, height: 8)
            
            Text(viewModel.toolMode.label)
                .font(.caption)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.black.opacity(0.5), in: Capsule())
    }
    
    // MARK: - Selection Overlay
    
    private var selectionOverlay: some View {
        VStack {
            Spacer()
            
            HStack(spacing: 16) {
                // Scale controls
                Button {
                    viewModel.scaleSelected(factor: 0.9)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                        .toolButtonStyle()
                }
                
                Button {
                    viewModel.scaleSelected(factor: 1.1)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                        .toolButtonStyle()
                }
                
                Spacer()
                
                Text("Path Selected")
                    .font(.caption)
                    .foregroundStyle(.white)
                
                Spacer()
                
                // Delete
                Button {
                    viewModel.deleteSelected()
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                        .toolButtonStyle()
                }
                
                // Deselect
                Button {
                    viewModel.clearSelection()
                } label: {
                    Image(systemName: "xmark.circle")
                        .toolButtonStyle()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.blue.opacity(0.3))
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
            .padding(.bottom, 100)
        }
    }
    
    // MARK: - Tool Palette (Pencil Squeeze)
    
    private var toolPaletteOverlay: some View {
        ZStack {
            // Dismiss background
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.spring(response: 0.2)) {
                        viewModel.showToolPalette = false
                    }
                }
            
            // Palette
            VStack(spacing: 12) {
                ForEach(ToolMode.allCases) { mode in
                    Button {
                        withAnimation(.spring(response: 0.2)) {
                            viewModel.toolMode = mode
                            viewModel.showToolPalette = false
                        }
                    } label: {
                        HStack {
                            Image(systemName: mode.systemImage)
                                .frame(width: 24)
                            Text(mode.label)
                            Spacer()
                            if viewModel.toolMode == mode {
                                Image(systemName: "checkmark")
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(viewModel.toolMode == mode ? mode.activeColor.opacity(0.3) : .clear)
                    }
                    .foregroundStyle(.white)
                }
            }
            .frame(width: 200)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .transition(.opacity)
    }
    
    // MARK: - Layer Panel
    
    private var layerPanel: some View {
        HStack {
            Spacer()
            
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    Text("Layers")
                        .font(.headline)
                    
                    Spacer()
                    
                    Button {
                        viewModel.addLayer(name: "Layer \(viewModel.document.layers.count + 1)")
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                .padding()
                
                Divider()
                
                // Layer list
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(Array(viewModel.document.layers.enumerated()), id: \.element.id) { index, layer in
                            layerRow(layer: layer, index: index)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
            }
            .frame(width: 260)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding()
        }
        .transition(.move(edge: .trailing))
    }
    
    private func layerRow(layer: VectorLayer, index: Int) -> some View {
        HStack {
            // Visibility toggle
            Button {
                viewModel.toggleLayerVisibility(at: index)
            } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .foregroundStyle(layer.isVisible ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            
            // Name
            Text(layer.name)
                .lineLimit(1)
            
            Spacer()
            
            // Path count
            Text("\(layer.paths.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            // Selection indicator
            if index == viewModel.selectedLayerIndex {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.blue)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            index == viewModel.selectedLayerIndex
            ? Color.blue.opacity(0.2)
            : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.selectedLayerIndex = index
        }
    }
    
    // MARK: - Pencil Squeeze Handler
    
    private func handlePencilSqueeze(_ action: PencilSqueezeAction) {
        switch action {
        case .showToolPalette:
            withAnimation(.spring(response: 0.2)) {
                viewModel.showToolPalette = true
            }
            
        case .toggleDrawMode:
            withAnimation(.spring(response: 0.2)) {
                viewModel.toolMode = viewModel.toolMode == .draw ? .navigate : .draw
            }
            
        case .undo:
            viewModel.undo()
            
        case .switchLayer:
            viewModel.selectedLayerIndex = (viewModel.selectedLayerIndex + 1) % viewModel.document.layers.count
        }
    }
}

// MARK: - View Extensions

extension View {
    func toolButtonStyle() -> some View {
        self
            .font(.title2)
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
    }
}

// MARK: - Preview

#Preview {
    ContentView(document: .constant(GlobeDocument()))
}
