import SwiftUI

@MainActor
@Observable
final class AuthViewModel {
    var token: PixivOAuthResponse?
    var isLoading = false
    var errorMessage: String?

    @ObservationIgnored private let client: PixivOAuthClient
    @ObservationIgnored private let loginSession: PixivLoginSession

    init() {
        let c = PixivOAuthClient(config: .pixivAndroid)
        self.client = c
        self.loginSession = PixivLoginSession(client: c)
        self.token = KeychainTokenStore.shared.load()
    }

    func login(provisional: Bool = false) async {
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil

        let result = await loginSession.login(provisional: provisional)
        switch result {
        case .success(let response, _):
            do {
                try KeychainTokenStore.shared.save(response)
                token = response
            } catch {
                errorMessage = "Failed to save token: \(error.localizedDescription)"
            }
        case .failure(let f):
            if case .userCancelled = f { return }
            errorMessage = f.message
        }
    }

    func refresh() async {
        guard let current = token else { return }
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil

        let result = await PixivOAuthClient(config: .pixivAndroid).refreshToken(current.refreshToken)
        switch result {
        case .success(let response, _):
            try? KeychainTokenStore.shared.save(response)
            token = response
        case .failure(let f):
            errorMessage = f.message
        }
    }

    func logout() {
        KeychainTokenStore.shared.clear()
        token = nil
    }
}

struct LoginView: View {
    @Bindable var auth: AuthViewModel

    var body: some View {
        ZStack {
            TunnelBackgroundView()
                .ignoresSafeArea()
            LoginScrimGradient()
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                VStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 56))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 6, y: 2)
                    Text("Sign in to Pixiv")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 6, y: 2)
                    Text("OAuth 2.0 with PKCE")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                        .shadow(color: .black.opacity(0.6), radius: 4, y: 1)
                }

                Spacer()

                VStack(spacing: 12) {
                    Button {
                        Task { await auth.login(provisional: false) }
                    } label: {
                        Text("Log in")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .foregroundStyle(.black)
                            .background(.white, in: .rect(cornerRadius: 14))
                    }
                    .disabled(auth.isLoading)

                    Button {
                        Task { await auth.login(provisional: true) }
                    } label: {
                        Text("Try without account")
                            .font(.system(size: 17, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .foregroundStyle(.white)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(.white.opacity(0.45), lineWidth: 1)
                            )
                    }
                    .disabled(auth.isLoading)
                }
                .padding(.horizontal, 30)

                if auth.isLoading {
                    ProgressView().tint(.white)
                }
                if let msg = auth.errorMessage {
                    Text(msg)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Spacer().frame(height: 24)
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct LoggedInView: View {
    @Bindable var auth: AuthViewModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)

            if let user = auth.token?.user {
                Text(user.name).font(.title2.bold())
                Text("@\(user.account)").foregroundStyle(.secondary)
                Text("ID \(user.id)").font(.footnote).foregroundStyle(.tertiary)
            }

            if let token = auth.token {
                GroupBox("Token") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Access").font(.caption.bold())
                        Text(token.accessToken).font(.caption.monospaced()).lineLimit(2).truncationMode(.middle)
                        Text("Expires \(token.expiresAt.formatted(date: .omitted, time: .shortened))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal)
            }

            HStack {
                Button("Refresh") { Task { await auth.refresh() } }
                    .buttonStyle(.bordered)
                Button("Log out", role: .destructive) { auth.logout() }
                    .buttonStyle(.bordered)
            }
            .disabled(auth.isLoading)

            if let msg = auth.errorMessage {
                Text(msg).font(.footnote).foregroundStyle(.red)
            }
        }
        .padding()
    }
}
