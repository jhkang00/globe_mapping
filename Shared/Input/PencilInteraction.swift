import SwiftUI

#if os(iOS)
import UIKit

// MARK: - Pencil Squeeze Action

/// Actions triggered by Apple Pencil Pro squeeze gesture
enum PencilSqueezeAction: String, CaseIterable {
    case showToolPalette
    case toggleDrawMode
    case undo
    case switchLayer
    
    var label: String {
        switch self {
        case .showToolPalette: return "Show Tool Palette"
        case .toggleDrawMode: return "Toggle Draw Mode"
        case .undo: return "Undo"
        case .switchLayer: return "Switch Layer"
        }
    }
    
    var systemImage: String {
        switch self {
        case .showToolPalette: return "square.grid.2x2"
        case .toggleDrawMode: return "pencil.tip.crop.circle"
        case .undo: return "arrow.uturn.backward"
        case .switchLayer: return "square.3.layers.3d"
        }
    }
}

// MARK: - Pencil Interaction Manager

/// Manages Apple Pencil Pro interactions
@MainActor
final class PencilInteractionManager: ObservableObject {
    
    // MARK: Published State
    
    @Published var isHovering: Bool = false
    @Published var hoverLocation: CGPoint = .zero
    @Published var hoverAltitude: Double = 0  // 0 = touching, 1 = max distance
    @Published var rollAngle: Double = 0  // Barrel roll in radians
    @Published var isPencilConnected: Bool = false
    
    /// Configured squeeze action
    @Published var squeezeAction: PencilSqueezeAction = .showToolPalette
    
    // MARK: Callbacks
    
    var onSqueeze: ((PencilSqueezeAction) -> Void)?
    var onHover: ((CGPoint, Double, Double) -> Void)?  // location, altitude, roll
    
    // MARK: Haptic Feedback
    
    private var feedbackGenerator: Any?  // UICanvasFeedbackGenerator on iOS 18+
    
    init() {
        setupFeedbackGenerator()
    }
    
    private func setupFeedbackGenerator() {
        if #available(iOS 17.5, *) {
            // UICanvasFeedbackGenerator available from iOS 17.5
            feedbackGenerator = UIImpactFeedbackGenerator(style: .light)
        }
    }
    
    // MARK: Haptic Feedback
    
    /// Provide alignment haptic (snap to grid/guide)
    func alignmentFeedback() {
        if #available(iOS 17.5, *) {
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.prepare()
            generator.impactOccurred()
        }
    }
    
    /// Provide path completion haptic
    func pathCompleteFeedback() {
        if #available(iOS 17.5, *) {
            let generator = UINotificationFeedbackGenerator()
            generator.prepare()
            generator.notificationOccurred(.success)
        }
    }
    
    /// Provide error haptic (can't perform action)
    func errorFeedback() {
        if #available(iOS 17.5, *) {
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.error)
        }
    }
}

// MARK: - Pencil Squeeze View Modifier

/// SwiftUI view modifier for handling pencil squeeze
struct PencilSqueezeModifier: ViewModifier {
    let manager: PencilInteractionManager
    let action: @MainActor (PencilSqueezeAction) -> Void
    
    func body(content: Content) -> some View {
        if #available(iOS 17.5, *) {
            content
                .onPencilSqueeze { phase in
                    if case .ended(_) = phase {
                        Task { @MainActor in
                            action(manager.squeezeAction)
                        }
                    }
                }
        } else {
            content
        }
    }
}

// MARK: - Pencil Hover Handler

/// UIKit view that tracks pencil hover
class PencilHoverView: UIView {
    var onHover: ((CGPoint, CGFloat, CGFloat) -> Void)?
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupHoverGesture()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupHoverGesture()
    }
    
    private func setupHoverGesture() {
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        addGestureRecognizer(hover)
    }
    
    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        let location = recognizer.location(in: self)
        
        var altitude: CGFloat = 0
        var roll: CGFloat = 0
        
        if #available(iOS 16.1, *) {
            altitude = recognizer.zOffset
        }
        
        // Roll angle requires Apple Pencil Pro
        if #available(iOS 17.5, *) {
            // rollAngle available on Apple Pencil Pro
            // Note: This requires runtime check for pencil type
        }
        
        switch recognizer.state {
        case .began, .changed:
            onHover?(location, altitude, roll)
        case .ended, .cancelled:
            onHover?(.zero, 1.0, 0)  // Signal hover ended
        default:
            break
        }
    }
}

// MARK: - SwiftUI Wrapper

struct PencilHoverWrapper: UIViewRepresentable {
    let onHover: (CGPoint, CGFloat, CGFloat) -> Void
    
    func makeUIView(context: Context) -> PencilHoverView {
        let view = PencilHoverView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true
        view.onHover = onHover
        return view
    }
    
    func updateUIView(_ uiView: PencilHoverView, context: Context) {
        uiView.onHover = onHover
    }
}

#else

// MARK: - macOS Stubs

enum PencilSqueezeAction: String, CaseIterable {
    case showToolPalette
    case toggleDrawMode
    case undo
    case switchLayer
    
    var label: String { rawValue }
    var systemImage: String { "pencil" }
}

@MainActor
final class PencilInteractionManager: ObservableObject {
    @Published var isHovering: Bool = false
    @Published var hoverLocation: CGPoint = .zero
    @Published var hoverAltitude: Double = 0
    @Published var rollAngle: Double = 0
    @Published var isPencilConnected: Bool = false
    @Published var squeezeAction: PencilSqueezeAction = .showToolPalette
    
    var onSqueeze: ((PencilSqueezeAction) -> Void)?
    var onHover: ((CGPoint, Double, Double) -> Void)?
    
    func alignmentFeedback() {}
    func pathCompleteFeedback() {}
    func errorFeedback() {}
}

struct PencilSqueezeModifier: ViewModifier {
    let manager: PencilInteractionManager
    let action: @MainActor (PencilSqueezeAction) -> Void
    
    func body(content: Content) -> some View {
        content
    }
}

#endif

// MARK: - View Extension

extension View {
    func onPencilSqueeze(
        manager: PencilInteractionManager,
        action: @escaping @MainActor (PencilSqueezeAction) -> Void
    ) -> some View {
        modifier(PencilSqueezeModifier(manager: manager, action: action))
    }
}
