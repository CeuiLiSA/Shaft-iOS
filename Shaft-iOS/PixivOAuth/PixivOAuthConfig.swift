import Foundation

struct PixivOAuthConfig: Sendable, Equatable {
    let clientId: String
    let clientSecret: String
    let redirectUri: String
    let loginUrl: String
    let provisionalAccountUrl: String
    let clientParam: String
    let tokenEndpointPath: String
    let callbackScheme: String
    let oauthBaseUrl: String

    init(
        clientId: String,
        clientSecret: String,
        redirectUri: String,
        loginUrl: String,
        provisionalAccountUrl: String? = nil,
        clientParam: String,
        tokenEndpointPath: String,
        callbackScheme: String,
        oauthBaseUrl: String = "https://oauth.secure.pixiv.net/"
    ) {
        precondition(!clientId.isEmpty, "clientId must not be blank")
        precondition(!clientSecret.isEmpty, "clientSecret must not be blank")
        precondition(redirectUri.hasPrefix("https://"), "redirectUri must use HTTPS")
        precondition(loginUrl.hasPrefix("https://"), "loginUrl must use HTTPS")
        precondition(!loginUrl.contains("?"), "loginUrl must not contain query params")
        precondition(!clientParam.isEmpty, "clientParam must not be blank")
        precondition(!tokenEndpointPath.isEmpty, "tokenEndpointPath must not be blank")
        precondition(!tokenEndpointPath.hasPrefix("/"), "tokenEndpointPath must be relative")
        precondition(!callbackScheme.isEmpty, "callbackScheme must not be blank")
        precondition(!callbackScheme.contains("://"), "callbackScheme must be scheme only")
        precondition(oauthBaseUrl.hasSuffix("/"), "oauthBaseUrl must end with '/'")

        self.clientId = clientId
        self.clientSecret = clientSecret
        self.redirectUri = redirectUri
        self.loginUrl = loginUrl
        self.provisionalAccountUrl = provisionalAccountUrl
            ?? loginUrl.replacingOccurrences(of: "/login", with: "/provisional-accounts/create")
        self.clientParam = clientParam
        self.tokenEndpointPath = tokenEndpointPath
        self.callbackScheme = callbackScheme
        self.oauthBaseUrl = oauthBaseUrl
    }

    static let pixivAndroid = PixivOAuthConfig(
        clientId: "MOBrBDS8blbauoSck0ZfDbtuzpyT",
        clientSecret: "lsACyCD94FhDUtGTXi3QzcFE2uU1hqtDaKeqrdwj",
        redirectUri: "https://app-api.pixiv.net/web/v1/users/auth/pixiv/callback",
        loginUrl: "https://app-api.pixiv.net/web/v1/login",
        clientParam: "pixiv-android",
        tokenEndpointPath: "auth/token",
        callbackScheme: "pixiv"
    )

    static let pixivComic = PixivOAuthConfig(
        clientId: "d9GW1FKXS7iAsrZRh5qp4P7wDjeG",
        clientSecret: "RaMhKgt3LEIVwnhmDkJP1pUrwI2A1vzgHyEJPiCd",
        redirectUri: "https://comic-api.pixiv.net/web/v1/users/auth/pixiv/callback",
        loginUrl: "https://comic-api.pixiv.net/web/v1/login",
        clientParam: "comic_ios",
        tokenEndpointPath: "v2/auth/token",
        callbackScheme: "pixiv-manga"
    )
}
