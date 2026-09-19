import UIKit

enum KeyHaptics {
    private static let impact = UIImpactFeedbackGenerator(style: .light)
    private static let selection = UISelectionFeedbackGenerator()

    static func prepare() {
        impact.prepare()
        selection.prepare()
    }

    static func keyDown() {
        impact.impactOccurred()
        impact.prepare()
    }

    static func selectionChanged() {
        selection.selectionChanged()
        selection.prepare()
    }
}

class KeyboardButton: UIButton {
    static let standardKeyColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.28, alpha: 0.85)
            : UIColor(white: 1, alpha: 0.85)
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

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard super.beginTracking(touch, with: event) else { return false }
        KeyHaptics.keyDown()
        return true
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

enum ToneSymbolStyle {
    static let previewFontSize: CGFloat = 28
    static let keyFontSize: CGFloat = 26

    private static let symbols = Set(MandarinTone.allCases.map(\.symbol))

    static func isToneSymbol(_ symbol: String) -> Bool {
        symbols.contains(symbol)
    }

    // modifier letters 的字形偏上，需下移（負值）拉回視覺中央。
    // 下方數值以 previewFontSize 為基準調校，其餘字級等比縮放；請在模擬器上微調。
    static func baselineOffset(for symbol: String, fontSize: CGFloat) -> CGFloat {
        let base: CGFloat =
            switch symbol {
            case "ˉ": -9
            case "ˊ": -9
            case "ˇ": -7
            case "ˋ": -9
            case "˙": -6
            default: 0
            }
        return base * fontSize / previewFontSize
    }

    static func attributedText(
        for symbol: String,
        fontSize: CGFloat,
        weight: UIFont.Weight = .medium
    ) -> NSAttributedString {
        NSAttributedString(
            string: symbol,
            attributes: [
                .font: UIFont.systemFont(ofSize: fontSize, weight: weight),
                .baselineOffset: baselineOffset(for: symbol, fontSize: fontSize)
            ]
        )
    }
}
