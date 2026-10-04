import Foundation

enum AppLanguage: String, CaseIterable {
    case english = "en"
    case russian = "ru"

    static func resolve(_ value: String?) -> AppLanguage {
        value.flatMap(AppLanguage.init(rawValue:)) ?? .english
    }

    static var current: AppLanguage {
        get {
            let defaults = UserDefaults(suiteName: label)
            // Pick up menu changes in the already-running monitor as well.
            defaults?.synchronize()
            return resolve(defaults?.string(forKey: "interfaceLanguage"))
        }
        set {
            let defaults = UserDefaults(suiteName: label)
            defaults?.set(newValue.rawValue, forKey: "interfaceLanguage")
            // The monitor is a separate process using the same preference domain.
            defaults?.synchronize()
        }
    }
}

func localized(_ english: String, _ russian: String, language: AppLanguage = .current) -> String {
    language == .russian ? russian : english
}
