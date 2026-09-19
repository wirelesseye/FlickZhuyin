import UIKit

class KeyboardButton: UIButton {
    var normalColor: UIColor = .secondarySystemBackground {
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
        layer.borderWidth = 0.5
        layer.borderColor = UIColor.white.withAlphaComponent(0.38).cgColor
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
        tintView.backgroundColor = normalColor.withAlphaComponent(isHighlighted ? 0.32 : 0.48)
        materialView.effect = UIBlurEffect(
            style: isHighlighted ? .systemThinMaterial : .systemUltraThinMaterial
        )
        layer.borderColor = UIColor.white.withAlphaComponent(
            traitCollection.userInterfaceStyle == .dark ? 0.16 : 0.46
        ).cgColor
        transform = isHighlighted
            ? CGAffineTransform(scaleX: 0.97, y: 0.97)
            : .identity
    }
}
