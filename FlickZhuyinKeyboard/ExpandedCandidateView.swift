import UIKit

final class ExpandedCandidateView: UIView {
    static let contentInset: CGFloat = 4

    var onSelect: ((InputCandidate) -> Void)?

    private static let rowHeight: CGFloat = 40
    private static let spacing: CGFloat = 7

    private let scrollView = UIScrollView()
    private let rowsStack = UIStackView()
    private var candidates: [InputCandidate] = []
    private var lastLayoutWidth: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        accessibilityIdentifier = "expanded-candidate-list"

        scrollView.showsVerticalScrollIndicator = true
        scrollView.alwaysBounceVertical = false
        if #available(iOS 26.0, *) {
            scrollView.topEdgeEffect.isHidden = true
            scrollView.leftEdgeEffect.isHidden = true
            scrollView.bottomEdgeEffect.isHidden = true
            scrollView.rightEdgeEffect.isHidden = true
        }
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        rowsStack.axis = .vertical
        rowsStack.spacing = Self.spacing
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(rowsStack)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            rowsStack.leadingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.leadingAnchor,
                constant: Self.contentInset
            ),
            rowsStack.trailingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.trailingAnchor,
                constant: -Self.contentInset
            ),
            rowsStack.topAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.topAnchor,
                constant: Self.contentInset
            ),
            rowsStack.bottomAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.bottomAnchor,
                constant: -Self.contentInset
            ),
            rowsStack.widthAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.widthAnchor,
                constant: -2 * Self.contentInset
            )
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(with candidates: [InputCandidate]) {
        self.candidates = candidates
        rebuildRows(forWidth: bounds.width)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.width != lastLayoutWidth else { return }
        rebuildRows(forWidth: bounds.width)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.preferredContentSizeCategory
            != traitCollection.preferredContentSizeCategory
        else {
            return
        }
        rebuildRows(forWidth: bounds.width)
    }

    func prepareForEntrance() {
        guard !rowsStack.arrangedSubviews.isEmpty else { return }
        rowsStack.transform = CGAffineTransform(
            translationX: 0,
            y: -(Self.rowHeight + Self.spacing)
        )
        rowsStack.alpha = 0
    }

    func animateEntrance(completion: (() -> Void)? = nil) {
        guard !rowsStack.arrangedSubviews.isEmpty else {
            completion?()
            return
        }
        UIView.animate(
            withDuration: 0.25,
            delay: 0,
            options: [.curveEaseOut],
            animations: {
                self.rowsStack.transform = .identity
                self.rowsStack.alpha = 1
            },
            completion: { _ in completion?() }
        )
    }

    func resetEntranceState() {
        rowsStack.layer.removeAllAnimations()
        rowsStack.transform = .identity
        rowsStack.alpha = 1
    }

    private func rebuildRows(forWidth width: CGFloat) {
        lastLayoutWidth = width
        UIView.performWithoutAnimation {
            for view in rowsStack.arrangedSubviews {
                rowsStack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            guard width > 0, !candidates.isEmpty else { return }
            let availableWidth = width - 2 * Self.contentInset
            var row = makeRow()
            var rowWidth: CGFloat = 0
            for candidate in candidates {
                let button = makeButton(for: candidate, maximumWidth: availableWidth)
                let buttonWidth = min(button.intrinsicContentSize.width, availableWidth)
                if rowWidth > 0, rowWidth + Self.spacing + buttonWidth > availableWidth {
                    appendRow(row)
                    row = makeRow()
                    rowWidth = 0
                }
                row.addArrangedSubview(button)
                rowWidth += (rowWidth > 0 ? Self.spacing : 0) + buttonWidth
            }
            appendRow(row)
        }
    }

    private func makeRow() -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = Self.spacing
        row.distribution = .fill
        row.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
        return row
    }

    private func appendRow(_ row: UIStackView) {
        if let last = row.arrangedSubviews.last {
            row.setCustomSpacing(0, after: last)
        }
        let spacer = makeSpacer()
        spacer.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        row.addArrangedSubview(spacer)
        rowsStack.addArrangedSubview(row)
    }

    private func makeButton(for candidate: InputCandidate, maximumWidth: CGFloat) -> CandidateButton {
        let button = CandidateButton.make(for: candidate, adjustsTitleToFit: true) { [weak self] selected in
            self?.onSelect?(selected)
        }
        button.widthAnchor.constraint(lessThanOrEqualToConstant: maximumWidth).isActive = true
        return button
    }

    private func makeSpacer() -> UIView {
        let spacer = UIView()
        spacer.isUserInteractionEnabled = false
        spacer.backgroundColor = .clear
        spacer.accessibilityElementsHidden = true
        return spacer
    }
}
