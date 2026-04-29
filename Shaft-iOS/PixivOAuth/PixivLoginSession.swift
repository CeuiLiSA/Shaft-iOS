import Foundation
import UIKit
import AuthenticationServices

@MainActor
final class PixivLoginSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let client: PixivOAuthClient
    private var session: ASWebAuthenticationSession?

    init(client: PixivOAuthClient) {
        self.client = client
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    func login(provisional: Bool = false) async -> PixivOAuthResult {
        let authURL = provisional ? client.startProvisionalAccount() : client.startLogin()
        let scheme = client.config.callbackScheme

        let callbackURL: URL
        do {
            callbackURL = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                let s = ASWebAuthenticationSession(url: authURL, callbackURLScheme: scheme) { url, error in
                    if let error { cont.resume(throwing: error); return }
                    if let url { cont.resume(returning: url); return }
                    cont.resume(throwing: ASWebAuthenticationSessionError(.canceledLogin))
                }
                s.presentationContextProvider = self
                s.prefersEphemeralWebBrowserSession = false
                self.session = s
                if !s.start() {
                    cont.resume(throwing: ASWebAuthenticationSessionError(.canceledLogin))
                }
            }
        } catch let e as ASWebAuthenticationSessionError where e.code == .canceledLogin {
            return .failure(.userCancelled)
        } catch {
            return .failure(.networkError(message: error.localizedDescription, underlying: error))
        }

        return await client.handleCallback(callbackURL)
    }
}
