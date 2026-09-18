#if DEBUG
import SwiftUI

/// Deterministic, isolated fixtures for visual and interaction tests. Never talks to
/// the network or writes account entitlements; excluded from Release builds.
actor ReferralPreviewService: ReferralServing {
    var snapshot: ReferralSnapshot
    var failure: String?
    init(scenario: String = "default") {
        let now = referralNow()
        snapshot = ReferralSnapshot(uid: 42, campaign: "2026-09", enabled: true, code: "K7M2QX4P",
                                    inviteUrl: "https://pixshaft.com/i/K7M2QX4P", effective: 1, retained: 1)
        snapshot.tasks = ReferralTask.listed.map {
            ReferralTaskState(key: $0.rawValue, days: 7, plan: $0 == .tutorial || $0 == .circle ? "max" : "pro",
                              target: $0.target, progress: $0 == .invite || $0 == .circle ? 1 : 0,
                              status: $0 == .invite ? "ready" : $0 == .circle ? "progress" : "new", enabled: true)
        }
        if scenario == "wallet" || scenario == "closed-wallet" || scenario == "expired" {
            snapshot.rewards = [.init(id: 100, task: "invite", plan: "pro", days: 7, issuedAt: now,
                                      expiresAt: now + (scenario == "expired" ? -1 : 30 * 86_400_000))]
            snapshot.tasks?[0].status = "claimed"
        }
        if scenario == "closed" || scenario == "closed-wallet" { snapshot.enabled = false; snapshot.code = nil; snapshot.inviteUrl = nil }
        if scenario == "error" { failure = "network" }
        if scenario == "rejected" {
            snapshot.tasks?[1].status = "rejected"
            snapshot.tasks?[1].reviewNote = "请补充可公开访问的 App 下载入口，并在说明中注明活动奖励关系。"
        }
        if scenario == "pending" { snapshot.tasks?[1].status = "pending" }
    }
    func load(uid: Int64, campaign: String?) async throws -> ReferralSnapshot {
        if let failure { throw ReferralFailure(code: failure) }
        return snapshot
    }
    func mutate(_ mutation: ReferralMutation, uid: Int64, campaign: String?) async throws -> ReferralSnapshot {
        switch mutation.operation {
        case "claim":
            guard let index = snapshot.tasks?.firstIndex(where: { $0.key == mutation.task }), snapshot.tasks?[index].state == .ready else { throw ReferralFailure(code: "not_ready", stale: true) }
            let task = snapshot.tasks![index]
            snapshot.tasks?[index].status = "claimed"
            snapshot.rewards = (snapshot.rewards ?? []) + [.init(id: 100, task: task.key, plan: task.plan, days: task.days,
                                                               issuedAt: referralNow(), expiresAt: referralNow() + 30 * 86_400_000)]
        case "activate":
            guard let index = snapshot.rewards?.firstIndex(where: { $0.id == mutation.id }) else { throw ReferralFailure(code: "unknown_reward") }
            snapshot.rewards?[index].activatedAt = referralNow()
            snapshot.activeUntil = referralNow() + 7 * 86_400_000
        case "bind": snapshot.boundTo = .init(inviterUid: 99, reviewState: "ok")
        case "submit":
            guard let index = snapshot.tasks?.firstIndex(where: { $0.key == mutation.task }) else { throw ReferralFailure(code: "task_disabled") }
            snapshot.tasks?[index].status = "pending"
            snapshot.tasks?[index].submittedUrl = mutation.url
        default: throw ReferralFailure(code: "generic")
        }
        return snapshot
    }
}

struct ReferralPreviewScreen: View {
    @State private var locale = OnboardingStore()
    private let scenario: String
    private let language: String
    private let dark: Bool
    private let width: CGFloat?
    private let large: Bool
    private let initialSheet: ReferralSheetSelection?
    @State private var model: ReferralModel
    init() {
        let args = ProcessInfo.processInfo.arguments
        func option(_ key: String) -> String? { args.first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) } }
        scenario = option("--referral-scenario") ?? "default"
        language = option("--referral-language") ?? "zh-Hans"
        dark = args.contains("--referral-dark")
        large = args.contains("--referral-large")
        width = option("--referral-width").flatMap(Double.init).map { CGFloat($0) }
        initialSheet = option("--referral-sheet").flatMap(ReferralSheetKind.init(rawValue:)).map {
            ReferralSheetSelection(kind: $0, task: ReferralTask(rawValue: option("--referral-task") ?? "invite") ?? .invite, cardID: 100)
        }
        _model = State(initialValue: ReferralModel(service: ReferralPreviewService(scenario: scenario), currentUID: { 42 }))
    }
    var body: some View {
        NavigationStack {
            ReferralPlanView(initialSheet: initialSheet, model: model)
                .frame(maxWidth: width ?? .infinity)
                .frame(maxWidth: .infinity)
        }
        .environment(locale).environment(\.locale, Locale(identifier: language))
        .environment(\.dynamicTypeSize, large ? .accessibility3 : .large)
        .preferredColorScheme(dark ? .dark : .light)
        .onAppear { locale.chosenTag = language }
    }
}
#endif
