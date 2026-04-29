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

    /// The active language tag — chosen tag, or system fallback.
    var activeTag: String {
        chosenTag ?? AppLocales.matchSystemOrFallback()
    }

    /// Locale derived from the active tag, for `.environment(\.locale, …)` so
    /// SwiftUI's built-in formatters (dates, numbers) match the chosen language.
    var currentLocale: Locale {
        Locale(identifier: activeTag)
    }

    /// Translate a UI key into the active language. Falls back to English, then
    /// the raw key.
    func t(_ key: LocalizedKey) -> String {
        LocalizedStrings.string(for: key, tag: activeTag)
    }

    /// Format a localized template that takes one `%@` placeholder.
    func t(_ key: LocalizedKey, _ arg: String) -> String {
        String(format: t(key), arg)
    }

    func apply(tag: String) {
        chosenTag = tag
        hasUserConfigured = true
        // Sets the system-level preferred-language list. Takes effect on next
        // cold launch for OS-localized UI (keyboard, system sheets); the in-app
        // text switches immediately because views read `t(_:)` against
        // `chosenTag` and `currentLocale` is published via @Observable.
        defaults.set([tag], forKey: appleLanguagesKey)
    }
}
