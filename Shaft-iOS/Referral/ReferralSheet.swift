import SwiftUI
import UIKit

private struct ReferralSheetHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Custom presentation keeps the Android edge-to-edge 30pt sheet geometry on iOS,
/// including iOS 26 (whose system sheet otherwise introduces floating margins).
struct ReferralSheet: View {
    @Bindable var model: ReferralModel
    var selection: ReferralSheetSelection
    var palette: ReferralPalette
    var copy: ReferralCopy
    var dismiss: () -> Void
    var wallet: () -> Void
    @State private var kind: ReferralSheetKind
    @State private var code: String
    @State private var url = ""
    @State private var description = ""
    @State private var confirmed = false
    @State private var error: String?
    @State private var submitting = false
    @State private var contentHeight: CGFloat = 600
    @State private var share: ShareItem?
    @State private var toast: String?
    @FocusState private var field: String?
    @AccessibilityFocusState private var headingFocused: Bool
    private var c: ReferralPalette { palette }
    private var s: ReferralSnapshot { model.snapshot }
    private var task: ReferralTask { selection.task }
    private var taskState: ReferralTaskState? { s.task(task) }
    private var card: ReferralReward? { s.cards.first { $0.id == selection.cardID } }

    init(model: ReferralModel, selection: ReferralSheetSelection, palette: ReferralPalette, copy: ReferralCopy,
         dismiss: @escaping () -> Void, wallet: @escaping () -> Void) {
        self.model = model; self.selection = selection; self.palette = palette; self.copy = copy
        self.dismiss = dismiss; self.wallet = wallet
        _kind = State(initialValue: selection.kind)
        _code = State(initialValue: selection.code)
        _url = State(initialValue: model.snapshot.task(selection.task)?.submittedUrl ?? "")
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 760
            ZStack(alignment: wide ? .center : .bottom) {
                Color.black.opacity(0.4).ignoresSafeArea().onTapGesture { close() }.accessibilityHidden(true)
                ScrollViewReader { scroll in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Capsule().fill(c.line).frame(width: 34, height: 4).frame(maxWidth: .infinity)
                                .accessibilityHidden(true).id("sheet-top")
                                .padding(.vertical, 0)
                                .gesture(DragGesture().onEnded { if $0.translation.height > 80 { close() } })
                            ReferralIconButton(glyph: .close, label: copy.text("close"), palette: c) { close() }
                                .frame(maxWidth: .infinity, alignment: .trailing).disabled(submitting)
                            contents
                        }
                        .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 24 + (wide ? 0 : geometry.safeAreaInsets.bottom))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(GeometryReader { value in Color.clear.preference(key: ReferralSheetHeight.self, value: value.size.height) })
                    }
                    .scrollIndicators(.hidden).scrollDismissesKeyboard(.interactively)
                    .onChange(of: kind) { _, _ in scroll.scrollTo("sheet-top", anchor: .top); headingFocused = true }
                }
                .frame(width: wide ? 480 : geometry.size.width, height: min(contentHeight, max(180, geometry.size.height - 24)))
                .background(c.surface)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 30, bottomLeadingRadius: wide ? 30 : 0,
                                                bottomTrailingRadius: wide ? 30 : 0, topTrailingRadius: 30, style: .circular))
                // During insertion SwiftUI also emits the key's default zero. Feeding
                // it back into the frame collapses the scroll viewport permanently.
                .onPreferenceChange(ReferralSheetHeight.self) { if $0 > 0 { contentHeight = $0 } }
                .accessibilityAddTraits(.isModal)
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .overlay(alignment: .bottom) {
            if let toast {
                ReferralText(value: toast, size: 12, weight: 500, color: c.surface)
                    .padding(.horizontal, 20).padding(.vertical, 14).background(c.ink, in: Capsule())
                    .padding(.bottom, 36).allowsHitTesting(false)
            }
        }
        .sheet(item: $share) { ReferralShareController(text: $0.text) }
        .onKeyPress(.escape) { close(); return .handled }
        .task { headingFocused = true }
        .accessibilityIdentifier("referral-sheet-\(kind.rawValue)")
    }

    @ViewBuilder private var contents: some View {
        switch kind {
        case .task: taskDetails
        case .claim:
            title("claim_title")
            bodyText("claim_desc", [copy.text(task.titleKey), String(taskState?.days ?? 7), referralPlanLabel(taskState?.plan)])
            reward(days: taskState?.days ?? 7, tier: referralPlanLabel(taskState?.plan))
            action("claim_confirm", primary: true) { run(.init(operation: "claim", task: task.rawValue), next: .claimed) }
            inlineError
            notice
        case .claimed:
            let rewardCard = s.cards.first { $0.kind == task }
            title("claim_success")
            bodyText("claim_success_note", [String(rewardCard?.duration ?? 7), referralPlanLabel(rewardCard?.plan ?? taskState?.plan), copy.date(rewardCard?.expiresAt ?? 0)])
            reward(days: rewardCard?.duration ?? 7, tier: referralPlanLabel(rewardCard?.plan ?? taskState?.plan))
            action("go_wallet", primary: true, wallet)
            action("continue", dismiss)
        case .activate:
            title("activate_title", [String(card?.duration ?? 7), referralPlanLabel(card?.plan)])
            reward(days: card?.duration ?? 7, tier: referralPlanLabel(card?.plan))
            bodyText("activate_desc", [copy.date(max(referralNow(), s.activeUntil ?? 0) + Double(card?.duration ?? 7) * 86_400_000)])
            action("activate_confirm", primary: true) {
                guard let id = card?.id else { error = copy.text("action_unavailable"); return }
                run(.init(operation: "activate", id: id), next: .activated)
            }
            inlineError
            action("later", dismiss)
        case .activated:
            title("activate_success")
            bodyText("activate_success_desc", [String(card?.duration ?? 7), referralPlanLabel(card?.plan), copy.date(s.activeUntil ?? 0)])
            reward(days: card?.duration ?? 7, tier: referralPlanLabel(card?.plan))
            action("ok", primary: true, dismiss)
        case .invite: invite
        case .inviteProgress:
            title("invite_progress_title")
            bodyText("invite_progress_desc", [String(s.effective ?? 0), String(s.retained ?? 0)])
            action("invite_action", primary: true) { go(.invite) }
        case .bind: binding
        case .bound:
            title("bind_success")
            bodyText("bind_success_desc", s.currentRules.arguments)
            if let uid = s.inviterUID { bodyText("bound_already", [String(uid)]) }
            action("ok", primary: true, dismiss)
        case .form: submission
        case .submitted:
            title("received")
            bodyText("submitted_note")
            action("ok", primary: true, dismiss)
        case .rules:
            title("rules_title")
            bodyText("rules_body", s.currentRules.arguments)
            notice
        case .materials:
            title("material_title")
            bodyText("material_lead")
            ForEach(1...3, id: \.self) { index in
                ReferralText(value: copy.text("material\(index)"), size: 15, weight: 600, color: c.ink).padding(.top, 24)
                bodyText("material\(index)_desc")
            }
            action("copy_template", primary: true) { copyText(copy.text("template")) }
        }
    }
    private var taskDetails: some View {
        VStack(alignment: .leading, spacing: 0) {
            title(task.titleKey)
            bodyText(task.rawValue + "_description")
            ReferralText(value: copy.text("days_pro", String(taskState?.days ?? 7), referralPlanLabel(taskState?.plan)), size: 24, weight: 700, color: c.primary).padding(.top, 20)
            if taskState?.state == .pending { bodyText("review_note") }
            if taskState?.state == .rejected {
                bodyText("rejected_note")
                if let note = taskState?.reviewNote, !note.isEmpty { paragraph(note) }
            }
            if taskState?.enabled == false { bodyText("task_disabled") }
            ReferralText(value: copy.text("how"), size: 15, weight: 600, color: c.ink).padding(.top, 22)
            let arguments = task == .circle ? s.currentRules.retainArguments : s.currentRules.arguments
            let steps = copy.format(task.rawValue + "_steps", arguments).components(separatedBy: "\n")
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                ReferralText(value: "\(index + 1). \(step)", size: 13, color: c.ink, lineMultiple: 1.7).padding(.top, 12)
            }
            bodyText(task.conditionKey)
            if taskState?.state == .ready {
                action("claim", primary: true) { go(.claim) }
            } else if taskState?.state == .claimed {
                action("go_wallet", primary: true, wallet)
            } else if taskState?.state == .pending || taskState?.enabled == false || s.enabled != true {
                action("ok", primary: true, dismiss)
            } else {
                action(task.isInvitation ? "invite_action" : "submit", primary: true) { go(task.isInvitation ? .invite : .form) }
            }
        }
    }
    private var invite: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("invite_title"); bodyText("invite_lead")
            ReferralText(value: copy.text("invite_benefit"), size: 24, weight: 700, color: c.primary).padding(.top, 24)
            bodyText("invite_condition", s.currentRules.arguments)
            bodyText(s.code == nil ? "closed_banner" : "invite_unavailable")
            if let code = s.code, !code.isEmpty {
                ReferralText(value: copy.text("code_label"), size: 12, weight: 600, color: c.ink).padding(.top, 24)
                Text(code).font(.system(size: 30, weight: .bold, design: .monospaced)).tracking(4.2).foregroundStyle(c.primary)
                    .textSelection(.enabled).frame(maxWidth: .infinity).padding(.horizontal, 16).padding(.vertical, 14)
                    .background(c.tint, in: RoundedRectangle(cornerRadius: 18, style: .circular)).padding(.top, 8)
            }
            if let link = s.inviteUrl, !link.isEmpty {
                let value = copy.text("invite_share_text", link, s.code ?? "")
                action("copy_invite", primary: true) { copyText(value) }
                action("share_app") { share = ShareItem(text: value) }
                action("copy_link") { copyText(link) }
            }
            action("invite_progress") { go(.inviteProgress) }
        }
    }
    private var binding: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("bind_title"); bodyText("bind_lead")
            label("bind_field")
            TextField(copy.text("bind_hint"), text: $code)
                .font(.system(size: 22, design: .monospaced)).tracking(3.08).multilineTextAlignment(.center)
                .textInputAutocapitalization(.characters).autocorrectionDisabled().keyboardType(.asciiCapable)
                .focused($field, equals: "code").accessibilityLabel(copy.text("bind_field"))
                .padding(.horizontal, 16).padding(.vertical, 14).frame(minHeight: 60)
                .background(c.surface2, in: RoundedRectangle(cornerRadius: 16, style: .circular))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .circular).strokeBorder(c.line, lineWidth: 1))
                .foregroundStyle(c.ink).padding(.top, 8)
                .onChange(of: code) { _, new in code = String(new.uppercased().prefix(16)) }
            action("bind_paste") {
                if let pasted = parseReferralCode(UIPasteboard.general.string), pasted != s.code { code = pasted }
                else { error = copy.text("error_bad_code") }
            }
            inlineError
            action("bind_confirm", primary: true) {
                guard let code = parseReferralCode(code) else { error = copy.text("error_bad_code"); return }
                run(.init(operation: "bind", code: code), next: .bound)
            }
            notice
        }
    }
    private var submission: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("form_title"); bodyText("form_lead")
            label("form_url")
            TextField(copy.text("form_url_hint"), text: $url)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($field, equals: "url").accessibilityLabel(copy.text("form_url"))
                .font(.custom(ReferralFonts.name(400), size: 14)).padding(.horizontal, 16).padding(.vertical, 14)
                .frame(minHeight: 56).fieldSurface(c).padding(.top, 8)
                .onChange(of: url) { _, new in url = String(new.prefix(2000)) }
            label("form_desc")
            TextField(copy.text("form_desc_hint"), text: $description, axis: .vertical)
                .lineLimit(4...).textInputAutocapitalization(.sentences).focused($field, equals: "description")
                .accessibilityLabel(copy.text("form_desc"))
                .font(.custom(ReferralFonts.name(400), size: 14)).padding(.horizontal, 16).padding(.vertical, 14)
                .frame(minHeight: 112, alignment: .top).fieldSurface(c).padding(.top, 8)
                .onChange(of: description) { _, new in description = String(new.prefix(1000)) }
            Button { confirmed.toggle() } label: {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 2).strokeBorder(c.primary, lineWidth: 2).frame(width: 20, height: 20)
                        if confirmed {
                            RoundedRectangle(cornerRadius: 2).fill(c.primary).frame(width: 20, height: 20)
                            ReferralIcon(glyph: .check).stroke(c.onPrimary, lineWidth: 1.7).frame(width: 18, height: 18)
                        }
                    }
                    ReferralText(value: copy.text("form_confirm"), size: 12, color: c.muted).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 48).contentShape(Rectangle())
            }.buttonStyle(ReferralPressStyle()).accessibilityAddTraits(confirmed ? .isSelected : []).padding(.top, 14)
            inlineError
            action("submit_review", primary: true) {
                let raw = url.trimmingCharacters(in: .whitespacesAndNewlines)
                let parsed = URLComponents(string: raw)
                guard confirmed, ["http", "https"].contains(parsed?.scheme?.lowercased() ?? ""),
                      parsed?.host?.isEmpty == false, description.trimmingCharacters(in: .whitespacesAndNewlines).count >= 20 else {
                    error = copy.text("form_invalid"); return
                }
                run(.init(operation: "submit", task: task.rawValue, url: raw,
                          description: description.trimmingCharacters(in: .whitespacesAndNewlines)), next: .submitted)
            }
            notice
        }
    }
    private func title(_ key: String, _ args: [String] = []) -> some View {
        ReferralText(value: copy.format(key, args), size: 25, weight: 700, color: c.ink)
            .accessibilityAddTraits(.isHeader).accessibilityFocused($headingFocused)
    }
    private func paragraph(_ value: String) -> some View {
        ReferralText(value: value, size: 13, color: c.muted, lineMultiple: 1.7).padding(.top, 14)
    }
    private func bodyText(_ key: String, _ args: [String] = []) -> some View { paragraph(copy.format(key, args)) }
    private var notice: some View { bodyText("preview_notice") }
    @ViewBuilder private var inlineError: some View {
        if let error {
            ReferralText(value: error, size: 12, weight: 500, color: c.danger).padding(.top, 12)
                .accessibilityIdentifier("referral-action-error")
        }
    }
    private func label(_ key: String) -> some View {
        ReferralText(value: copy.text(key), size: 12, weight: 600, color: c.ink).padding(.top, 20)
    }
    private func action(_ key: String, primary: Bool = false, _ action: @escaping () -> Void) -> some View {
        ReferralButton(label: copy.text(key), palette: c, primary: primary, action: action)
            .disabled(submitting || model.busy).padding(.top, 14)
    }
    private func reward(days: Int, tier: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ReferralText(value: "\(tier) / EXPERIENCE PASS", size: 10, weight: 600, color: c.onHero)
            HStack(spacing: 10) {
                ReferralText(value: String(days), size: 58, weight: 800, color: c.ink)
                ReferralText(value: copy.text("day_unit"), size: 15, weight: 600, color: c.onHero)
            }.padding(.top, 10)
            ReferralText(value: copy.text(days <= 7 ? "card_week" : "card_month", tier), size: 17, weight: 600, color: c.ink).padding(.top, 6)
            ReferralText(value: copy.text("card_hint"), size: 11, color: c.onHero).padding(.top, 14)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 22)
            .background(c.hero, in: RoundedRectangle(cornerRadius: 24, style: .circular)).padding(.top, 22)
    }
    private func go(_ kind: ReferralSheetKind) { error = nil; field = nil; self.kind = kind }
    private func close() { if !submitting { field = nil; dismiss() } }
    private func run(_ mutation: ReferralMutation, next: ReferralSheetKind) {
        guard !submitting else { return }
        submitting = true; error = nil
        Task { @MainActor in
            defer { submitting = false }
            if let failure = await model.mutate(mutation) {
                error = copy.text(failure.messageKey)
                UIAccessibility.post(notification: .announcement, argument: error)
            } else { go(next) }
        }
    }
    private func copyText(_ value: String) {
        UIPasteboard.general.string = value
        toast = copy.text("copy_success")
        UIAccessibility.post(notification: .announcement, argument: toast)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            toast = nil
        }
    }
    private struct ShareItem: Identifiable { let id = UUID(); var text: String }
}

private extension View {
    func fieldSurface(_ c: ReferralPalette) -> some View {
        foregroundStyle(c.ink).tint(c.primary)
            .background(c.surface2, in: RoundedRectangle(cornerRadius: 16, style: .circular))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .circular).strokeBorder(c.line, lineWidth: 1))
    }
}

private struct ReferralShareController: UIViewControllerRepresentable {
    var text: String
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
