import SwiftUI

/// A passive window keeps the reference's frame stable while keyboards and sheets move.
struct ScreenEdgeOverlay: UIViewRepresentable {
    var color: Color
    var onCornerRadius: (CGFloat) -> Void
    func makeUIView(context: Context) -> EdgeAnchor { EdgeAnchor() }
    func updateUIView(_ view: EdgeAnchor, context: Context) { view.update(color: UIColor(color), onCornerRadius: onCornerRadius) }
    static func dismantleUIView(_ view: EdgeAnchor, coordinator: ()) { view.removeFrame() }
}

final class PassiveWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

final class EdgeAnchor: UIView {
    private var frameWindow: PassiveWindow?
    private var color = UIColor.systemBlue
    private var onCornerRadius: ((CGFloat) -> Void)?
    override func didMoveToWindow() { super.didMoveToWindow(); installFrame() }
    func update(color: UIColor, onCornerRadius: @escaping (CGFloat) -> Void) {
        self.color = color
        self.onCornerRadius = onCornerRadius
        installFrame()
        (frameWindow?.rootViewController?.view as? EdgeDrawing)?.frameColor = color
    }
    private func installFrame() {
        guard frameWindow == nil, let scene = window?.windowScene else { return }
        let overlay = PassiveWindow(windowScene: scene)
        overlay.windowLevel = .alert + 1
        overlay.backgroundColor = .clear
        let controller = UIViewController()
        let drawing = EdgeDrawing()
        drawing.onCornerRadius = { [weak self] radius in self?.onCornerRadius?(radius) }
        drawing.frameColor = color
        drawing.backgroundColor = .clear
        drawing.isUserInteractionEnabled = false
        drawing.accessibilityElementsHidden = true
        controller.view = drawing
        overlay.rootViewController = controller
        overlay.isUserInteractionEnabled = false
        overlay.isHidden = false
        frameWindow = overlay
    }
    func removeFrame() { frameWindow?.isHidden = true; frameWindow = nil }
}

final class EdgeDrawing: UIView {
    var frameColor = UIColor.systemBlue { didSet { updateColor() } }
    var onCornerRadius: ((CGFloat) -> Void)?
    private var reportedRadius: CGFloat = 0
    override init(frame: CGRect) {
        super.init(frame: frame)
        // iOS resolves the physical display curve, including future phone models.
        cornerConfiguration = .uniformCorners(radius: .containerConcentric())
        layer.cornerCurve = .continuous
        layer.borderWidth = 4
        layer.shadowOffset = .zero
        layer.shadowRadius = 6.5
        layer.shadowOpacity = 0.65
        updateColor()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        let radius = effectiveRadius(corner: .allCorners)
        if radius > 0 && abs(radius - reportedRadius) > 0.1 {
            reportedRadius = radius
            DispatchQueue.main.async { [weak self] in self?.onCornerRadius?(radius) }
        }
    }
    private func updateColor() {
        layer.borderColor = frameColor.cgColor
        layer.shadowColor = frameColor.cgColor
    }
}
