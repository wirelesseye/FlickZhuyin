import UIKit

final class CandidateBarView: UIView {
    var onSelect: ((InputCandidate) -> Void)?
    var onToggleExpansion: (() -> Void)?
    var onVisibleCandidatesChanged: ((Int) -> Void)?

    private(set) var isExpanded = false
    private(set) var visibleCandidateCount = 0
    private var isTransitioningExpansion = false
    private var isAdjustingLayout = false
    private var hasCandidates = false

    static let animationDuration: TimeInterval = 0.25

    private static let collapsedSpacing: CGFloat = 2
    private static let contentInset: CGFloat = 4
    private static let expandSymbolPointSize: CGFloat = 13
    private static let expandButtonLeadingInset: CGFloat = 8
    private static let expandButtonContentWidth: CGFloat = 36
    private static let dividerHeight: CGFloat = 20

    private let scrollView = UIScrollView()
    private let stackView = UIStackView()
    private let expandButton = UIButton(type: .system)
    private let dividerView = UIView()
    private let hitSurfaceView = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

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

        expandButton.setImage(
            UIImage(
                systemName: "chevron.down",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: Self.expandSymbolPointSize, weight: .medium)
            ),
            for: .normal
        )
        expandButton.tintColor = .label
        expandButton.backgroundColor = .clear
        expandButton.contentEdgeInsets = UIEdgeInsets(
            top: 0,
            left: Self.expandButtonLeadingInset,
            bottom: 0,
            right: 0
        )
        expandButton.accessibilityIdentifier = "candidate-expand-toggle"
        expandButton.accessibilityLabel = "展開候選字"
        expandButton.isEnabled = false
        expandButton.alpha = 0.4
        expandButton.isHidden = true
        expandButton.translatesAutoresizingMaskIntoConstraints = false
        expandButton.addAction(
            UIAction { [weak self] _ in self?.toggleExpansion() },
            for: .touchUpInside
        )
        addSubview(expandButton)

        dividerView.backgroundColor = .separator
        dividerView.isAccessibilityElement = false
        dividerView.isUserInteractionEnabled = false
        dividerView.isHidden = true
        dividerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dividerView)

        // Keyboard extensions are hosted in a remote window whose input region can
        // omit fully transparent pixels. Render an imperceptible surface so the
        // whole area to the right of the divider remains part of that input region.
        hitSurfaceView.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.02)
        hitSurfaceView.isUserInteractionEnabled = false
        insertSubview(hitSurfaceView, belowSubview: expandButton)

        stackView.axis = .horizontal
        stackView.alignment = .fill
        stackView.spacing = Self.collapsedSpacing
        stackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stackView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: dividerView.leadingAnchor, constant: -8),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            dividerView.trailingAnchor.constraint(equalTo: expandButton.leadingAnchor),
            dividerView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dividerView.widthAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
            dividerView.heightAnchor.constraint(equalToConstant: Self.dividerHeight),
            expandButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            expandButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            expandButton.widthAnchor.constraint(
                equalToConstant: Self.expandButtonLeadingInset + Self.expandButtonContentWidth
            ),
            expandButton.heightAnchor.constraint(equalTo: heightAnchor),
            stackView.leadingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.leadingAnchor,
                constant: Self.contentInset
            ),
            stackView.trailingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.trailingAnchor,
                constant: -Self.contentInset
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
        UIView.performWithoutAnimation {
            isAdjustingLayout = true
            defer { isAdjustingLayout = false }
            for view in stackView.arrangedSubviews {
                stackView.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            for candidate in candidates {
                stackView.addArrangedSubview(makeButton(for: candidate))
            }
            scrollView.contentOffset = .zero
            stackView.spacing = Self.collapsedSpacing
            layoutIfNeeded()
            updateVisibleCandidateCount()
            if isExpanded {
                applyExpandedPresentation()
            }
        }
        let hasCandidates = !candidates.isEmpty
        self.hasCandidates = hasCandidates
        expandButton.isHidden = !hasCandidates
        dividerView.isHidden = !hasCandidates || isExpanded
        expandButton.isEnabled = hasCandidates
        expandButton.alpha = hasCandidates ? 1 : 0.4
    }

    func setExpanded(_ expanded: Bool, completion: (() -> Void)? = nil) {
        guard isExpanded != expanded else {
            completion?()
            return
        }
        isExpanded = expanded
        let symbol = expanded ? "chevron.up" : "chevron.down"
        expandButton.setImage(
            UIImage(
                systemName: symbol,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: Self.expandSymbolPointSize, weight: .medium)
            ),
            for: .normal
        )
        expandButton.accessibilityLabel = expanded ? "收合候選字" : "展開候選字"
        dividerView.isHidden = expanded || !hasCandidates
        scrollView.isScrollEnabled = !expanded
        scrollView.contentOffset = .zero
        setExtrasAccessibilityHidden(expanded)
        isTransitioningExpansion = true
        UIView.animate(
            withDuration: Self.animationDuration,
            delay: 0,
            options: [.curveEaseInOut],
            animations: {
                if expanded {
                    self.applyExpandedSpacing()
                } else {
                    self.stackView.spacing = Self.collapsedSpacing
                }
                self.stackView.layoutIfNeeded()
            },
            completion: { [weak self] _ in
                guard let self else { return }
                self.isTransitioningExpansion = false
                if !self.isExpanded {
                    self.updateVisibleCandidateCount()
                }
                completion?()
            }
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        hitSurfaceView.frame = CGRect(
            x: dividerView.frame.maxX,
            y: bounds.minY,
            width: max(0, bounds.maxX - dividerView.frame.maxX),
            height: bounds.height
        )
        guard !isTransitioningExpansion, !isAdjustingLayout else { return }
        updateVisibleCandidateCount()
        if isExpanded {
            applyExpandedSpacing()
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let isInExpansionRegion =
            !expandButton.isHidden
            && expandButton.isEnabled
            && bounds.contains(point)
            && point.x >= dividerView.frame.maxX

        guard isInExpansionRegion else { return super.hitTest(point, with: event) }

        return expandButton
    }

    private func toggleExpansion() {
        KeyHaptics.keyDown()
        onToggleExpansion?()
    }

    private func updateVisibleCandidateCount() {
        stackView.layoutIfNeeded()
        let visibleWidth = scrollView.bounds.width - Self.contentInset
        var offset: CGFloat = 0
        var count = 0
        for view in stackView.arrangedSubviews {
            let maxX = offset + view.bounds.width
            guard maxX <= visibleWidth + 0.5 else { break }
            count += 1
            offset = maxX + Self.collapsedSpacing
        }
        guard count != visibleCandidateCount else { return }
        visibleCandidateCount = count
        onVisibleCandidatesChanged?(count)
    }

    private func applyExpandedPresentation() {
        applyExpandedSpacing()
        setExtrasAccessibilityHidden(true)
        stackView.layoutIfNeeded()
        layoutIfNeeded()
    }

    private func applyExpandedSpacing() {
        let spacing = computedExpandedSpacing()
        guard stackView.spacing != spacing else { return }
        stackView.spacing = spacing
    }

    private func computedExpandedSpacing() -> CGFloat {
        let count = visibleCandidateCount
        guard count > 0 else { return Self.collapsedSpacing }
        let contentWidth = stackView.arrangedSubviews.prefix(count)
            .reduce(CGFloat.zero) { $0 + $1.bounds.width }
        let availableWidth = scrollView.bounds.width - 2 * Self.contentInset
        let spacing = (availableWidth - contentWidth) / CGFloat(max(1, count - 1))
        return max(Self.collapsedSpacing, spacing)
    }

    private func setExtrasAccessibilityHidden(_ hidden: Bool) {
        for view in stackView.arrangedSubviews.dropFirst(visibleCandidateCount) {
            view.accessibilityElementsHidden = hidden
        }
    }

    private func makeButton(for candidate: InputCandidate) -> CandidateButton {
        CandidateButton.make(for: candidate) { [weak self] selected in
            self?.onSelect?(selected)
        }
    }
}

final class CandidateButton: UIButton {
    static func make(
        for candidate: InputCandidate,
        contentInsets: UIEdgeInsets = UIEdgeInsets(top: 2, left: 10, bottom: 2, right: 10),
        adjustsTitleToFit: Bool = false,
        onSelect: @escaping (InputCandidate) -> Void
    ) -> CandidateButton {
        let button = CandidateButton(type: .custom)
        button.configuration = nil
        button.setTitle(candidate.text, for: .normal)
        button.setTitleColor(.label, for: .normal)
        button.contentEdgeInsets = contentInsets
        button.titleLabel?.font = .preferredFont(forTextStyle: .title3)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        if adjustsTitleToFit {
            button.titleLabel?.adjustsFontSizeToFitWidth = true
            button.titleLabel?.minimumScaleFactor = 0.6
            button.titleLabel?.lineBreakMode = .byClipping
        }
        button.accessibilityIdentifier = candidate.id.accessibilityIdentifier
        button.accessibilityLabel = candidate.text
        button.addAction(
            UIAction { _ in
                KeyHaptics.keyDown()
                onSelect(candidate)
            },
            for: .touchUpInside
        )
        return button
    }

    override var isHighlighted: Bool {
        didSet { updateAppearance() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
        clipsToBounds = true
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateAppearance() {
        alpha = 1
        titleLabel?.alpha = 1
        backgroundColor = isHighlighted ? KeyboardButton.standardKeyColor : .clear
    }
}
