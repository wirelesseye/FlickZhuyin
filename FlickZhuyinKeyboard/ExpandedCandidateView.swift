import UIKit

final class ExpandedCandidateView: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    static let contentInset: CGFloat = 4

    var onSelect: ((InputCandidate) -> Void)?

    private static let spacing: CGFloat = 7

    private let flowLayout = UICollectionViewFlowLayout()
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: flowLayout)
    private var candidates: [InputCandidate] = []
    private var widthCache: [String: CGFloat] = [:]
    private var lastLayoutWidth: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        accessibilityIdentifier = "expanded-candidate-list"

        flowLayout.scrollDirection = .vertical
        flowLayout.minimumInteritemSpacing = Self.spacing
        flowLayout.minimumLineSpacing = Self.spacing
        flowLayout.sectionInset = UIEdgeInsets(
            top: Self.contentInset,
            left: Self.contentInset,
            bottom: Self.contentInset,
            right: Self.contentInset
        )

        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(
            CandidateCell.self,
            forCellWithReuseIdentifier: CandidateCell.reuseIdentifier
        )
        collectionView.backgroundColor = KeyboardSurface.interactionColor
        collectionView.showsVerticalScrollIndicator = true
        collectionView.alwaysBounceVertical = false
        collectionView.contentInsetAdjustmentBehavior = .never
        if #available(iOS 26.0, *) {
            collectionView.topEdgeEffect.isHidden = true
            collectionView.leftEdgeEffect.isHidden = true
            collectionView.bottomEdgeEffect.isHidden = true
            collectionView.rightEdgeEffect.isHidden = true
        }
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(collectionView)

        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(with candidates: [InputCandidate]) {
        self.candidates = candidates
        collectionView.reloadData()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.width != lastLayoutWidth else { return }
        lastLayoutWidth = bounds.width
        collectionView.reloadData()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.preferredContentSizeCategory
            != traitCollection.preferredContentSizeCategory
        else {
            return
        }
        widthCache.removeAll()
        collectionView.reloadData()
    }

    func prepareForEntrance() {
        guard !candidates.isEmpty else { return }
        collectionView.transform = CGAffineTransform(
            translationX: 0,
            y: -(CandidateMetrics.itemHeight + Self.spacing)
        )
        collectionView.alpha = 0
    }

    func animateEntrance(completion: (() -> Void)? = nil) {
        guard !candidates.isEmpty else {
            completion?()
            return
        }
        UIView.animate(
            withDuration: 0.25,
            delay: 0,
            options: [.curveEaseOut],
            animations: {
                self.collectionView.transform = .identity
                self.collectionView.alpha = 1
            },
            completion: { _ in completion?() }
        )
    }

    func resetEntranceState() {
        collectionView.layer.removeAllAnimations()
        collectionView.transform = .identity
        collectionView.alpha = 1
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
        let candidate = candidates[indexPath.item]
        candidateCell.configure(
            with: candidate,
            adjustsTitleToFit: isOversized(candidate.text)
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
            width: min(itemWidth(for: candidates[indexPath.item].text), availableWidth),
            height: CandidateMetrics.itemHeight
        )
    }

    private var availableWidth: CGFloat {
        max(collectionView.bounds.width - 2 * Self.contentInset, 1)
    }

    private func isOversized(_ text: String) -> Bool {
        itemWidth(for: text) > availableWidth
    }

    private func itemWidth(for text: String) -> CGFloat {
        if let cached = widthCache[text] {
            return cached
        }
        let width = CandidateMetrics.itemWidth(text)
        widthCache[text] = width
        return width
    }
}
