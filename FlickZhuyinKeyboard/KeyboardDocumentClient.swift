import Foundation
import UIKit

@MainActor
protocol KeyboardDocumentClient: AnyObject {
    func setMarkedText(_ text: String, selectedRange: NSRange)
    func unmarkText()
    func insertText(_ text: String)
    func deleteBackward()
    func moveCursor(by offset: Int)
}

@MainActor
final class DocumentEffectApplier {
    private let client: any KeyboardDocumentClient

    init(client: any KeyboardDocumentClient) {
        self.client = client
    }

    func apply(_ effects: [DocumentEffect]) {
        for effect in effects {
            switch effect {
            case let .setMarkedText(text, caret):
                client.setMarkedText(text, selectedRange: NSRange(location: caret, length: 0))
            case .unmarkText:
                client.unmarkText()
            case let .insertText(text):
                client.insertText(text)
            case .deleteBackward:
                client.deleteBackward()
            case let .moveCursor(offset):
                client.moveCursor(by: offset)
            case .showInputModeList:
                break
            }
        }
    }
}

@MainActor
final class TextDocumentProxyClient: KeyboardDocumentClient {
    private let proxy: UITextDocumentProxy

    init(proxy: UITextDocumentProxy) {
        self.proxy = proxy
    }

    func setMarkedText(_ text: String, selectedRange: NSRange) {
        proxy.setMarkedText(text, selectedRange: selectedRange)
    }

    func unmarkText() {
        proxy.unmarkText()
    }

    func insertText(_ text: String) {
        proxy.insertText(text)
    }

    func deleteBackward() {
        proxy.deleteBackward()
    }

    func moveCursor(by offset: Int) {
        proxy.adjustTextPosition(byCharacterOffset: offset)
    }
}
