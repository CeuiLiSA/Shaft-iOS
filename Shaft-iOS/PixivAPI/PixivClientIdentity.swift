import Foundation

/// Single source of truth for the iOS-client identity Shaft presents to pixiv —
/// the API request headers plus the image-CDN and OAuth User-Agent. 1:1 with
/// upstream Pixiv-Shaft's `HeaderInterceptor` / `LanguageHelper`: app-version is
/// pinned to a real PixivIOSApp release (8.6.10, captured from the official
/// client) and `app-accept-language` follows the app/device language.
///
/// Unlike upstream (an Android app that must hard-code an iOS fingerprint), we
/// run on real iOS, so the OS version and hardware model are the device's actual
/// values — a more authentic client identity than a hard-coded capture.
enum PixivClientIdentity {
    /// Pixiv iOS app version we impersonate — bump in this ONE place. Must match a
    /// real PixivIOSApp release or the API starts rejecting requests.
    static let appVersion = "8.6.10"

    /// Real device iOS version, e.g. "18.5" (patch dropped when 0). Captured once;
    /// constant for the process lifetime. `ProcessInfo` avoids any UIKit / main-
    /// actor dependency so this is safe to read from the networking actor.
    static let osVersion: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion == 0
            ? "\(v.majorVersion).\(v.minorVersion)"
            : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }()

    /// Real hardware model identifier, e.g. "iPhone16,2" — not `UIDevice.model`'s
    /// generic "iPhone". The simulator reports the model it's simulating.
    static let deviceModel: String = {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return sim
        }
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        guard size > 0 else { return "iPhone" }
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        return String(cString: machine)
    }()

    /// `PixivIOSApp/8.6.10 (iOS 18.5; iPhone16,2)` — the one User-Agent for API,
    /// image-CDN and OAuth requests (upstream unified them onto this string).
    static let userAgent = "PixivIOSApp/\(appVersion) (iOS \(osVersion); \(deviceModel))"

    /// `accept-language` — locale-region plus the usual quality-weighted fallbacks.
    static func acceptLanguage() -> String {
        let pref = Locale.preferredLanguages.first ?? "en"
        let lang = Locale(identifier: pref).language.languageCode?.identifier ?? "en"
        let region = Locale(identifier: pref).region?.identifier ?? "US"
        return "\(lang)-\(region.lowercased()),\(lang);q=0.9,en-us;q=0.8,en;q=0.7"
    }

    /// `app-accept-language` — the pixiv-iOS form: `zh-hans` / `zh-hant` for
    /// Chinese, otherwise the bare ISO-639-1 code. 1:1 with upstream
    /// `LanguageHelper.getRequestHeaderAppAcceptLanguageFromAppLanguage()`.
    static func appAcceptLanguage() -> String {
        let pref = Locale.preferredLanguages.first ?? "en"
        let locale = Locale(identifier: pref)
        let lang = locale.language.languageCode?.identifier ?? "en"
        guard lang == "zh" else { return lang.isEmpty ? "en" : lang }
        let region = locale.region?.identifier.uppercased() ?? ""
        let script = locale.language.script?.identifier ?? ""
        let traditional = script == "Hant" || region == "TW" || region == "HK" || region == "MO"
        return traditional ? "zh-hant" : "zh-hans"
    }
}
