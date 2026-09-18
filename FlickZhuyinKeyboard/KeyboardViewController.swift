import UIKit

final class KeyboardViewController: UIInputViewController {
    private var engine = KeyboardEngine()
    private var keyButtons: [(key: KeyboardKey, button: KeyboardButton)] = []
    private weak var nextKeyboardButton: KeyboardButton?
    private var heightConstraint: NSLayoutConstraint?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGray5
        buildKeyboard()
        configureHeight()
        refreshKeyLabels()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        nextKeyboardButton?.isHidden = !needsInputModeSwitchKey
        updateKeyboardHeight()
    }

    private func buildKeyboard() {
        let keyboardStack = UIStackView()
        keyboardStack.axis = .vertical
        keyboardStack.spacing = 8
        keyboardStack.distribution = .fillEqually
        keyboardStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(keyboardStack)

        NSLayoutConstraint.activate([
            keyboardStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            keyboardStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
            keyboardStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            keyboardStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8)
        ])

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
        for key in KeyboardLayout.controlRow {
            let button = makeButton(for: key)
            controlStack.addArrangedSubview(button)
            switch key {
            case .nextKeyboard:
                button.widthAnchor.constraint(equalToConstant: 52).isActive = true
            case .return:
                button.widthAnchor.constraint(equalToConstant: 92).isActive = true
            default:
                break
            }
        }
        keyboardStack.addArrangedSubview(controlStack)
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
        switch engine.command(for: key) {
        case let .insertText(text):
            textDocumentProxy.insertText(text)
        case .deleteBackward:
            textDocumentProxy.deleteBackward()
        case .showInputModeList, .none:
            break
        }
        refreshKeyLabels()
    }

    private func refreshKeyLabels() {
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
            case .nextKeyboard:
                break
            }
        }
    }

    private func configureHeight() {
        let constraint = view.heightAnchor.constraint(equalToConstant: 270)
        constraint.priority = .defaultHigh
        constraint.isActive = true
        heightConstraint = constraint
        updateKeyboardHeight()
    }

    private func updateKeyboardHeight() {
        heightConstraint?.constant = traitCollection.verticalSizeClass == .compact ? 206 : 270
    }

    private func isLetter(_ key: KeyboardKey) -> Bool {
        if case .letter = key { return true }
        return false
    }

    private func accessibilityLabel(for key: KeyboardKey) -> String {
        switch key {
        case let .letter(character): String(character)
        case .shift: "Shift"
        case .delete: "Delete"
        case .space: "Space"
        case .return: "Return"
        case .nextKeyboard: "Next keyboard"
        }
    }
}
