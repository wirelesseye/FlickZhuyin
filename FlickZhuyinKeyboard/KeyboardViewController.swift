import UIKit

final class KeyboardViewController: UIInputViewController {
    private var engine = KeyboardEngine()
    private var keyButtons: [(key: KeyboardKey, button: KeyboardButton)] = []
    private weak var nextKeyboardButton: KeyboardButton?
    private weak var candidateBar: CandidateBarView?
    private weak var toneButton: FlickKeyButton?
    private weak var neutralToneButton: KeyboardButton?
    private var heightConstraint: NSLayoutConstraint?
    private var documentEffectDepth = 0

    private var coordinator: ChineseInputCoordinator?

    private lazy var effectApplier = DocumentEffectApplier(
        client: TextDocumentProxyClient(proxy: textDocumentProxy)
    )

    override func viewDidLoad() {
        super.viewDidLoad()
        view.isOpaque = false
        view.backgroundColor = .clear
        KeyHaptics.prepare()
        configureHeight()
        rebuildKeyboard()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        nextKeyboardButton?.isHidden = !needsInputModeSwitchKey
        updateKeyboardHeight()
    }

    override func textWillChange(_ textInput: UITextInput?) {
        super.textWillChange(textInput)
        handleHostDocumentChange()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        handleHostDocumentChange()
    }

    override func handleInputModeList(from view: UIView, with event: UIEvent) {
        super.handleInputModeList(from: view, with: event)
    }

    private func rebuildKeyboard() {
        view.subviews.forEach { $0.removeFromSuperview() }
        keyButtons.removeAll(keepingCapacity: true)
        nextKeyboardButton = nil
        candidateBar = nil
        toneButton = nil
        neutralToneButton = nil

        switch engine.mode {
        case .zhuyin: buildZhuyinKeyboard()
        case .abc: buildABCKeyboard()
        }
        refreshUI()
        view.setNeedsLayout()
    }

    private func buildABCKeyboard() {
        let keyboardStack = pinnedVerticalStack(spacing: 7)
        keyboardStack.distribution = .fillEqually
        for (index, row) in KeyboardLayout.letterRows.enumerated() {
            let rowStack = makeRow()
            if index == 1 {
                rowStack.layoutMargins = UIEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
                rowStack.isLayoutMarginsRelativeArrangement = true
            }
            let keys = index == 2 ? KeyboardLayout.thirdRow : row
            keys.forEach { rowStack.addArrangedSubview(makeButton(for: $0)) }
            keyboardStack.addArrangedSubview(rowStack)
        }

        let controlStack = makeControlRow()
        for key in [.nextKeyboard, .modeSwitch, .space, .return] as [KeyboardKey] {
            let button = makeButton(for: key)
            controlStack.addArrangedSubview(button)
            switch key {
            case .nextKeyboard, .modeSwitch:
                button.widthAnchor.constraint(equalToConstant: 52).isActive = true
            case .return:
                button.widthAnchor.constraint(equalToConstant: 92).isActive = true
            default:
                break
            }
        }
        keyboardStack.addArrangedSubview(controlStack)
    }

    private func buildZhuyinKeyboard() {
        let mainStack = pinnedVerticalStack(spacing: 7)

        let candidateBar = CandidateBarView()
        candidateBar.onSelect = { [weak self] candidate in self?.select(candidate) }
        candidateBar.heightAnchor.constraint(equalToConstant: 40).isActive = true
        mainStack.addArrangedSubview(candidateBar)
        self.candidateBar = candidateBar

        let grid = UIStackView()
        grid.axis = .vertical
        grid.spacing = 7
        grid.distribution = .fillEqually
        for rowIndex in 0..<3 {
            let row = makeRow()
            row.addArrangedSubview(rowIndex == 2 ? makeButton(for: .modeSwitch) : makeGridSpacer())
            for mapping in ZhuyinLayout.groups[(rowIndex * 3)..<(rowIndex * 3 + 3)] {
                let button = makeFlickButton(mapping: mapping) { [weak self] direction in
                    guard let symbol = mapping[direction], let character = symbol.first else { return }
                    self?.handle(.zhuyin(character))
                }
                row.addArrangedSubview(button)
            }
            switch rowIndex {
            case 1:
                row.addArrangedSubview(makeButton(for: .delete))
            case 2:
                row.addArrangedSubview(makeButton(for: .return))
            default:
                row.addArrangedSubview(makeGridSpacer())
            }
            grid.addArrangedSubview(row)
        }

        let spaceRow = makeRow()
        spaceRow.addArrangedSubview(makeGridSpacer())
        let neutralToneButton = makeButton(for: .tone(.neutral))
        spaceRow.addArrangedSubview(neutralToneButton)
        self.neutralToneButton = neutralToneButton
        spaceRow.addArrangedSubview(makeToneControl())
        spaceRow.addArrangedSubview(makeGridSpacer())
        spaceRow.addArrangedSubview(makeGridSpacer())
        grid.addArrangedSubview(spaceRow)
        mainStack.addArrangedSubview(grid)
    }

    private func makeGridSpacer() -> UIView {
        let spacer = UIView()
        spacer.isUserInteractionEnabled = false
        spacer.backgroundColor = .clear
        spacer.accessibilityElementsHidden = true
        return spacer
    }

    private func makeToneControl() -> FlickKeyButton {
        let button = makeFlickButton(mapping: FlickKeyMapping(["space"])) { [weak self] direction in
            guard let self else { return }
            if self.engine.hasPendingTokens {
                guard let tone = ZhuyinLayout.tone(for: direction) else { return }
                self.handle(.tone(tone))
            } else {
                guard direction == .center else { return }
                self.handle(.space)
            }
        }
        button.titleLabel?.font = .systemFont(ofSize: 15)
        button.normalColor = KeyboardButton.standardKeyColor
        button.accessibilityLabel = "空白或音調"
        toneButton = button
        return button
    }

    private func pinnedVerticalStack(spacing: CGFloat) -> UIStackView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 7),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -7),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        return stack
    }

    private func makeRow() -> UIStackView {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 7
        stack.distribution = .fillEqually
        return stack
    }

    private func makeControlRow() -> UIStackView {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 7
        stack.distribution = .fill
        return stack
    }

    private func makeFlickButton(
        mapping: FlickKeyMapping,
        onSelection: @escaping (FlickDirection) -> Void
    ) -> FlickKeyButton {
        let button = FlickKeyButton(mapping: mapping)
        button.overlayHost = view
        button.onSelection = onSelection
        button.normalColor = KeyboardButton.standardKeyColor
        button.accessibilityLabel = mapping.center
        return button
    }

    private func makeButton(for key: KeyboardKey) -> KeyboardButton {
        let button = KeyboardButton(type: .system)
        button.accessibilityLabel = accessibilityLabel(for: key)
        button.normalColor = KeyboardButton.standardKeyColor

        if key == .nextKeyboard {
            button.setImage(UIImage(systemName: "globe"), for: .normal)
            button.addAction(
                UIAction { [weak self] _ in self?.prepareForInputModeSwitch() },
                for: .touchUpInside
            )
            button.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
            nextKeyboardButton = button
        } else {
            button.addAction(UIAction { [weak self] _ in self?.handle(key) }, for: .touchUpInside)
        }
        keyButtons.append((key, button))
        return button
    }

    private func prepareForInputModeSwitch() {
        apply(engine.update(for: .nextKeyboard))
        refreshUI()
    }

    private func handle(_ key: KeyboardKey) {
        let oldMode = engine.mode
        apply(engine.update(for: key))
        if engine.mode != oldMode {
            rebuildKeyboard()
        } else {
            refreshUI()
        }
    }

    private func select(_ candidate: InputCandidate) {
        apply(engine.selectCandidate(candidate))
        refreshUI()
    }

    private func apply(_ update: KeyboardUpdate) {
        documentEffectDepth += 1
        defer { documentEffectDepth -= 1 }
        effectApplier.apply(update.documentEffects)
        if update.invalidatesCandidates {
            coordinator?.invalidate()
        }
        if let request = update.candidateRequest {
            resolvedCoordinator().requestCandidates(for: request.tokens)
        }
    }

    private func handleHostDocumentChange() {
        guard documentEffectDepth == 0 else { return }
        guard !engine.composition.isEmpty else { return }
        resetComposition()
    }

    private func resetComposition() {
        apply(engine.resetComposition())
        refreshUI()
    }

    private func refreshCandidates() {
        candidateBar?.update(with: coordinator?.candidates ?? [])
    }

    private func resolvedCoordinator() -> ChineseInputCoordinator {
        if let coordinator {
            return coordinator
        }
        let coordinator = ChineseInputCoordinator { [bundle = Bundle.main] in
            try LexiconChineseInputPipeline(bundle: bundle)
        }
        coordinator.onChange = { [weak self] in self?.refreshCandidates() }
        self.coordinator = coordinator
        return coordinator
    }

    private func refreshUI() {
        if engine.mode == .zhuyin {
            refreshCandidates()
            let hasPending = engine.hasPendingTokens
            neutralToneButton?.alpha = hasPending ? 1 : 0
            neutralToneButton?.isUserInteractionEnabled = hasPending
            neutralToneButton?.accessibilityElementsHidden = !hasPending
            toneButton?.mapping = hasPending
                ? ZhuyinLayout.tones
                : FlickKeyMapping(["space"])
            toneButton?.showsPreview = hasPending
            if hasPending {
                toneButton?.setImage(nil, for: .normal)
                toneButton?.setTitle("調", for: .normal)
            } else {
                toneButton?.setTitle(nil, for: .normal)
                toneButton?.setImage(keyIcon(named: "space"), for: .normal)
                toneButton?.tintColor = .label
            }
        }

        for (key, button) in keyButtons {
            switch key {
            case let .letter(character):
                let title = engine.letterCase == .lowercase
                    ? String(character).lowercased()
                    : String(character).uppercased()
                button.setTitle(title, for: .normal)
            case .shift:
                let symbol = engine.letterCase == .capsLocked ? "capslock.fill" : "shift.fill"
                button.setTitle(nil, for: .normal)
                button.setImage(keyIcon(named: symbol), for: .normal)
                button.tintColor = engine.letterCase == .lowercase ? .label : .systemBlue
            case .delete:
                button.setTitle(nil, for: .normal)
                button.setImage(keyIcon(named: "delete.left"), for: .normal)
                button.tintColor = .label
            case .space:
                button.setTitle(nil, for: .normal)
                button.setImage(nil, for: .normal)
            case .return:
                if engine.mode == .zhuyin, engine.hasMarkedText {
                    button.setImage(nil, for: .normal)
                    button.setTitle("確定", for: .normal)
                    button.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
                } else {
                    button.setTitle(nil, for: .normal)
                    button.setImage(keyIcon(named: "arrow.turn.down.left"), for: .normal)
                    button.tintColor = .label
                }
            case .modeSwitch:
                button.setTitle(engine.mode == .zhuyin ? "ABC" : "中", for: .normal)
                button.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
            case let .tone(tone):
                button.setTitle(tone.symbol, for: .normal)
                button.titleLabel?.font = .systemFont(ofSize: 20, weight: .medium)
            case .nextKeyboard, .zhuyin:
                break
            }
        }
    }

    private func configureHeight() {
        let constraint = view.heightAnchor.constraint(equalToConstant: 260)
        constraint.priority = .defaultHigh
        constraint.isActive = true
        heightConstraint = constraint
    }

    private func updateKeyboardHeight() {
        let compact = traitCollection.verticalSizeClass == .compact
        switch engine.mode {
        case .zhuyin: heightConstraint?.constant = compact ? 220 : 260
        case .abc: heightConstraint?.constant = compact ? 190 : 230
        }
    }

    private func keyIcon(named name: String) -> UIImage? {
        let configuration = UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        return UIImage(systemName: name, withConfiguration: configuration)
    }

    private func accessibilityLabel(for key: KeyboardKey) -> String {
        switch key {
        case let .letter(character), let .zhuyin(character): String(character)
        case let .tone(tone): tone == .first ? "第一聲" : tone.symbol
        case .shift: "Shift"
        case .delete: "Delete"
        case .space: "Space"
        case .return: "Return"
        case .nextKeyboard: "Next keyboard"
        case .modeSwitch: engine.mode == .zhuyin ? "切換 ABC" : "切換中文"
        }
    }
}
