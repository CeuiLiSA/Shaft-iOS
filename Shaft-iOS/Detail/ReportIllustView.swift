import SwiftUI

// MARK: - Reason

/// One of pixiv's four report reasons. `rawValue` is the `type_of_problem`
/// string the report endpoint expects; `titleKey` the localized label. 1:1 with
/// upstream `FlagReason`.
enum ReportReason: String, CaseIterable, Identifiable, Hashable {
    case sexual    = "contains_excessive_sexual_content"
    case grotesque = "contains_excessive_grotesque_content"
    case copyright = "infringes_on_copyrights"
    case other     = "violated_other_rules"

    var id: String { rawValue }

    var titleKey: LocalizedKey {
        switch self {
        case .sexual:    .reportReasonSexual
        case .grotesque: .reportReasonGrotesque
        case .copyright: .reportReasonCopyright
        case .other:     .reportReasonOther
        }
    }
}

// MARK: - Report flow (sheet)

/// Two-step report flow presented as a sheet — reason picker pushes the
/// description page. 1:1 with upstream `FlagReasonFragment` → `FlagDescFragment`
/// (which upstream stacks as two activities). Reached from the illust-detail
/// More menu ("举报这个作品").
struct ReportIllustView: View {
    let illustId: Int64

    @Environment(\.dismiss) private var dismiss
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        NavigationStack {
            // Reason picker — upstream cell_flag_reason.xml: 70pt rows, 18pt
            // text at 16pt leading inset, trailing chevron. The list is
            // ListMode.VERTICAL_NO_MARGIN, which adds no item decoration, so
            // there are no separators between cells.
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(ReportReason.allCases) { reason in
                        NavigationLink(value: reason) {
                            HStack(spacing: 0) {
                                Text(l10n.t(reason.titleKey))
                                    .font(.system(size: 18))
                                    .foregroundStyle(Theme.v3Text1)
                                Spacer(minLength: 12)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Theme.v3Text3)
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 70)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle(l10n.t(.reportReasonTitle))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: ReportReason.self) { reason in
                ReportDescView(illustId: illustId, reason: reason) { dismiss() }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(l10n.t(.actionCancel)) { dismiss() }
                }
            }
        }
    }
}

// MARK: - Description page

/// The second step: shows the chosen reason, a free-text box and a red submit
/// button. 1:1 with upstream `fragment_flag_desc.xml` / `FlagDescFragment` —
/// submit is a no-op while the text is empty; on success it shows a toast then
/// dismisses the whole flow.
private struct ReportDescView: View {
    let illustId: Int64
    let reason: ReportReason
    /// Dismisses the entire sheet (not just this page) — mirrors upstream
    /// `activity.finish()` after a successful report.
    let onComplete: () -> Void

    @Environment(OnboardingStore.self) private var l10n
    private let api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)

    @State private var desc = ""
    @State private var submitting = false
    @State private var errorMessage: String?
    @State private var showSuccess = false
    @FocusState private var inputFocused: Bool

    private var trimmed: String {
        desc.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(l10n.t(reason.titleKey))
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Theme.v3Text1)

            // Free-text box — upstream 200dp rounded EditText with a hint.
            ZStack(alignment: .topLeading) {
                if desc.isEmpty {
                    Text(l10n.t(.reportHint))
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.v3Text3)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 18)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $desc)
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.v3Text1)
                    .scrollContentBackground(.hidden)
                    .focused($inputFocused)
                    .padding(10)
            }
            .frame(height: 200)
            // round_corner_white05_r8: solid colorBlack10 (#1A000000 = black@10%),
            // 8dp corners, no stroke. White@10% in dark so the box stays visible.
            .background(Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.10, darkAlpha: 0.10),
                        in: .rect(cornerRadius: 8))
            .padding(.top, 30)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
                    .padding(.top, 12)
            }

            // Submit — upstream RedShiningButton (round_corner_shining_btn_red):
            // dark-maroon #480416 @75% fill, 6dp corners, 0.5dp #FF5A7E stroke,
            // bold #FF3E65 text with a #A7002A glow. Full-width, 50dp, 60dp gap.
            Button(action: submit) {
                ZStack {
                    if submitting {
                        ProgressView().tint(Color(hex: 0xFF3E65))
                    } else {
                        Text(l10n.t(.reportSubmit))
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Color(hex: 0xFF3E65))
                            .shadow(color: Color(hex: 0xA7002A), radius: 6, y: 2)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Color(hex: 0x480416, alpha: 0.75), in: .rect(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(hex: 0xFF5A7E), lineWidth: 0.5))
                .opacity(canSubmit ? 1 : 0.4)
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .padding(.top, 60)

            Spacer(minLength: 0)
        }
        .padding(16)
        .navigationTitle(l10n.t(.reportDescTitle))
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if showSuccess {
                Text(l10n.t(.reportSuccess))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(.black.opacity(0.75), in: .capsule)
                    .padding(.bottom, 60)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showSuccess)
    }

    private var canSubmit: Bool { !trimmed.isEmpty && !submitting }

    private func submit() {
        let message = trimmed
        guard !message.isEmpty, !submitting else { return }
        inputFocused = false
        submitting = true
        errorMessage = nil
        Task {
            do {
                try await api.reportIllust(illustId, typeOfProblem: reason.rawValue, message: message)
                showSuccess = true
                try? await Task.sleep(for: .seconds(1.2))
                onComplete()
            } catch {
                errorMessage = error.localizedDescription
                submitting = false
            }
        }
    }
}
