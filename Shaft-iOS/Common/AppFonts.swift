import SwiftUI
import CoreText

/// Montserrat faces bundled from upstream `res/font/` (V3 display typeface).
/// Registered at runtime via CTFontManager because the project uses a
/// generated Info.plist (no `UIAppFonts` array to declare them in).
///
/// Upstream V3 applies Montserrat through styles plus `textStyle="bold"`,
/// which Android renders as a synthetic-bold of the named face. The closest
/// single-face match: `textMontserratSemiBold` + bold → Montserrat-Bold,
/// `textMontserratMedium` (no bold flag) → Montserrat-Medium.
enum AppFonts {
    static func register() {
        for resource in ["montserrat_regular", "montserrat_medium", "montserrat_semi_bold", "montserrat_bold", "montserrat_extra_bold"] {
            guard let url = Bundle.main.url(forResource: resource, withExtension: "ttf") else {
                continue
            }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

extension Font {
    static func montserratBold(_ size: CGFloat) -> Font {
        .custom("Montserrat-Bold", size: size)
    }

    static func montserratMedium(_ size: CGFloat) -> Font {
        .custom("Montserrat-Medium", size: size)
    }

    static func montserratSemiBold(_ size: CGFloat) -> Font {
        .custom("Montserrat-SemiBold", size: size)
    }
}
