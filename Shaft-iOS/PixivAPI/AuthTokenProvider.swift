import Foundation

actor AuthTokenProvider: PixivTokenProvider {
    static let shared = AuthTokenProvider()

    private let store = KeychainTokenStore.shared
    private let oauth = PixivOAuthClient(config: .pixivAndroid)

    private var inflightRefresh: Task<String?, Never>?

    func currentAccessToken() async -> String? {
        store.load()?.accessToken
    }

    /// Concurrent callers are coalesced into a single refresh: the first arrival
    /// publishes its `Task` to `inflightRefresh`, later arrivals await the same
    /// value. Actor isolation guarantees the check-then-set sequence runs without
    /// interleaving — `Task { ... }` does not suspend, so other actor-isolated
    /// methods cannot run between line "check" and line "publish".
    func refreshAccessToken() async -> String? {
        if let inflight = inflightRefresh {
            return await inflight.value
        }
        let task = Task<String?, Never> { [oauth, store] in
            guard let current = store.load() else { return nil }
            let result = await oauth.refreshToken(current.refreshToken)
            if case .success(let resp, _) = result {
                try? store.save(resp)
                return resp.accessToken
            }
            return nil
        }
        inflightRefresh = task
        let result = await task.value
        inflightRefresh = nil
        return result
    }
}
