import Foundation

actor AuthTokenProvider: PixivTokenProvider {
    static let shared = AuthTokenProvider()

    private let store = KeychainTokenStore.shared
    private let oauth = PixivOAuthClient(config: .pixivAndroid)

    private var inflightRefresh: Task<String?, Never>?
    private var refreshID: UUID?

    func currentAccessToken() async -> String? {
        store.load()?.accessToken
    }

    /// Concurrent callers are coalesced into a single refresh: the first arrival
    /// publishes its `Task` to `inflightRefresh`, later arrivals await the same
    /// value. Actor isolation guarantees the check-then-set sequence runs without
    /// interleaving — `Task { ... }` does not suspend, so other actor-isolated
    /// methods cannot run between line "check" and line "publish".
    func refreshAccessToken() async -> String? {
        guard !Task.isCancelled else { return nil }
        if let inflight = inflightRefresh {
            return try? await CancellableTaskWaiter<String?>().value(of: inflight)
        }
        let task = Task<String?, Never> { [oauth, store] in
            guard let current = store.load() else { return nil }
            let result = await oauth.refreshToken(current.refreshToken)
            if case .success(let resp, _) = result {
                let saved: PixivOAuthResponse
                if let fresh = resp.user {
                    saved = PixivOAuthResponse(
                        accessToken: resp.accessToken,
                        refreshToken: resp.refreshToken,
                        expiresIn: resp.expiresIn,
                        tokenType: resp.tokenType,
                        scope: resp.scope,
                        user: PixivOAuthUser(
                            id: fresh.id,
                            name: fresh.name,
                            account: fresh.account,
                            isPremium: fresh.isPremium ?? current.user?.isPremium,
                            xRestrict: fresh.xRestrict ?? current.user?.xRestrict
                        ),
                        issuedAt: resp.issuedAt
                    )
                } else {
                    saved = PixivOAuthResponse(
                        accessToken: resp.accessToken,
                        refreshToken: resp.refreshToken,
                        expiresIn: resp.expiresIn,
                        tokenType: resp.tokenType,
                        scope: resp.scope,
                        user: current.user,
                        issuedAt: resp.issuedAt
                    )
                }
                guard store.load()?.refreshToken == current.refreshToken else { return store.load()?.accessToken }
                try? store.save(saved)
                return resp.accessToken
            }
            return nil
        }
        inflightRefresh = task
        let id = UUID()
        refreshID = id
        Task { [weak self] in
            _ = await task.value
            await self?.finishRefresh(id)
        }
        return try? await CancellableTaskWaiter<String?>().value(of: task)
    }
    private func finishRefresh(_ id: UUID) {
        guard refreshID == id else { return }
        inflightRefresh = nil; refreshID = nil
    }

}
