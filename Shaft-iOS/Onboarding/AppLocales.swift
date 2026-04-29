import Foundation

enum AppLocales {
    static let supportedTags: [String] = [
        "en", "zh-Hans", "zh-Hant", "ja", "ko", "ru", "tr",
    ]

    static func displayName(_ tag: String) -> String {
        switch tag {
        case "en": return "English"
        case "zh-Hans": return "简体中文"
        case "zh-Hant": return "繁體中文"
        case "ja": return "日本語"
        case "ko": return "한국어"
        case "ru": return "Русский"
        case "tr": return "Türkçe"
        default: return Locale(identifier: tag).localizedString(forIdentifier: tag) ?? tag
        }
    }

    struct Greeting: Equatable, Sendable {
        let tag: String
        let hero: String
        let subtitle: String
    }

    static let greetings: [Greeting] = [
        .init(tag: "en", hero: "Welcome", subtitle: "Choose your language"),
        .init(tag: "zh-Hans", hero: "欢迎", subtitle: "选择你的语言"),
        .init(tag: "zh-Hant", hero: "歡迎", subtitle: "選擇你的語言"),
        .init(tag: "ja", hero: "ようこそ", subtitle: "言語を選んでください"),
        .init(tag: "ko", hero: "환영합니다", subtitle: "언어를 선택하세요"),
        .init(tag: "ru", hero: "Добро пожаловать", subtitle: "Выберите язык"),
        .init(tag: "tr", hero: "Hoş geldiniz", subtitle: "Dilinizi seçin"),
    ]

    static func continueLabel(for tag: String) -> String {
        switch tag {
        case "en": return "Continue"
        case "zh-Hans": return "继续"
        case "zh-Hant": return "繼續"
        case "ja": return "続ける"
        case "ko": return "계속"
        case "ru": return "Продолжить"
        case "tr": return "Devam"
        default: return "Continue"
        }
    }

    static func matchSystemOrFallback() -> String {
        let pref = Locale.preferredLanguages.first ?? "en"
        if let exact = supportedTags.first(where: { $0.caseInsensitiveCompare(pref) == .orderedSame }) {
            return exact
        }
        let lang = Locale(identifier: pref).language.languageCode?.identifier ?? "en"
        if lang == "zh" {
            let region = Locale(identifier: pref).region?.identifier ?? ""
            if ["TW", "HK", "MO"].contains(region) { return "zh-Hant" }
            return "zh-Hans"
        }
        return supportedTags.first { $0.hasPrefix(lang) } ?? "en"
    }
}
