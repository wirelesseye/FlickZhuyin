import UIKit

final class KeyboardViewController: UIInputViewController {
    private var engine = KeyboardEngine()
    private var keyButtons: [(key: KeyboardKey, button: KeyboardButton)] = []
    private weak var nextKeyboardButton: KeyboardButton?
    private weak var candidateButton: UIButton?
    private weak var toneButton: FlickKeyButton?
    private var heightConstraint: NSLayoutConstraint?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGray5
        configureHeight()
        rebuildKeyboard()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        nextKeyboardButton?.isHidden = !needsInputModeSwitchKey
        updateKeyboardHeight()
    }

    private func rebuildKeyboard() {
        view.subviews.forEach { $0.removeFromSuperview() }
        keyButtons.removeAll(keepingCapacity: true)
        nextKeyboardButton = nil
        candidateButton = nil
        toneButton = nil

        switch engine.mode {
        case .zhuyin: buildZhuyinKeyboard()
        case .abc: buildABCKeyboard()
        }
        refreshUI()
        view.setNeedsLayout()
    }

    private func buildABCKeyboard() {
        let keyboardStack = pinnedVerticalStack(spacing: 8)
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
        let mainStack = pinnedVerticalStack(spacing: 6)

        let candidate = UIButton(type: .system)
        candidate.contentHorizontalAlignment = .leading
        candidate.titleLabel?.font = .systemFont(ofSize: 21, weight: .medium)
        candidate.setTitleColor(.label, for: .normal)
        candidate.backgroundColor = .secondarySystemBackground
        candidate.layer.cornerRadius = 8
        candidate.accessibilityLabel = "注音候選"
        candidate.addAction(UIAction { [weak self] _ in self?.handle(.commitCandidate) }, for: .touchUpInside)
        candidate.heightAnchor.constraint(equalToConstant: 38).isActive = true
        mainStack.addArrangedSubview(candidate)
        candidateButton = candidate

        let grid = UIStackView()
        grid.axis = .vertical
        grid.spacing = 6
        grid.distribution = .fillEqually
        for rowIndex in 0..<3 {
            let row = makeRow()
            for mapping in ZhuyinLayout.groups[(rowIndex * 3)..<(rowIndex * 3 + 3)] {
                let button = makeFlickButton(mapping: mapping) { [weak self] direction in
                    guard let symbol = mapping[direction], let character = symbol.first else { return }
                    self?.handle(.zhuyin(character))
                }
                row.addArrangedSubview(button)
            }
            grid.addArrangedSubview(row)
        }
        mainStack.addArrangedSubview(grid)

        let controls = makeRow()
        controls.heightAnchor.constraint(equalToConstant: 52).isActive = true
        controls.addArrangedSubview(makeLeftControls())
        controls.addArrangedSubview(makeToneControl())
        controls.addArrangedSubview(makeRightControls())
        mainStack.addArrangedSubview(controls)
    }

    private func makeLeftControls() -> UIStackView {
        let stack = makeRow()
        stack.addArrangedSubview(makeButton(for: .nextKeyboard))
        stack.addArrangedSubview(makeButton(for: .modeSwitch))
        return stack
    }

    private func makeToneControl() -> FlickKeyButton {
        let button = makeFlickButton(mapping: FlickKeyMapping(["space"])) { [weak self] direction in
            guard let self else { return }
            if self.engine.candidate == nil {
                guard direction == .center else { return }
                self.handle(.space)
            } else {
                self.handle(.tone(ZhuyinLayout.tone(for: direction)))
            }
        }
        button.titleLabel?.font = .systemFont(ofSize: 15)
        button.normalColor = .systemGray3
        button.accessibilityLabel = "空白或音調"
        toneButton = button
        return button
    }

    private func makeRightControls() -> UIStackView {
        let stack = makeRow()
        stack.addArrangedSubview(makeButton(for: .delete))
        stack.addArrangedSubview(makeButton(for: .return))
        return stack
    }

    private func pinnedVerticalStack(spacing: CGFloat) -> UIStackView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8)
        ])
        return stack
    }

    private func makeRow() -> UIStackView {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.distribution = .fillEqually
        return stack
    }

    private func makeControlRow() -> UIStackView {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
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
        button.normalColor = .systemBackground
        button.accessibilityLabel = mapping.center
        return button
    }

    private func makeButton(for key: KeyboardKey) -> KeyboardButton {
        let button = KeyboardButton(type: .system)
        button.accessibilityLabel = accessibilityLabel(for: key)
        button.normalColor = isLetter(key) ? .systemBackground : .systemGray3

        if key == .nextKeyboard {
            button.setImage(UIImage(systemName: "globe"), for: .normal)
            button.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
            nextKeyboardButton = button
        } else {
            button.addAction(UIAction { [weak self] _ in self?.handle(key) }, for: .touchUpInside)
        }
        keyButtons.append((key, button))
        return button
    }

    private func handle(_ key: KeyboardKey) {
        let oldMode = engine.mode
        apply(engine.command(for: key))
        if engine.mode != oldMode {
            rebuildKeyboard()
        } else {
            refreshUI()
        }
    }

    private func apply(_ command: KeyboardCommand) {
        switch command {
        case let .insertText(text): textDocumentProxy.insertText(text)
        case .deleteBackward: textDocumentProxy.deleteBackward()
        case .showInputModeList, .none: break
        }
    }

    private func refreshUI() {
        if engine.mode == .zhuyin {
            candidateButton?.setTitle(engine.candidate, for: .normal)
            candidateButton?.isHidden = engine.candidate == nil
            toneButton?.mapping = engine.candidate == nil
                ? FlickKeyMapping(["space"])
                : ZhuyinLayout.tones
            toneButton?.setTitle(engine.candidate == nil ? "space" : "調", for: .normal)
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
                button.setImage(UIImage(systemName: symbol), for: .normal)
                button.tintColor = engine.letterCase == .lowercase ? .label : .systemBlue
            case .delete:
                button.setImage(UIImage(systemName: "delete.left.fill"), for: .normal)
                button.tintColor = .label
            case .space:
                button.setTitle("space", for: .normal)
                button.titleLabel?.font = .systemFont(ofSize: 15)
            case .return:
                button.setTitle("return", for: .normal)
                button.titleLabel?.font = .systemFont(ofSize: 15)
            case .modeSwitch:
                button.setTitle(engine.mode == .zhuyin ? "ABC" : "中", for: .normal)
                button.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
            case .nextKeyboard, .zhuyin, .tone, .commitCandidate:
                break
            }
        }
    }

    private func configureHeight() {
        let constraint = view.heightAnchor.constraint(equalToConstant: 310)
        constraint.priority = .defaultHigh
        constraint.isActive = true
        heightConstraint = constraint
    }

    private func updateKeyboardHeight() {
        let compact = traitCollection.verticalSizeClass == .compact
        switch engine.mode {
        case .zhuyin: heightConstraint?.constant = compact ? 232 : 310
        case .abc: heightConstraint?.constant = compact ? 206 : 270
        }
    }

    private func isLetter(_ key: KeyboardKey) -> Bool {
        if case .letter = key { return true }
        return false
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
        case .commitCandidate: "確認候選"
        }
    }
}
