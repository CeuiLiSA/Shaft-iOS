import SwiftUI

/// Programmatic push onto the enclosing tab's `NavigationStack` path — the
/// SwiftUI equivalent of upstream's `startActivity(Intent)` for flows that
/// decide their destination at runtime (the search box dispatching by search
/// type, a numeric ID that resolves to an illust *or* a user, …). Installed by
/// `HomeView.tabStack`; the default is a no-op so previews / sheets stay inert.
struct RoutePusher {
    let push: (AppRoute) -> Void

    func callAsFunction(_ route: AppRoute) { push(route) }
}

private struct RoutePusherKey: EnvironmentKey {
    static let defaultValue = RoutePusher(push: { _ in })
}

extension EnvironmentValues {
    var pushRoute: RoutePusher {
        get { self[RoutePusherKey.self] }
        set { self[RoutePusherKey.self] = newValue }
    }
}
