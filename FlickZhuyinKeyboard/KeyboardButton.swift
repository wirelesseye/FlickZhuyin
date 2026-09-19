import UIKit

class KeyboardButton: UIButton {
    static let standardKeyColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.28, alpha: 1)
            : UIColor(white: 1, alpha: 1)
    }

    var normalColor: UIColor = KeyboardButton.standardKeyColor {
        didSet { updateAppearance() }
    }

    private let materialView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    private let tintView = UIView()

    override var isHighlighted: Bool {
        didSet { updateAppearance() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 11
        layer.cornerCurve = .continuous
        clipsToBounds = false

        materialView.isUserInteractionEnabled = false
        materialView.layer.cornerRadius = 11
        materialView.layer.cornerCurve = .continuous
        materialView.clipsToBounds = true
        insertSubview(materialView, at: 0)

        tintView.isUserInteractionEnabled = false
        tintView.layer.cornerRadius = 11
        tintView.layer.cornerCurve = .continuous
        tintView.clipsToBounds = true
        materialView.contentView.addSubview(tintView)

        titleLabel?.font = .systemFont(ofSize: 20, weight: .regular)
        setTitleColor(.label, for: .normal)
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        sendSubviewToBack(materialView)
        materialView.frame = bounds
        tintView.frame = materialView.bounds
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateAppearance()
    }

    private func updateAppearance() {
        backgroundColor = .clear
        tintView.backgroundColor = isHighlighted
            ? normalColor.withAlphaComponent(0.78)
            : normalColor
        materialView.effect = UIBlurEffect(
            style: isHighlighted ? .systemThinMaterial : .systemUltraThinMaterial
        )
        transform = isHighlighted
            ? CGAffineTransform(scaleX: 0.97, y: 0.97)
            : .identity
    }
}
