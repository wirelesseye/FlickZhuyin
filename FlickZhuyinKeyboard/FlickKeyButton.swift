import UIKit

final class FlickKeyButton: KeyboardButton {
    var mapping: FlickKeyMapping {
        didSet { setTitle(mapping.center, for: .normal) }
    }
    var onSelection: ((FlickDirection) -> Void)?
    var showsPreview = true
    weak var overlayHost: UIView?

    private var startPoint = CGPoint.zero
    private var activeDirection: FlickDirection = .center
    private var preview: FlickPreviewView?
    private var dimmedButtonStates: [DimmedButtonState] = []

    init(mapping: FlickKeyMapping) {
        self.mapping = mapping
        super.init(frame: .zero)
        setTitle(mapping.center, for: .normal)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard super.beginTracking(touch, with: event) else { return false }
        startPoint = touch.location(in: self)
        activeDirection = .center
        isHighlighted = true
        showPreview(selected: .center)
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let point = touch.location(in: self)
        let direction = FlickGestureResolver.direction(
            deltaX: Double(point.x - startPoint.x),
            deltaY: Double(point.y - startPoint.y)
        )
        let active = mapping[direction] == nil ? nil : direction
        preview?.selectedDirection = active
        if let active, active != activeDirection {
            activeDirection = active
            KeyHaptics.selectionChanged()
        }
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        defer {
            hidePreview()
            isHighlighted = false
            super.endTracking(touch, with: event)
        }
        guard let touch else { return }
        let point = touch.location(in: self)
        let direction = FlickGestureResolver.direction(
            deltaX: Double(point.x - startPoint.x),
            deltaY: Double(point.y - startPoint.y)
        )
        guard mapping[direction] != nil else { return }
        onSelection?(direction)
    }

    override func cancelTracking(with event: UIEvent?) {
        hidePreview()
        isHighlighted = false
        super.cancelTracking(with: event)
    }

    private func showPreview(selected: FlickDirection) {
        guard showsPreview, let overlayHost else { return }
        dimOtherButtons(in: overlayHost)

        let preview = FlickPreviewView(mapping: mapping)
        let keyFrame = convert(bounds, to: overlayHost)
        let cellWidth = keyFrame.width * 1.18
        let cellHeight = min(keyFrame.height * 1.18, 62)
        let size = CGSize(width: cellWidth * 3, height: cellHeight * 3)
        var origin = CGPoint(x: keyFrame.midX - size.width / 2, y: keyFrame.midY - size.height / 2)
        let contentBottom = origin.y + (mapping[.down] == nil ? size.height - cellHeight : size.height)
        let bottomOverflow = contentBottom - (overlayHost.bounds.maxY - 4)
        if bottomOverflow > 0 {
            origin.y = max(overlayHost.bounds.minY, origin.y - bottomOverflow)
        }
        preview.frame = CGRect(origin: origin, size: size)
        preview.selectedDirection = selected
        overlayHost.addSubview(preview)
        self.preview = preview
    }

    private func hidePreview() {
        preview?.removeFromSuperview()
        preview = nil
        restoreDimmedButtons()
    }

    private func dimOtherButtons(in rootView: UIView) {
        dimmedButtonStates = rootView.allDescendants(of: UIButton.self)
            .filter { $0 !== self }
            .map { button in
                let state = DimmedButtonState(
                    button: button,
                    titleAlpha: button.titleLabel?.alpha ?? 1,
                    imageAlpha: button.imageView?.alpha ?? 1
                )
                button.titleLabel?.alpha = 0.35
                button.imageView?.alpha = 0.35
                return state
            }
    }

    private func restoreDimmedButtons() {
        for state in dimmedButtonStates {
            state.button.titleLabel?.alpha = state.titleAlpha
            state.button.imageView?.alpha = state.imageAlpha
        }
        dimmedButtonStates.removeAll()
    }
}

private struct DimmedButtonState {
    let button: UIButton
    let titleAlpha: CGFloat
    let imageAlpha: CGFloat
}

private extension UIView {
    func allDescendants<T: UIView>(of type: T.Type) -> [T] {
        subviews.flatMap { subview in
            let current = subview as? T
            return (current.map { [$0] } ?? []) + subview.allDescendants(of: type)
        }
    }
}

private final class FlickPreviewView: UIView {
    var selectedDirection: FlickDirection? {
        didSet { updateSelection() }
    }

    private var options: [FlickDirection: FlickPreviewOptionView] = [:]

    init(mapping: FlickKeyMapping) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false

        for direction in FlickDirection.allCases {
            guard let symbol = mapping[direction] else { continue }
            let option = FlickPreviewOptionView(symbol: symbol, direction: direction)
            addSubview(option)
            options[direction] = option
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let cell = CGSize(width: bounds.width / 3, height: bounds.height / 3)
        let positions: [FlickDirection: (Int, Int)] = [
            .center: (1, 1), .left: (0, 1), .up: (1, 0),
            .right: (2, 1), .down: (1, 2)
        ]
        for (direction, option) in options {
            guard let position = positions[direction] else { continue }
            option.frame = CGRect(
                x: CGFloat(position.0) * cell.width,
                y: CGFloat(position.1) * cell.height,
                width: cell.width,
                height: cell.height
            )
        }
    }

    private func updateSelection() {
        for (direction, option) in options {
            option.isSelected = direction == selectedDirection
        }
    }
}

private final class FlickPreviewOptionView: UIView {
    var isSelected = false {
        didSet { updateAppearance() }
    }

    private let materialView = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private let tintView = UIView()
    private let label = UILabel()

    init(symbol: String, direction: FlickDirection) {
        super.init(frame: .zero)

        layer.cornerRadius = 11
        layer.cornerCurve = .continuous
        layer.maskedCorners = Self.maskedCorners(for: direction)
        clipsToBounds = true

        materialView.isUserInteractionEnabled = false
        addSubview(materialView)

        tintView.isUserInteractionEnabled = false
        materialView.contentView.addSubview(tintView)

        label.textAlignment = .center
        if ToneSymbolStyle.isToneSymbol(symbol) {
            label.attributedText = ToneSymbolStyle.attributedText(
                for: symbol,
                fontSize: ToneSymbolStyle.previewFontSize
            )
        } else {
            label.text = symbol
            label.font = .systemFont(ofSize: symbol.count > 1 ? 15 : 22, weight: .medium)
        }
        materialView.contentView.addSubview(label)
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        materialView.frame = bounds
        tintView.frame = materialView.bounds
        label.frame = materialView.bounds
    }

    private func updateAppearance() {
        tintView.backgroundColor = isSelected
            ? UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(white: 0.48, alpha: 1)
                    : UIColor(white: 0.84, alpha: 1)
            }
            : KeyboardButton.standardKeyColor
        label.textColor = .label
    }

    private static func maskedCorners(for direction: FlickDirection) -> CACornerMask {
        switch direction {
        case .center:
            return []
        case .up:
            return [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        case .down:
            return [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        case .left:
            return [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        case .right:
            return [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        }
    }
}
