import Foundation

// Wire fields deliberately remain optional, matching Android's ReferralStateResponse.
// Unknown tasks are ignored; rewards and eligibility are never inferred locally.
enum ReferralTask: String, CaseIterable, Identifiable, Codable {
    case invite, recommend, circle, tutorial, welcome
    static let listed: [Self] = [.invite, .recommend, .circle, .tutorial]
    var id: String { rawValue }
    var target: Int { self == .circle ? 3 : 1 }
    var titleKey: String { self == .invite ? "invite_title_task" : "\(rawValue)_title" }
    var conditionKey: String { self == .invite ? "invite_condition_task" : "\(rawValue)_condition" }
    var isInvitation: Bool { self == .invite || self == .circle }
}

enum ReferralStatus: String, Codable {
    case new, progress, pending, rejected, ready, claimed
    var labelKey: String {
        switch self {
        case .progress: return "progress"
        case .ready: return "ready"
        default: return "state_\(rawValue)"
        }
    }
    var actionKey: String {
        switch self {
        case .new: return "see_task"
        case .progress: return "see_progress"
        case .pending: return "see_review"
        case .rejected: return "fix"
        case .ready: return "claim"
        case .claimed: return "see_reward"
        }
    }
}

struct ReferralTaskState: Codable {
    var key: String?
    var days: Int?
    var plan: String?
    var target: Int?
    var progress: Int?
    var status: String?
    var enabled: Bool?
    var reviewNote: String?
    var submittedUrl: String?
    var state: ReferralStatus { ReferralStatus(rawValue: status ?? "") ?? .new }
}

struct ReferralReward: Codable, Identifiable {
    var id: Int64?
    var task: String?
    var plan: String?
    var days: Int?
    var issuedAt: Double?
    var expiresAt: Double?
    var activatedAt: Double?
    var grantedUntil: Double?
    var kind: ReferralTask? { ReferralTask(rawValue: task ?? "") }
    var duration: Int { days ?? 7 }
    var activated: Bool { (activatedAt ?? 0) > 0 }
    func usable(at now: Double) -> Bool { !activated && (expiresAt ?? 0) > now }
}

struct ReferralRules: Codable {
    var qualifyWindowDays: Int?
    var qualifyActiveDays: Int?
    var retainWindowDays: Int?
    var retainActiveDays: Int?
    var retainLateFromDay: Int?
    var cardValidDays: Int?
    var arguments: [String] {
        [qualifyWindowDays ?? 7, qualifyActiveDays ?? 2, retainWindowDays ?? 14,
         retainActiveDays ?? 3, retainLateFromDay ?? 8, cardValidDays ?? 30].map(String.init)
    }
    var retainArguments: [String] {
        [retainWindowDays ?? 14, retainActiveDays ?? 3, retainLateFromDay ?? 8].map(String.init)
    }
}

struct ReferralSnapshot: Codable {
    struct Binding: Codable {
        var inviterUid: Int64?
        var reviewState: String?
    }
    var uid: Int64?
    var campaign: String?
    var campaigns: [String]?
    var enabled: Bool?
    var code: String?
    var inviteUrl: String?
    var boundTo: Binding?
    var effective: Int?
    var retained: Int?
    var pending: Int?
    var flagged: Int?
    var tasks: [ReferralTaskState]?
    var rewards: [ReferralReward]?
    var activeUntil: Double?
    var rules: ReferralRules?
    var cards: [ReferralReward] { (rewards ?? []).filter { $0.id != nil && $0.kind != nil } }
    var listedTasks: [ReferralTaskState] { ReferralTask.listed.compactMap { task($0) } }
    var currentRules: ReferralRules { rules ?? ReferralRules() }
    var claimable: Int { listedTasks.filter { $0.state == .ready }.count }
    var earnedDays: Int { cards.reduce(0) { $0 + $1.duration } }
    var inviterUID: Int64? { boundTo?.inviterUid.flatMap { $0 > 0 ? $0 : nil } }
    var inviteRejected: Bool { boundTo?.reviewState == "rejected" }
    var hasSomethingToSettle: Bool {
        !cards.isEmpty || inviterUID != nil || (pending ?? 0) > 0 || (flagged ?? 0) > 0 ||
        (campaigns ?? []).count > 1 || listedTasks.contains { $0.state != .new }
    }
    var showsContent: Bool { !listedTasks.isEmpty && (enabled == true || hasSomethingToSettle) }
    func task(_ task: ReferralTask) -> ReferralTaskState? { tasks?.last { $0.key == task.rawValue } }
    func status(_ task: ReferralTask) -> ReferralStatus { self.task(task)?.state ?? .new }
    func progress(_ task: ReferralTask) -> Int { max(0, self.task(task)?.progress ?? 0) }
    func target(_ task: ReferralTask) -> Int { max(1, self.task(task)?.target ?? task.target) }
}

struct ReferralActionResponse: Decodable {
    var state: ReferralSnapshot?
    var error: String?
    var expiresAt: Double?
}

struct ReferralFailure: Error {
    var code: String
    var stale = false
    var messageKey: String {
        switch code {
        case "login_required": return "login_required"
        case "network": return "error_network"
        case "unauthorized", "uid_forbidden": return "error_auth"
        case "rate_limited": return "error_busy"
        case "self_referral": return "error_self"
        case "already_bound": return "error_already_bound"
        case "unknown_code", "bad_code": return "error_bad_code"
        case "not_new_user": return "error_not_new"
        case "budget_exhausted": return "error_budget"
        case "inviter_full": return "error_inviter_full"
        case "referral_disabled", "task_disabled": return "error_closed"
        case "not_ready": return "error_not_ready"
        case "already_claimed": return "error_claimed"
        case "higher_tier_active": return "error_higher_tier"
        case "already_activated": return "error_activated"
        case "reward_expired": return "error_card_expired"
        case "unknown_reward": return "error_card_missing"
        case "bad_url": return "error_bad_url"
        case "bad_description": return "error_bad_description"
        case "already_pending": return "error_pending"
        case "already_approved": return "error_approved"
        case "form_invalid": return "form_invalid"
        default: return "error_generic"
        }
    }
}

func referralPlanLabel(_ plan: String?) -> String { plan == "max" ? "MAX" : "PRO" }
func referralNow() -> Double { Date().timeIntervalSince1970 * 1000 }

func parseReferralCode(_ raw: String?) -> String? {
    guard let raw, !raw.isEmpty, raw.count <= 200 else { return nil }
    var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    if let range = value.range(of: #"/I/([0-9A-Z]+)"#, options: .regularExpression) {
        value = String(value[range].dropFirst(3))
    }
    value = value.replacingOccurrences(of: #"[\s-]"#, with: "", options: .regularExpression)
    return value.range(of: #"^[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{8}$"#, options: .regularExpression) == nil ? nil : value
}

/// Generated catalog is copied from Android resources, including all seven translations.
struct ReferralCopy {
    var tag: String
    private static let catalog: [String: [String: String]] = {
        guard let url = Bundle.main.url(forResource: "referral-strings", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode([String: [String: String]].self, from: data) else { return [:] }
        return value
    }()
    func text(_ key: String, _ arguments: String...) -> String { format(key, arguments) }
    func format(_ key: String, _ arguments: [String]) -> String {
        var value = Self.catalog[tag]?[key] ?? Self.catalog["en"]?[key] ?? key
        // Android positional placeholders keep their order in translated sentences.
        for (index, argument) in arguments.enumerated() {
            value = value.replacingOccurrences(of: "%\(index + 1)$d", with: argument)
                .replacingOccurrences(of: "%\(index + 1)$s", with: argument)
        }
        return value
    }
    func date(_ milliseconds: Double, time: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: tag)
        formatter.dateStyle = time ? .short : .medium
        formatter.timeStyle = time ? .short : .none
        return formatter.string(from: Date(timeIntervalSince1970: milliseconds / 1000))
    }
}
