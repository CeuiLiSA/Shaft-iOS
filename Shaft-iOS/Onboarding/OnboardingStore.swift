import Foundation
import Observation

@MainActor
@Observable
final class OnboardingStore {
    private let defaults = UserDefaults.standard
    private let configuredKey = "app_locale_configured"
    private let chosenTagKey = "app_locale_chosen_tag"
    private let appleLanguagesKey = "AppleLanguages"

    var hasUserConfigured: Bool {
        get { defaults.bool(forKey: configuredKey) }
        set { defaults.set(newValue, forKey: configuredKey) }
    }

    var chosenTag: String? {
        get { defaults.string(forKey: chosenTagKey) }
        set { defaults.set(newValue, forKey: chosenTagKey) }
    }

    func apply(tag: String) {
        chosenTag = tag
        hasUserConfigured = true
        defaults.set([tag], forKey: appleLanguagesKey)
    }
}
