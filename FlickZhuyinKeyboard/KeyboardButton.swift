import UIKit

final class KeyboardButton: UIButton {
    var normalColor: UIColor = .secondarySystemBackground {
        didSet { updateAppearance() }
    }

    override var isHighlighted: Bool {
        didSet { updateAppearance() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 6
        layer.cornerCurve = .continuous
        titleLabel?.font = .systemFont(ofSize: 20)
        setTitleColor(.label, for: .normal)
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateAppearance() {
        backgroundColor = isHighlighted ? .tertiarySystemFill : normalColor
    }
}
