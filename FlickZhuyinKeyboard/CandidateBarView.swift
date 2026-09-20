import UIKit

enum CandidateMetrics {
    static let contentInsets = UIEdgeInsets(top: 2, left: 10, bottom: 2, right: 10)
    static let itemHeight: CGFloat = 40

    static func itemWidth(_ text: String) -> CGFloat {
        let font = UIFont.preferredFont(forTextStyle: .title3)
        let width = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        return width + contentInsets.left + contentInsets.right
    }
}

final class CandidateCell: UICollectionViewCell {
    static let reuseIdentifier = "CandidateCell"

    private(set) var candidate: InputCandidate?
    private var onSelect: ((InputCandidate) -> Void)?
    private let button = CandidateButton(type: .custom)

    override init(frame: CGRect) {
        super.init(frame: frame)
        button.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            button.topAnchor.constraint(equalTo: contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
        button.addAction(
            UIAction { [weak self] _ in
                guard let self, let candidate else { return }
                KeyHaptics.keyDown()
                onSelect?(candidate)
            },
            for: .touchUpInside
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        with candidate: InputCandidate,
        adjustsTitleToFit: Bool,
        onSelect: @escaping (InputCandidate) -> Void
    ) {
        self.candidate = candidate
        self.onSelect = onSelect
        button.update(with: candidate, adjustsTitleToFit: adjustsTitleToFit)
    }
}

final class CandidateBarView: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    var onSelect: ((InputCandidate) -> Void)?
    var onToggleExpansion: (() -> Void)?
    var onVisibleCandidatesChanged: ((Int) -> Void)?

    private(set) var isExpanded = false
    private(set) var visibleCandidateCount = 0
    private var isTransitioningExpansion = false
    private var isAdjustingLayout = false
    private var hasCandidates = false
    private var candidates: [InputCandidate] = []
    private var widthCache: [String: CGFloat] = [:]

    static let animationDuration: TimeInterval = 0.25

    private static let collapsedSpacing: CGFloat = 2
    private static let contentInset: CGFloat = 4
    private static let expandSymbolPointSize: CGFloat = 13
    private static let expandButtonLeadingInset: CGFloat = 8
    private static let expandButtonContentWidth: CGFloat = 36
    private static let dividerHeight: CGFloat = 20

    private let flowLayout = UICollectionViewFlowLayout()
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: flowLayout)
    private let expandButton = UIButton(type: .system)
    private let dividerView = UIView()
    private let hitSurfaceView = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        flowLayout.scrollDirection = .horizontal
        flowLayout.minimumInteritemSpacing = Self.collapsedSpacing
        flowLayout.minimumLineSpacing = 0
        flowLayout.sectionInset = UIEdgeInsets(
            top: 0,
            left: Self.contentInset,
            bottom: 0,
            right: Self.contentInset
        )

        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(
            CandidateCell.self,
            forCellWithReuseIdentifier: CandidateCell.reuseIdentifier
        )
        collectionView.backgroundColor = KeyboardSurface.interactionColor
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.alwaysBounceHorizontal = false
        collectionView.contentInsetAdjustmentBehavior = .never
        if #available(iOS 26.0, *) {
            collectionView.topEdgeEffect.isHidden = true
            collectionView.leftEdgeEffect.isHidden = true
            collectionView.bottomEdgeEffect.isHidden = true
            collectionView.rightEdgeEffect.isHidden = true
        }
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(collectionView)

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
        hitSurfaceView.backgroundColor = KeyboardSurface.interactionColor
        hitSurfaceView.isUserInteractionEnabled = false
        insertSubview(hitSurfaceView, belowSubview: expandButton)

        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: dividerView.leadingAnchor, constant: -8),
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
            dividerView.trailingAnchor.constraint(equalTo: expandButton.leadingAnchor),
            dividerView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dividerView.widthAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
            dividerView.heightAnchor.constraint(equalToConstant: Self.dividerHeight),
            expandButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            expandButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            expandButton.widthAnchor.constraint(
                equalToConstant: Self.expandButtonLeadingInset + Self.expandButtonContentWidth
            ),
            expandButton.heightAnchor.constraint(equalTo: heightAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(with candidates: [InputCandidate]) {
        guard candidates != self.candidates else { return }
        self.candidates = candidates
        UIView.performWithoutAnimation {
            isAdjustingLayout = true
            defer { isAdjustingLayout = false }
            collectionView.reloadData()
            collectionView.setContentOffset(.zero, animated: false)
            flowLayout.minimumInteritemSpacing = Self.collapsedSpacing
            flowLayout.invalidateLayout()
            collectionView.layoutIfNeeded()
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
        collectionView.isScrollEnabled = !expanded
        collectionView.setContentOffset(.zero, animated: false)
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
                    self.flowLayout.minimumInteritemSpacing = Self.collapsedSpacing
                    self.flowLayout.invalidateLayout()
                }
                self.collectionView.layoutIfNeeded()
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
        if isExpanded, collectionView.contentOffset != .zero {
            collectionView.setContentOffset(.zero, animated: false)
        }
        guard !isTransitioningExpansion, !isAdjustingLayout else { return }
        updateVisibleCandidateCount()
        if isExpanded {
            applyExpandedSpacing()
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.preferredContentSizeCategory
            != traitCollection.preferredContentSizeCategory
        else {
            return
        }
        widthCache.removeAll()
        flowLayout.invalidateLayout()
        layoutIfNeeded()
        updateVisibleCandidateCount()
        if isExpanded {
            applyExpandedSpacing()
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard isExpanded, scrollView.contentOffset != .zero else { return }
        scrollView.setContentOffset(.zero, animated: false)
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

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        candidates.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: CandidateCell.reuseIdentifier,
            for: indexPath
        )
        guard let candidateCell = cell as? CandidateCell else { return cell }
        candidateCell.configure(
            with: candidates[indexPath.item],
            adjustsTitleToFit: false
        ) { [weak self] selected in
            self?.onSelect?(selected)
        }
        return candidateCell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        CGSize(
            width: itemWidth(for: candidates[indexPath.item].text),
            height: max(collectionView.bounds.height, CandidateMetrics.itemHeight)
        )
    }

    private func toggleExpansion() {
        KeyHaptics.keyDown()
        onToggleExpansion?()
    }

    private func itemWidth(for text: String) -> CGFloat {
        if let cached = widthCache[text] {
            return cached
        }
        let width = CandidateMetrics.itemWidth(text)
        widthCache[text] = width
        return width
    }

    private func updateVisibleCandidateCount() {
        collectionView.layoutIfNeeded()
        let visibleWidth = collectionView.bounds.width - Self.contentInset
        var count = 0
        for index in 0..<candidates.count {
            guard let attributes = collectionView.layoutAttributesForItem(
                at: IndexPath(item: index, section: 0)
            ) else { break }
            guard attributes.frame.maxX - Self.contentInset <= visibleWidth + 0.5 else { break }
            count += 1
        }
        guard count != visibleCandidateCount else { return }
        visibleCandidateCount = count
        onVisibleCandidatesChanged?(count)
    }

    private func applyExpandedPresentation() {
        applyExpandedSpacing()
        setExtrasAccessibilityHidden(true)
        collectionView.layoutIfNeeded()
        layoutIfNeeded()
    }

    private func applyExpandedSpacing() {
        let spacing = computedExpandedSpacing()
        guard flowLayout.minimumInteritemSpacing != spacing else { return }
        flowLayout.minimumInteritemSpacing = spacing
        flowLayout.invalidateLayout()
    }

    private func computedExpandedSpacing() -> CGFloat {
        let count = visibleCandidateCount
        guard count > 0 else { return Self.collapsedSpacing }
        var contentWidth: CGFloat = 0
        for index in 0..<count {
            guard let attributes = collectionView.layoutAttributesForItem(
                at: IndexPath(item: index, section: 0)
            ) else { break }
            contentWidth += attributes.frame.width
        }
        let availableWidth = collectionView.bounds.width - 2 * Self.contentInset
        let spacing = (availableWidth - contentWidth) / CGFloat(max(1, count - 1))
        return max(Self.collapsedSpacing, spacing)
    }

    private func setExtrasAccessibilityHidden(_ hidden: Bool) {
        for cell in collectionView.visibleCells {
            guard let indexPath = collectionView.indexPath(for: cell) else { continue }
            cell.accessibilityElementsHidden = hidden && indexPath.item >= visibleCandidateCount
        }
    }
}

final class CandidateButton: UIButton {
    func update(with candidate: InputCandidate, adjustsTitleToFit: Bool) {
        configuration = nil
        setTitle(candidate.text, for: .normal)
        setTitleColor(.label, for: .normal)
        titleLabel?.font = .preferredFont(forTextStyle: .title3)
        titleLabel?.adjustsFontForContentSizeCategory = true
        titleLabel?.adjustsFontSizeToFitWidth = adjustsTitleToFit
        titleLabel?.minimumScaleFactor = adjustsTitleToFit ? 0.6 : 1
        titleLabel?.lineBreakMode = .byClipping
        accessibilityIdentifier = candidate.id.accessibilityIdentifier
        accessibilityLabel = candidate.text
    }

    override var isHighlighted: Bool {
        didSet { updateAppearance() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentEdgeInsets = CandidateMetrics.contentInsets
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
