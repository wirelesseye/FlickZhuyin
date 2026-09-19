import UIKit

final class CandidateBarView: UIView {
    var onSelect: ((InputCandidate) -> Void)?

    private let scrollView = UIScrollView()
    private let stackView = UIStackView()
    private let materialView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    private let hairline = UIView()
    private var candidates: [InputCandidate] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        layer.cornerRadius = 13
        layer.cornerCurve = .continuous
        layer.borderWidth = 0.5
        layer.borderColor = UIColor.white.withAlphaComponent(0.35).cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.10
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 2)
        clipsToBounds = true

        materialView.isUserInteractionEnabled = false
        materialView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(materialView)

        hairline.backgroundColor = UIColor.white.withAlphaComponent(0.22)
        hairline.translatesAutoresizingMaskIntoConstraints = false
        materialView.contentView.addSubview(hairline)

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false
        if #available(iOS 26.0, *) {
            scrollView.topEdgeEffect.isHidden = true
            scrollView.leftEdgeEffect.isHidden = true
            scrollView.bottomEdgeEffect.isHidden = true
            scrollView.rightEdgeEffect.isHidden = true
        }
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        stackView.axis = .horizontal
        stackView.alignment = .fill
        stackView.spacing = 2
        stackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stackView)

        NSLayoutConstraint.activate([
            materialView.leadingAnchor.constraint(equalTo: leadingAnchor),
            materialView.trailingAnchor.constraint(equalTo: trailingAnchor),
            materialView.topAnchor.constraint(equalTo: topAnchor),
            materialView.bottomAnchor.constraint(equalTo: bottomAnchor),
            hairline.leadingAnchor.constraint(equalTo: materialView.contentView.leadingAnchor, constant: 12),
            hairline.trailingAnchor.constraint(equalTo: materialView.contentView.trailingAnchor, constant: -12),
            hairline.topAnchor.constraint(equalTo: materialView.contentView.topAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 0.5),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stackView.leadingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.leadingAnchor,
                constant: 4
            ),
            stackView.trailingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.trailingAnchor,
                constant: -4
            ),
            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stackView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(with candidates: [InputCandidate]) {
        self.candidates = candidates
        UIView.performWithoutAnimation {
            for view in stackView.arrangedSubviews {
                stackView.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            for candidate in candidates {
                stackView.addArrangedSubview(makeButton(for: candidate))
            }
            scrollView.contentOffset = .zero
            stackView.layoutIfNeeded()
            layoutIfNeeded()
        }
    }

    private func makeButton(for candidate: InputCandidate) -> UIButton {
        let button = UIButton(type: .system)
        button.configuration = nil
        button.setTitle(candidate.text, for: .normal)
        button.setTitleColor(.label, for: .normal)
        button.backgroundColor = .clear
        button.contentEdgeInsets = UIEdgeInsets(top: 2, left: 10, bottom: 2, right: 10)
        button.titleLabel?.font = .preferredFont(forTextStyle: .title3)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.accessibilityIdentifier = candidate.id.accessibilityIdentifier
        button.accessibilityLabel = candidate.text
        button.addAction(
            UIAction { [weak self] _ in
                guard let self,
                      let match = self.candidates.first(where: { $0.id == candidate.id })
                else {
                    return
                }
                self.onSelect?(match)
            },
            for: .touchUpInside
        )
        return button
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        layer.borderColor = UIColor.white.withAlphaComponent(
            traitCollection.userInterfaceStyle == .dark ? 0.14 : 0.38
        ).cgColor
    }
}
