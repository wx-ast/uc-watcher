import Foundation

enum AppLanguage: String, CaseIterable {
    case english = "en"
    case russian = "ru"

    static func resolve(_ value: String?) -> AppLanguage {
        value.flatMap(AppLanguage.init(rawValue:)) ?? .english
    }

    static var preferences: UserDefaults {
        // Using the application's own bundle ID as a suite name returns nil.
        // App and monitor processes inside the bundle share standard defaults.
        if Bundle.main.bundleIdentifier == label { return .standard }
        // The standalone CLI still needs to read the application's domain.
        guard let defaults = UserDefaults(suiteName: label) else {
            preconditionFailure("Cannot access UC Watchdog language preferences")
        }
        return defaults
    }

    static var current: AppLanguage {
        get {
            let defaults = preferences
            // Pick up menu changes in the already-running monitor as well.
            defaults.synchronize()
            return resolve(defaults.string(forKey: "interfaceLanguage"))
        }
        set {
            let defaults = preferences
            defaults.set(newValue.rawValue, forKey: "interfaceLanguage")
            // The monitor is a separate process using the same preference domain.
            defaults.synchronize()
        }
    }
}

func localized(_ english: String, _ russian: String, language: AppLanguage = .current) -> String {
    language == .russian ? russian : english
}
