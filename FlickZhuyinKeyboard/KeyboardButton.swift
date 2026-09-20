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

enum KeyboardSurface {
    // Keyboard extensions are hosted in a remote window whose input region can
    // omit fully transparent pixels. Render an imperceptible surface so scrollable
    // areas stay part of that input region.
    static let interactionColor = UIColor.systemBackground.withAlphaComponent(0.02)
}

final class KeyRepeater {
    private let initialDelay: TimeInterval
    private let interval: TimeInterval
    private let action: () -> Void
    private var timer: Timer?
    private var didRepeat = false

    init(
        initialDelay: TimeInterval = 0.4,
        interval: TimeInterval = 0.1,
        action: @escaping () -> Void
    ) {
        self.initialDelay = initialDelay
        self.interval = interval
        self.action = action
    }

    deinit {
        timer?.invalidate()
    }

    func begin() {
        guard timer == nil else { return }
        didRepeat = false
        let timer = Timer(timeInterval: initialDelay, repeats: false) { [weak self] _ in
            self?.fireFirstRepeat()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func end() {
        timer?.invalidate()
        timer = nil
    }

    func consumeRepeat() -> Bool {
        defer { didRepeat = false }
        return didRepeat
    }

    private func fireFirstRepeat() {
        timer = nil
        didRepeat = true
        action()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.action()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
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

    private let tintView = UIView()

    override var isHighlighted: Bool {
        didSet { updateAppearance() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 11
        layer.cornerCurve = .continuous
        clipsToBounds = false

        tintView.isUserInteractionEnabled = false
        tintView.layer.cornerRadius = 11
        tintView.layer.cornerCurve = .continuous
        tintView.clipsToBounds = true
        insertSubview(tintView, at: 0)

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
        sendSubviewToBack(tintView)
        tintView.frame = bounds
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
