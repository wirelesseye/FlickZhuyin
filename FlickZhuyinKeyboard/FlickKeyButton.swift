import UIKit

final class FlickKeyButton: KeyboardButton {
    var mapping: FlickKeyMapping {
        didSet { setTitle(mapping.center, for: .normal) }
    }
    var onSelection: ((FlickDirection) -> Void)?
    weak var overlayHost: UIView?

    private var startPoint = CGPoint.zero
    private var preview: FlickPreviewView?

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
        preview?.selectedDirection = mapping[direction] == nil ? nil : direction
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
        guard let overlayHost else { return }
        let preview = FlickPreviewView(mapping: mapping)
        let keyFrame = convert(bounds, to: overlayHost)
        let cellWidth = keyFrame.width
        let cellHeight = min(keyFrame.height, 52)
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
    }
}

private final class FlickPreviewView: UIView {
    var selectedDirection: FlickDirection? {
        didSet { updateSelection() }
    }

    private var labels: [FlickDirection: UILabel] = [:]

    init(mapping: FlickKeyMapping) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.2
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 2)

        for direction in FlickDirection.allCases {
            guard let symbol = mapping[direction] else { continue }
            let label = UILabel()
            label.text = symbol
            label.textAlignment = .center
            label.font = .systemFont(ofSize: symbol.count > 1 ? 15 : 22, weight: .medium)
            label.textColor = .label
            label.backgroundColor = .systemBackground
            label.layer.cornerRadius = 7
            label.layer.cornerCurve = .continuous
            label.layer.masksToBounds = true
            label.layer.borderWidth = 0.5
            label.layer.borderColor = UIColor.separator.cgColor
            addSubview(label)
            labels[direction] = label
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
        for (direction, label) in labels {
            guard let position = positions[direction] else { continue }
            label.frame = CGRect(
                x: CGFloat(position.0) * cell.width + 2,
                y: CGFloat(position.1) * cell.height + 2,
                width: cell.width - 4,
                height: cell.height - 4
            )
        }
    }

    private func updateSelection() {
        for (direction, label) in labels {
            let selected = direction == selectedDirection
            label.backgroundColor = selected ? .systemBlue : .systemBackground
            label.textColor = selected ? .white : .label
        }
    }
}
