import SwiftUI

/// One-time "may contain R-18 / sensitive content" gate shown before the
/// shaft-api-v2 feeds (当前最热 / 站长推荐 / 操作记录). 1:1 with upstream
/// `SensitiveContentGate`: a single Bool in UserDefaults (`sensitive_content_gate_acked`);
/// once the user taps 坚持查看 it never shows again for any of the three pages.
@MainActor
@Observable
final class SensitiveGateStore {
    static let shared = SensitiveGateStore()
    private let key = "sensitive_content_gate_acked"
    private(set) var acked: Bool
    private init() { acked = UserDefaults.standard.bool(forKey: key) }
    func ack() {
        acked = true
        UserDefaults.standard.set(true, forKey: key)
    }
}

/// Wraps a gated page's content. Until acked, shows a confirm panel instead of
/// the content; 取消查看 pops the page, 坚持查看 reveals it and remembers.
struct SensitiveGate<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var store = SensitiveGateStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        if store.acked {
            content
        } else {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.shield")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)
                Text(l10n.t(.sensitiveGateTitle)).font(.headline)
                Text(l10n.t(.sensitiveGateMessage))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    Button(l10n.t(.sensitiveGateCancel)) { dismiss() }
                        .buttonStyle(.bordered)
                    Button(l10n.t(.sensitiveGateProceed)) { store.ack() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.top, 4)
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
