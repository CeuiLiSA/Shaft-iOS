import Foundation

enum LocalizedKey: String, CaseIterable, Sendable {
    // Login
    case loginTitle
    case loginSubtitle
    case loginAction
    case loginProvisional

    // Bottom tabs
    case tabRecommend
    case tabDiscover
    case tabWhatsNew

    // Recommend tab
    case homeNavTitle      // string_207 — toolbar title for the Recommend tab
    case subRecommendedWorks
    case subPopularTags
    case rankingTodayTitle

    // Account / actions
    case account
    case actionDone
    case actionLogOut
    case actionRefresh
    case actionRetry

    // Token sheet
    case tokenTitle
    case tokenAccess
    case tokenExpiresFormat   // "%@" → expiry time

    // Common
    case nothingHere
}
