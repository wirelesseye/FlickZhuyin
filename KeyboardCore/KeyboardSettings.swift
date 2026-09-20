import Foundation

enum KeyboardSettings {
    static let appGroupIdentifier = "group.com.wirelesseye.FlickZhuyin"
    static let showsDirectionalSymbolsKey = "showsDirectionalSymbols"
    static let autoCommitCompositionKey = "autoCommitComposition"

    static let sharedDefaults = UserDefaults(suiteName: appGroupIdentifier)

    static var showsDirectionalSymbols: Bool {
        get { boolValue(for: showsDirectionalSymbolsKey) }
        set { sharedDefaults?.set(newValue, forKey: showsDirectionalSymbolsKey) }
    }

    static var autoCommitComposition: Bool {
        get { boolValue(for: autoCommitCompositionKey) }
        set { sharedDefaults?.set(newValue, forKey: autoCommitCompositionKey) }
    }

    private static func boolValue(for key: String) -> Bool {
        sharedDefaults?.object(forKey: key) as? Bool ?? true
    }
}
