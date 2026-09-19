import Foundation

enum KeyboardSettings {
    static let appGroupIdentifier = "group.com.wirelesseye.FlickZhuyin"
    static let showsDirectionalSymbolsKey = "showsDirectionalSymbols"

    static let sharedDefaults = UserDefaults(suiteName: appGroupIdentifier)

    static var showsDirectionalSymbols: Bool {
        get {
            guard let value = sharedDefaults?.object(forKey: showsDirectionalSymbolsKey) as? Bool else {
                return true
            }
            return value
        }
        set {
            sharedDefaults?.set(newValue, forKey: showsDirectionalSymbolsKey)
        }
    }
}
