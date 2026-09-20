import UIKit

struct FlickFaceStyle: Equatable {
    let centerFontScale: CGFloat
    let directionFontScale: CGFloat

    static let punctuation = FlickFaceStyle(centerFontScale: 0.43, directionFontScale: 0.28)
    static let zhuyin = FlickFaceStyle(centerFontScale: 0.43, directionFontScale: 0.26)
    static let tone = FlickFaceStyle(centerFontScale: 0.56, directionFontScale: 0.42)
}

final class FlickKeyButton: KeyboardButton {
    var mapping: FlickKeyMapping {
        didSet { updateFace() }
    }
    var directionalFace: FlickKeyMapping? {
        didSet { updateFace() }
    }
    var directionalFaceStyle = FlickFaceStyle.punctuation {
        didSet { updateFace() }
    }
    var onSelection: ((FlickDirection) -> Void)?
    var showsPreview = true
    weak var overlayHost: UIView?

    private var startPoint = CGPoint.zero
    private var activeDirection: FlickDirection = .center
    private var preview: FlickPreviewView?
    private var directionalFaceView: FlickDirectionalFaceView?
    private var previewDelayWorkItem: DispatchWorkItem?
    private var dimmedButtonStates: [DimmedButtonState] = []

    private static let previewLongPressDelay: TimeInterval = 0.5

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
        schedulePreviewForLongPress()
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let point = touch.location(in: self)
        let direction = FlickGestureResolver.direction(
            deltaX: Double(point.x - startPoint.x),
            deltaY: Double(point.y - startPoint.y)
        )
        if preview == nil, direction != .center {
            showPreview(selected: direction)
        }
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
            cancelPendingPreview()
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
        cancelPendingPreview()
        hidePreview()
        isHighlighted = false
        super.cancelTracking(with: event)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        directionalFaceView?.frame = bounds
    }

    private func updateFace() {
        directionalFaceView?.removeFromSuperview()
        directionalFaceView = nil

        guard let directionalFace else {
            titleLabel?.isHidden = false
            setTitle(mapping.center, for: .normal)
            return
        }

        let faceView = FlickDirectionalFaceView(mapping: directionalFace, style: directionalFaceStyle)
        addSubview(faceView)
        directionalFaceView = faceView
        setTitle(nil, for: .normal)
        setAttributedTitle(nil, for: .normal)
        titleLabel?.isHidden = true
        setNeedsLayout()
    }

    private func schedulePreviewForLongPress() {
        cancelPendingPreview()
        guard showsPreview else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.showsPreview, self.preview == nil else { return }
            self.showPreview(selected: self.activeDirection)
        }
        previewDelayWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.previewLongPressDelay, execute: workItem)
    }

    private func cancelPendingPreview() {
        previewDelayWorkItem?.cancel()
        previewDelayWorkItem = nil
    }

    private func showPreview(selected: FlickDirection) {
        guard showsPreview, let overlayHost else { return }
        dimOtherButtons(in: overlayHost)

        let preview = FlickPreviewView(mapping: mapping)
        let keyFrame = convert(bounds, to: overlayHost)
        let cellWidth = keyFrame.width * 1.18
        let cellHeight = min(keyFrame.height * 1.18, 62)
        let size = CGSize(width: cellWidth * 3, height: cellHeight * 3)
        let origin = CGPoint(x: keyFrame.midX - size.width / 2, y: keyFrame.midY - size.height / 2)
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
                let faceViews = button.subviews.compactMap { $0 as? FlickDirectionalFaceView }
                let state = DimmedButtonState(
                    button: button,
                    titleAlpha: button.titleLabel?.alpha ?? 1,
                    imageAlpha: button.imageView?.alpha ?? 1,
                    faceAlphas: faceViews.map(\.alpha)
                )
                button.titleLabel?.alpha = 0.35
                button.imageView?.alpha = 0.35
                faceViews.forEach { $0.alpha = 0.35 }
                return state
            }
    }

    private func restoreDimmedButtons() {
        for state in dimmedButtonStates {
            state.button.titleLabel?.alpha = state.titleAlpha
            state.button.imageView?.alpha = state.imageAlpha
            let faceViews = state.button.subviews.compactMap { $0 as? FlickDirectionalFaceView }
            for (faceView, alpha) in zip(faceViews, state.faceAlphas) {
                faceView.alpha = alpha
            }
        }
        dimmedButtonStates.removeAll()
    }
}

private struct DimmedButtonState {
    let button: UIButton
    let titleAlpha: CGFloat
    let imageAlpha: CGFloat
    let faceAlphas: [CGFloat]
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
        for (direction, option) in options {
            option.frame = flickDirectionFrame(for: direction, cell: cell)
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

    private let materialView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
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

private let flickDirectionPositions: [FlickDirection: (column: Int, row: Int)] = [
    .center: (1, 1), .left: (0, 1), .up: (1, 0),
    .right: (2, 1), .down: (1, 2)
]

private func flickDirectionFrame(for direction: FlickDirection, cell: CGSize) -> CGRect {
    guard let position = flickDirectionPositions[direction] else { return .zero }
    return CGRect(
        x: CGFloat(position.column) * cell.width,
        y: CGFloat(position.row) * cell.height,
        width: cell.width,
        height: cell.height
    )
}

private final class FlickDirectionalFaceView: UIView {
    private let style: FlickFaceStyle
    private let centerLabel = UILabel()
    private var directionLabels: [(direction: FlickDirection, label: UILabel)] = []

    init(mapping: FlickKeyMapping, style: FlickFaceStyle) {
        self.style = style
        super.init(frame: .zero)
        isUserInteractionEnabled = false

        centerLabel.text = mapping.center
        Self.configure(centerLabel)
        addSubview(centerLabel)

        for direction in FlickDirection.allCases where direction != .center {
            guard let symbol = mapping[direction] else { continue }
            let label = UILabel()
            label.text = symbol
            Self.configure(label)
            addSubview(label)
            directionLabels.append((direction, label))
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let cell = CGSize(width: bounds.width / 3, height: bounds.height / 3)
        Self.applyFont(to: centerLabel, fontSize: bounds.height * style.centerFontScale)
        centerLabel.frame = bounds
        for (direction, label) in directionLabels {
            Self.applyFont(to: label, fontSize: bounds.height * style.directionFontScale)
            let cellFrame = flickDirectionFrame(for: direction, cell: cell)
            label.frame = cellFrame.insetBy(dx: 0, dy: -cellFrame.height * 0.7)
        }
    }

    private static func applyFont(to label: UILabel, fontSize: CGFloat) {
        guard let symbol = label.text, ToneSymbolStyle.isToneSymbol(symbol) else {
            label.font = .systemFont(ofSize: fontSize)
            return
        }
        label.attributedText = ToneSymbolStyle.attributedText(for: symbol, fontSize: fontSize)
    }

    private static func configure(_ label: UILabel) {
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        label.textColor = .label
    }
}
