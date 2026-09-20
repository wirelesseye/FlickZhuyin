import UIKit

final class KeyboardViewController: UIInputViewController {
    private static let maximumCandidateCount = 30

    private var engine = KeyboardEngine()
    private var keyButtons: [(key: KeyboardKey, button: KeyboardButton)] = []
    private weak var nextKeyboardButton: KeyboardButton?
    private weak var candidateBar: CandidateBarView?
    private weak var expandedCandidatesView: ExpandedCandidateView?
    private weak var keyGrid: UIStackView?
    private weak var toneButton: FlickKeyButton?
    private weak var punctuationButton: FlickKeyButton?
    private var heightConstraint: NSLayoutConstraint?
    private var isCandidateListExpanded = false
    private var documentEffectDepth = 0
    private var showsDirectionalSymbols = KeyboardSettings.showsDirectionalSymbols

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

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let shows = KeyboardSettings.showsDirectionalSymbols
        guard shows != showsDirectionalSymbols else { return }
        showsDirectionalSymbols = shows
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
        refreshReturnKeyFace()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        handleHostDocumentChange()
        refreshReturnKeyFace()
    }

    override func handleInputModeList(from view: UIView, with event: UIEvent) {
        super.handleInputModeList(from: view, with: event)
    }

    private func rebuildKeyboard() {
        view.subviews.forEach { $0.removeFromSuperview() }
        keyButtons.removeAll(keepingCapacity: true)
        nextKeyboardButton = nil
        candidateBar = nil
        expandedCandidatesView = nil
        keyGrid = nil
        toneButton = nil
        punctuationButton = nil
        isCandidateListExpanded = false

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
        candidateBar.onToggleExpansion = { [weak self] in self?.toggleCandidateExpansion() }
        candidateBar.onVisibleCandidatesChanged = { [weak self] _ in
            self?.refreshExpandedCandidates()
        }
        candidateBar.heightAnchor.constraint(equalToConstant: 40).isActive = true
        mainStack.addArrangedSubview(candidateBar)
        self.candidateBar = candidateBar

        let leftColumn = makeColumn()
        leftColumn.addArrangedSubview(makeGridSpacer())
        leftColumn.addArrangedSubview(makeButton(for: .cursorLeft))
        leftColumn.addArrangedSubview(makeEmojiButton())
        leftColumn.addArrangedSubview(makeButton(for: .modeSwitch))

        let inputKeys = makeColumn()
        for rowIndex in 0..<3 {
            let row = makeRow()
            for mapping in ZhuyinLayout.groups[(rowIndex * 3)..<(rowIndex * 3 + 3)] {
                row.addArrangedSubview(makeZhuyinControl(mapping))
            }
            inputKeys.addArrangedSubview(row)
        }
        let toneRow = makeRow()
        toneRow.addArrangedSubview(makeToneControl())
        toneRow.addArrangedSubview(makeZhuyinControl(ZhuyinLayout.nasalFinals))
        let punctuationButton = makePunctuationControl()
        toneRow.addArrangedSubview(punctuationButton)
        self.punctuationButton = punctuationButton
        inputKeys.addArrangedSubview(toneRow)

        let editKeys = makeColumn()
        editKeys.addArrangedSubview(makeButton(for: .delete))
        editKeys.addArrangedSubview(makeButton(for: .cursorRight))

        let rightColumn = makeColumn()
        rightColumn.addArrangedSubview(editKeys)
        rightColumn.addArrangedSubview(makeButton(for: .return))

        let grid = UIStackView()
        grid.axis = .horizontal
        grid.spacing = 7
        grid.addArrangedSubview(leftColumn)
        grid.addArrangedSubview(inputKeys)
        grid.addArrangedSubview(rightColumn)
        keyGrid = grid

        NSLayoutConstraint.activate([
            rightColumn.widthAnchor.constraint(equalTo: leftColumn.widthAnchor),
            inputKeys.widthAnchor.constraint(
                equalTo: leftColumn.widthAnchor,
                multiplier: 3,
                constant: grid.spacing * 2
            )
        ])

        mainStack.addArrangedSubview(grid)

        let expandedCandidates = ExpandedCandidateView()
        expandedCandidates.onSelect = { [weak self] candidate in self?.select(candidate) }
        expandedCandidates.isHidden = true
        expandedCandidates.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(expandedCandidates)
        NSLayoutConstraint.activate([
            expandedCandidates.leadingAnchor.constraint(equalTo: grid.leadingAnchor),
            expandedCandidates.trailingAnchor.constraint(equalTo: grid.trailingAnchor),
            expandedCandidates.topAnchor.constraint(equalTo: grid.topAnchor),
            expandedCandidates.bottomAnchor.constraint(equalTo: grid.bottomAnchor)
        ])
        expandedCandidatesView = expandedCandidates
    }

    private func makeGridSpacer() -> UIView {
        let spacer = UIView()
        spacer.isUserInteractionEnabled = false
        spacer.backgroundColor = .clear
        spacer.accessibilityElementsHidden = true
        return spacer
    }

    private func makeEmojiButton() -> KeyboardButton {
        // TODO: picks up custom emoji picker in the future; placeholder for now.
        let button = KeyboardButton(type: .system)
        button.setImage(keyIcon(named: "face.smiling"), for: .normal)
        button.tintColor = .label
        button.normalColor = KeyboardButton.standardKeyColor
        button.accessibilityLabel = "表情符號"
        return button
    }

    private func makeToneControl() -> FlickKeyButton {
        let button = makeFlickButton(mapping: FlickKeyMapping(["space"])) { [weak self] direction in
            guard let self else { return }
            if self.engine.hasActiveTokens {
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

    private func makeZhuyinControl(_ mapping: FlickKeyMapping) -> FlickKeyButton {
        let button = makeFlickButton(mapping: mapping) { [weak self] direction in
            guard let symbol = mapping[direction], let character = symbol.first else { return }
            self?.handle(.zhuyin(character))
        }
        if showsDirectionalSymbols {
            button.directionalFaceStyle = .zhuyin
            button.directionalFace = mapping
        }
        return button
    }

    private func makePunctuationControl() -> FlickKeyButton {
        let mapping = ZhuyinLayout.punctuation
        let button = makeFlickButton(mapping: mapping) { [weak self] direction in
            guard let self else { return }
            if self.engine.hasActiveTokens {
                guard direction == .center else { return }
                self.handle(.tone(.neutral))
            } else {
                guard let symbol = mapping[direction] else { return }
                self.insertPunctuation(symbol)
            }
        }
        applyPunctuationFace(button, mapping: mapping)
        button.accessibilityLabel = mappingSymbols(mapping)
        return button
    }

    private func applyPunctuationFace(_ button: FlickKeyButton, mapping: FlickKeyMapping) {
        guard !showsDirectionalSymbols else {
            button.directionalFace = mapping
            return
        }
        button.directionalFace = nil
        button.setAttributedTitle(
            NSAttributedString(
                string: mapping.center,
                attributes: [
                    .font: UIFont.systemFont(ofSize: 18),
                    .foregroundColor: UIColor.label
                ]
            ),
            for: .normal
        )
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.7
    }

    private func mappingSymbols(_ mapping: FlickKeyMapping) -> String {
        FlickDirection.allCases.compactMap { mapping[$0] }.joined()
    }

    private func insertPunctuation(_ symbol: String) {
        if engine.hasMarkedText {
            apply(engine.update(for: .return))
        }
        apply(KeyboardUpdate(documentEffects: [.insertText(symbol)]))
        refreshUI()
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

    private func makeColumn() -> UIStackView {
        let stack = UIStackView()
        stack.axis = .vertical
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

        if case .letter = key {
            button.titleLabel?.font = .systemFont(ofSize: 24, weight: .regular)
        }

        if key == .nextKeyboard {
            button.setImage(UIImage(systemName: "globe"), for: .normal)
            button.addAction(
                UIAction { [weak self] _ in self?.prepareForInputModeSwitch() },
                for: .touchUpInside
            )
            button.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
            nextKeyboardButton = button
        } else if key == .delete || key == .cursorLeft || key == .cursorRight {
            installKeyRepeat(for: key, on: button)
        } else {
            button.addAction(UIAction { [weak self] _ in self?.handle(key) }, for: .touchUpInside)
        }
        keyButtons.append((key, button))
        return button
    }

    private func installKeyRepeat(for key: KeyboardKey, on button: KeyboardButton) {
        let repeater = KeyRepeater { [weak self] in self?.handle(key) }
        button.addAction(UIAction { _ in repeater.begin() }, for: .touchDown)
        button.addAction(
            UIAction { _ in repeater.end() },
            for: [.touchUpOutside, .touchCancel, .touchDragExit]
        )
        button.addAction(UIAction { [weak self] _ in
            let didRepeat = repeater.consumeRepeat()
            repeater.end()
            guard !didRepeat else { return }
            self?.handle(key)
        }, for: .touchUpInside)
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
        setCandidateListExpanded(false)
        apply(
            engine.selectCandidate(
                candidate,
                autoCommit: KeyboardSettings.autoCommitComposition
            )
        )
        refreshUI()
    }

    private func toggleCandidateExpansion() {
        setCandidateListExpanded(!isCandidateListExpanded)
    }

    private func setCandidateListExpanded(_ expanded: Bool) {
        guard isCandidateListExpanded != expanded else { return }
        isCandidateListExpanded = expanded
        expandedCandidatesView?.isHidden = !expanded
        keyGrid?.isUserInteractionEnabled = !expanded
        keyGrid?.accessibilityElementsHidden = expanded
        if expanded {
            refreshExpandedCandidates()
            view.layoutIfNeeded()
            expandedCandidatesView?.prepareForEntrance()
            candidateBar?.setExpanded(true)
            expandedCandidatesView?.animateEntrance()
        } else {
            expandedCandidatesView?.resetEntranceState()
            candidateBar?.setExpanded(false)
        }
        UIView.animate(withDuration: CandidateBarView.animationDuration) {
            self.keyGrid?.alpha = expanded ? 0 : 1
        }
        view.setNeedsLayout()
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
        let candidates = coordinator?.candidates ?? []
        candidateBar?.update(with: candidates)
        refreshExpandedCandidates()
        if candidates.isEmpty {
            setCandidateListExpanded(false)
        }
    }

    private func refreshExpandedCandidates() {
        guard isCandidateListExpanded else { return }
        let candidates = coordinator?.candidates ?? []
        let visibleCount = candidateBar?.visibleCandidateCount ?? 0
        let start = min(visibleCount, candidates.count)
        expandedCandidatesView?.update(with: Array(candidates.dropFirst(start)))
    }

    private func resolvedCoordinator() -> ChineseInputCoordinator {
        if let coordinator {
            return coordinator
        }
        let coordinator = ChineseInputCoordinator { [bundle = Bundle.main] in
            try LexiconChineseInputPipeline(
                bundle: bundle,
                decoder: Decoder(
                    configuration: DecoderConfiguration(
                        maximumCandidates: Self.maximumCandidateCount
                    )
                )
            )
        }
        coordinator.onChange = { [weak self] in self?.refreshCandidates() }
        self.coordinator = coordinator
        return coordinator
    }

    private func refreshUI() {
        if engine.mode == .zhuyin {
            refreshCandidates()
            let hasPending = engine.hasActiveTokens
            if hasPending {
                punctuationButton?.mapping = FlickKeyMapping([MandarinTone.neutral.symbol])
                punctuationButton?.directionalFace = nil
                punctuationButton?.showsPreview = false
                punctuationButton?.setAttributedTitle(
                    ToneSymbolStyle.attributedText(
                        for: MandarinTone.neutral.symbol,
                        fontSize: ToneSymbolStyle.keyFontSize
                    ),
                    for: .normal
                )
                punctuationButton?.accessibilityLabel = "輕聲"
            } else {
                punctuationButton?.mapping = ZhuyinLayout.punctuation
                if let punctuationButton {
                    applyPunctuationFace(punctuationButton, mapping: ZhuyinLayout.punctuation)
                }
                punctuationButton?.showsPreview = true
                punctuationButton?.accessibilityLabel = mappingSymbols(ZhuyinLayout.punctuation)
            }
            toneButton?.mapping = hasPending
                ? ZhuyinLayout.tones
                : FlickKeyMapping(["space"])
            toneButton?.showsPreview = hasPending
            if hasPending {
                toneButton?.setImage(nil, for: .normal)
                if showsDirectionalSymbols {
                    toneButton?.directionalFaceStyle = .tone
                    toneButton?.directionalFace = ZhuyinLayout.tones
                } else {
                    toneButton?.directionalFace = nil
                    toneButton?.setAttributedTitle(
                        ToneSymbolStyle.attributedText(
                            for: MandarinTone.first.symbol,
                            fontSize: ToneSymbolStyle.keyFontSize
                        ),
                        for: .normal
                    )
                }
            } else {
                toneButton?.directionalFace = nil
                toneButton?.setAttributedTitle(nil, for: .normal)
                toneButton?.setTitle(nil, for: .normal)
                toneButton?.setImage(keyIcon(named: "space"), for: .normal)
                toneButton?.tintColor = .label
            }
        }

        UIView.performWithoutAnimation {
            for (key, button) in keyButtons {
                switch key {
                case let .letter(character):
                    let title = engine.letterCase == .lowercase
                        ? String(character).lowercased()
                        : String(character).uppercased()
                    button.setTitle(title, for: .normal)
                case .shift:
                    let symbol: String
                    switch engine.letterCase {
                    case .lowercase: symbol = "shift"
                    case .shifted: symbol = "shift.fill"
                    case .capsLocked: symbol = "capslock.fill"
                    }
                    button.setTitle(nil, for: .normal)
                    button.setImage(keyIcon(named: symbol), for: .normal)
                    button.tintColor = .label
                case .delete:
                    button.setTitle(nil, for: .normal)
                    button.setImage(keyIcon(named: "delete.left"), for: .normal)
                    button.tintColor = .label
                case .cursorLeft, .cursorRight:
                    button.setTitle(nil, for: .normal)
                    let symbol = key == .cursorLeft ? "arrowtriangle.left.fill" : "arrowtriangle.right.fill"
                    button.setImage(keyIcon(named: symbol, pointSize: 12), for: .normal)
                    button.tintColor = .label
                case .space:
                    button.setTitle(nil, for: .normal)
                    button.setImage(nil, for: .normal)
                case .return:
                    updateReturnKeyFace(button)
                case .modeSwitch:
                    button.setTitle(engine.mode == .zhuyin ? "ABC" : "中", for: .normal)
                    button.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
                case let .tone(tone):
                    button.setAttributedTitle(
                        ToneSymbolStyle.attributedText(
                            for: tone.symbol,
                            fontSize: ToneSymbolStyle.keyFontSize
                        ),
                        for: .normal
                    )
                case .nextKeyboard, .zhuyin:
                    break
                }
            }
            view.layoutIfNeeded()
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

    private func refreshReturnKeyFace() {
        for (key, button) in keyButtons where key == .return {
            updateReturnKeyFace(button)
        }
    }

    private func updateReturnKeyFace(_ button: KeyboardButton) {
        let type = textDocumentProxy.returnKeyType
        if engine.mode == .zhuyin, engine.hasMarkedText {
            setReturnTitle("確定", on: button)
            applyReturnKeyAccent(false, on: button)
            return
        }
        if let iconName = returnKeyIconName(for: type) {
            setReturnIcon(iconName, on: button)
        } else if let title = returnKeyTitle(for: type) {
            setReturnTitle(title, on: button)
        } else {
            setReturnIcon("arrow.turn.down.left", on: button)
        }
        applyReturnKeyAccent(type != nil && type != .default, on: button)
    }

    private func applyReturnKeyAccent(_ isAccented: Bool, on button: KeyboardButton) {
        button.normalColor = isAccented ? .systemBlue : KeyboardButton.standardKeyColor
        let foreground: UIColor = isAccented ? .white : .label
        button.setTitleColor(foreground, for: .normal)
        button.tintColor = foreground
    }

    private func setReturnIcon(_ name: String, on button: KeyboardButton) {
        button.setTitle(nil, for: .normal)
        button.setImage(keyIcon(named: name), for: .normal)
        button.tintColor = .label
    }

    private func setReturnTitle(_ title: String, on button: KeyboardButton) {
        button.setImage(nil, for: .normal)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.7
    }

    private func returnKeyIconName(for type: UIReturnKeyType?) -> String? {
        switch type {
        case .default: "arrow.turn.down.left"
        case .go: "arrow.forward"
        case .next, .continue: "chevron.forward"
        case .route: "arrow.triangle.turn.up.right.diamond"
        case .search: "magnifyingglass"
        case .send: "paperplane.fill"
        case .done: "checkmark"
        case .emergencyCall: "phone.fill"
        default: nil
        }
    }

    private func returnKeyTitle(for type: UIReturnKeyType?) -> String? {
        switch type {
        case .join: "加入"
        case .google: "Google"
        case .yahoo: "Yahoo"
        default: nil
        }
    }

    private func keyIcon(named name: String, pointSize: CGFloat = 16) -> UIImage? {
        let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        return UIImage(systemName: name, withConfiguration: configuration)
    }

    private func accessibilityLabel(for key: KeyboardKey) -> String {
        switch key {
        case let .letter(character), let .zhuyin(character): String(character)
        case let .tone(tone): tone == .first ? "第一聲" : tone.symbol
        case .shift: "Shift"
        case .delete: "Delete"
        case .cursorLeft: "向左移動"
        case .cursorRight: "向右移動"
        case .space: "Space"
        case .return: "Return"
        case .nextKeyboard: "Next keyboard"
        case .modeSwitch: engine.mode == .zhuyin ? "切換 ABC" : "切換中文"
        }
    }
}
