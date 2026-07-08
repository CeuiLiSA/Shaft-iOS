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
        // Bind the anonymous shaft-api-v2 client_id to the pixiv uid (cached/idempotent).
        if let uid = token?.user?.id {
            Task { await ShaftEventReporter.shared.bindUid(uid) }
        }
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
                if let uid = response.user?.id {
                    Task { await ShaftEventReporter.shared.bindUid(uid) }
                }
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

/// 1:1 port of upstream `page_login.xml` + `FragmentLogin`'s login page: the
/// tunnel keeps running behind a scrim; everything sits in a bottom-pinned
/// column — two white pill buttons (login / register), the email-restore
/// entry, then the terms checkbox row. Both buttons gate on the checkbox
/// (`read_agreement` alert) and show the proxy-hint dialog before starting
/// OAuth, exactly like `checkAndNext` → `openProxyHint`.
struct LoginView: View {
    @Bindable var auth: AuthViewModel
    @Environment(OnboardingStore.self) private var l10n
    @Environment(\.openURL) private var openURL

    @State private var termsAccepted = false
    @State private var showProxyHint = false
    @State private var showReadAgreement = false
    @State private var showRestoreUnavailable = false
    @State private var pendingProvisional = false

    var body: some View {
        ZStack {
            TunnelBackgroundView()
                .ignoresSafeArea()
            LoginScrimGradient()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                if let msg = auth.errorMessage {
                    Text(msg)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                        .padding(.bottom, 12)
                }

                whiteActionButton(l10n.t(.loginNow)) { attempt(provisional: false) }
                    .padding(.bottom, 10)
                whiteActionButton(l10n.t(.signNow)) { attempt(provisional: true) }
                    .padding(.bottom, 10)

                Button { showRestoreUnavailable = true } label: {
                    Text(l10n.t(.loginRestoreEmail))
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .opacity(0.85)
                .padding(.bottom, 14)

                termsRow
            }

            // Upstream `loading_spinner`: bare white indeterminate, centered.
            if auth.isLoading {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }
        }
        .preferredColorScheme(.dark)
        .alert(l10n.t(.loginProxyTitle), isPresented: $showProxyHint) {
            Button(l10n.t(.actionCancel), role: .cancel) {}
            Button(l10n.t(.loginProxyConfirm)) {
                Task { await auth.login(provisional: pendingProvisional) }
            }
        } message: {
            Text(l10n.t(.loginProxyMessage))
        }
        .alert(l10n.t(.readAgreement), isPresented: $showReadAgreement) {
            Button("OK", role: .cancel) {}
        }
        .alert(l10n.t(.loginRestoreUnavailable), isPresented: $showRestoreUnavailable) {
            Button("OK", role: .cancel) {}
        }
    }

    /// Upstream `checkAndNext`: terms checkbox gates both buttons; then the
    /// proxy-hint dialog confirms before the OAuth tab opens.
    private func attempt(provisional: Bool) {
        guard termsAccepted else { showReadAgreement = true; return }
        pendingProvisional = provisional
        showProxyHint = true
    }

    /// `round_corner_white_r20` pill: 50pt tall, white r16, Montserrat
    /// SemiBold 16, black label, 30pt side margins.
    private func whiteActionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.montserratSemiBold(16))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(.white, in: .rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(auth.isLoading)
        .padding(.horizontal, 30)
    }

    /// `checkbox_one`: 40×40 tap target with the 18pt box (faint outlined
    /// square unchecked / the upstream `terms_checked` asset checked), and the
    /// 12pt terms text whose ToS / privacy-policy spans open pixiv's pages.
    private var termsRow: some View {
        HStack(alignment: .top, spacing: 0) {
            Button { termsAccepted.toggle() } label: {
                Group {
                    if termsAccepted {
                        Image("terms_checked")
                            .resizable()
                            .frame(width: 18, height: 18)
                    } else {
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(.white.opacity(0.4), lineWidth: 0.5)
                            .background(
                                RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.048))
                            )
                            .frame(width: 18, height: 18)
                    }
                }
                .padding(.top, 12)
                .frame(width: 40, height: 40, alignment: .top)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            Text(termsText)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .tint(.white)
                .padding(.top, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 20)
        .padding(.trailing, 34)
    }

    private var termsText: AttributedString {
        let tos = l10n.t(.termsOfService)
        let pp = l10n.t(.privacyPolicy)
        var attr = AttributedString(String(format: l10n.t(.landingTermsBase), tos, pp))
        if let r = attr.range(of: tos) {
            attr[r].link = URL(string: "https://www.pixiv.net/terms/?page=term&appname=pixiv_ios")
            attr[r].underlineStyle = .single
        }
        if let r = attr.range(of: pp) {
            attr[r].link = URL(string: "https://www.pixiv.net/terms/?page=privacy&appname=pixiv_ios")
            attr[r].underlineStyle = .single
        }
        return attr
    }
}

struct LoggedInView: View {
    @Bindable var auth: AuthViewModel
    @Environment(OnboardingStore.self) private var l10n

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
                GroupBox(l10n.t(.tokenTitle)) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(l10n.t(.tokenAccess)).font(.caption.bold())
                        Text(token.accessToken).font(.caption.monospaced()).lineLimit(2).truncationMode(.middle)
                        let formatted = token.expiresAt.formatted(date: .omitted, time: .shortened)
                        Text(l10n.t(.tokenExpiresFormat, formatted))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal)
            }

            HStack {
                Button(l10n.t(.actionRefresh)) { Task { await auth.refresh() } }
                    .buttonStyle(.bordered)
                Button(l10n.t(.actionLogOut), role: .destructive) { auth.logout() }
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
