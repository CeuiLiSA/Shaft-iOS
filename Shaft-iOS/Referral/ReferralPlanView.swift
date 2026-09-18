import SwiftUI

enum ReferralFilter: String, CaseIterable { case all, progress, ready }
enum ReferralSheetKind: String { case task, claim, claimed, activate, activated, invite, inviteProgress, bind, bound, form, submitted, rules, materials }
struct ReferralSheetSelection: Identifiable {
    let id = UUID()
    var kind: ReferralSheetKind
    var task: ReferralTask = .invite
    var cardID: Int64?
    var code = ""
}

struct ReferralPlanView: View {
    var initialCode: String?
    var initialSheet: ReferralSheetSelection?
    var readClipboard: () -> String? = { UIPasteboard.general.string }
    @State var bindingPrompt = ReferralBindingPrompt()
    @State var model = ReferralModel()
    @Environment(OnboardingStore.self) private var l10n
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var darkOverride: Bool?
    @State private var filter: ReferralFilter = .all
    @State private var sheet: ReferralSheetSelection?
    @State private var now = referralNow()
    @ScaledMetric(relativeTo: .body) private var fontScale: CGFloat = 1
    private var c: ReferralPalette { ReferralPalette(dark: darkOverride ?? (colorScheme == .dark)) }
    private var copy: ReferralCopy { ReferralCopy(tag: l10n.activeTag) }
    private var s: ReferralSnapshot { model.snapshot }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 760
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if s.showsContent {
                            topBar
                            content(wide: wide, width: min(1180, geometry.size.width), scroll: scroll)
                                .padding(.horizontal, wide ? 36 : 20).padding(.top, 18)
                        } else {
                            VStack(alignment: .leading, spacing: 24) { topBar; placeholder }
                                .padding(.horizontal, 20).padding(.vertical, 18)
                        }
                    }
                    .frame(maxWidth: 1180).frame(maxWidth: .infinity)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
                .background(c.bg.ignoresSafeArea())
                .accessibilityHidden(sheet != nil)
                .overlay {
                    if let selection = sheet {
                        ReferralSheet(model: model, selection: selection, palette: c, copy: copy,
                                      dismiss: { sheet = nil }, wallet: {
                            sheet = nil
                            scroll.scrollTo("referral-wallet", anchor: .top)
                        })
                        .id(selection.id)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .background(ReferralDismissalGuard(blocked: sheet != nil))
        .preferredColorScheme(darkOverride.map { $0 ? .dark : .light })
        .task { await model.refresh(); suggestBinding(); if let initialSheet { sheet = initialSheet } }
        .onChange(of: phase) { _, value in
            if value == .active { now = referralNow(); Task { await model.refresh(); suggestBinding() } }
        }
        .onChange(of: model.loading) { _, _ in suggestBinding() }
        .onChange(of: model.snapshot.code) { _, _ in suggestBinding() }
        .onChange(of: sheet?.id) { _, value in if value == nil { suggestBinding() } }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: sheet?.id)
        .accessibilityIdentifier("referral-page")
    }

    private func text(_ key: String, _ size: CGFloat = 14, _ weight: Int = 400, _ color: Color? = nil, args: [String] = []) -> ReferralText {
        ReferralText(value: copy.format(key, args), size: size, weight: weight, color: color ?? c.ink)
    }
    private func open(_ kind: ReferralSheetKind, task: ReferralTask = .invite, cardID: Int64? = nil) {
        sheet = ReferralSheetSelection(kind: kind, task: task, cardID: cardID)
    }
    private var topBar: some View {
        HStack(spacing: 0) {
            ReferralIconButton(glyph: .back, label: copy.text("back"), palette: c) { dismiss() }
            ReferralText(value: "Pixiv-Shaft", size: 12, weight: 500, color: c.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
            text("preview", 9, 400, c.muted)
            ReferralIconButton(glyph: .moon, label: copy.text("switch_theme"), palette: c) { darkOverride = !c.dark }
                .accessibilityIdentifier("referral-theme")
        }.padding(.leading, 6).padding(.trailing, 10).frame(minHeight: 64)
    }
    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 0) {
            text(model.loading || model.error != nil ? "heading" : "closed_title", 28, 700)
                .accessibilityAddTraits(.isHeader)
            text(model.loading ? "loading" : model.error?.messageKey ?? "closed_desc", 13, 400, c.muted).padding(.top, 12)
            if model.error != nil {
                ReferralButton(label: copy.text("retry"), palette: c, primary: true, expand: false) {
                    Task { await model.refresh(); suggestBinding() }
                }.padding(.top, 20)
            }
        }
    }
    private var heading: some View {
        VStack(alignment: .leading, spacing: 0) {
            let headerLayout = fontScale > 1.3 ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout())
            headerLayout {
                ReferralText(value: copy.text("eyebrow"), size: 8, weight: 700, color: c.primary, tracking: 1.44)
                if fontScale <= 1.3 { Spacer(minLength: 0) }
                Button { open(.rules) } label: {
                    HStack(spacing: 10) {
                        text("rules", 10, 600, c.onTint)
                        ReferralIcon(glyph: .arrow).stroke(c.onTint, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)).frame(width: 16, height: 16)
                    }.frame(minHeight: 48).contentShape(Rectangle())
                }.buttonStyle(ReferralPressStyle())
            }.frame(height: fontScale > 1.3 ? nil : 18)
            ReferralText(value: copy.text("heading"), size: 28, weight: 700, color: c.ink, headingStar: true)
                .accessibilityAddTraits(.isHeader).padding(.top, 9)
            text("intro", 12, 400, c.muted).padding(.top, 10)
        }
    }
    private func content(wide: Bool, width: CGFloat, scroll: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            heading
            if (s.campaigns ?? []).count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(s.campaigns ?? [], id: \.self) { campaign in
                            ReferralButton(label: copy.text("campaign", campaign), palette: c, outline: true, expand: false) {
                                Task { await model.chooseCampaign(campaign) }
                            }.disabled(s.campaign == campaign || model.busy)
                        }
                    }
                }.padding(.top, 14)
            }
            if let error = model.error {
                note(copy.text(error.messageKey)).padding(.top, 12)
                ReferralButton(label: copy.text("retry"), palette: c) { Task { await model.refresh() } }.padding(.top, 8)
            }
            if s.enabled != true { note(copy.text("closed_banner")).padding(.top, 16) }
            if s.inviteRejected { note(copy.text("bound_rejected"), danger: true).padding(.top, 16) }
            hero(wide: wide, width: width - (wide ? 72 : 40)).padding(.top, 23)
            if wide {
                HStack(alignment: .top, spacing: 30) {
                    tasks(scroll: scroll).frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 28) { rewards; journey }.frame(width: 288)
                }.padding(.top, 29)
            } else {
                rewards.padding(.top, 29)
                tasks(scroll: scroll).padding(.top, 32)
                journey.padding(.top, 28)
            }
            footer.padding(.top, 24)
        }
    }
    private var heroActions: some View {
        VStack(alignment: .leading, spacing: 0) {
            if s.inviteUrl?.isEmpty == false {
                ReferralButton(label: copy.text("invite_action"), palette: c, primary: true, icon: .arrow, expand: false) { open(.invite) }
            }
            ReferralText(value: copy.text("hero_note"), size: 12, color: c.onHero, lineHeight: 12 * 1.7).padding(.top, 12)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func heroCopy(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ReferralText(value: "•  " + copy.text("hero_tag"), size: 9, weight: 500, color: c.onTint)
                .padding(.horizontal, 11).padding(.vertical, 7).background(c.bg, in: Capsule())
            ReferralText(value: copy.text("hero_title"), size: wide ? 36 : 31, weight: 800, color: c.ink, lineHeight: (wide ? 36 : 31) * 1.4)
                .padding(.top, 15).accessibilityAddTraits(.isHeader)
            ReferralText(value: copy.text("hero_body"), size: 12, color: c.onHero, lineHeight: 12 * 1.95).padding(.top, 13)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func hero(wide: Bool, width: CGFloat) -> some View {
        Group {
            if wide && fontScale <= 1.1 {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 24) { heroCopy(wide: true); heroActions }
                        .padding(.leading, 36).padding(.trailing, 24).padding(.top, 26).padding(.bottom, 25)
                        .frame(maxWidth: .infinity)
                    ReferralHeroArt(palette: c, copy: copy).frame(maxWidth: .infinity).frame(height: 320).padding(.trailing, 24)
                }
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    heroCopy(wide: wide)
                    if width - 48 >= 208 + 112 * fontScale {
                        HStack(spacing: 12) {
                            heroActions
                            ReferralHeroArt(palette: c, copy: copy).frame(width: 196, height: 180)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 16) {
                            heroActions
                            ReferralHeroArt(palette: c, copy: copy).frame(height: 220)
                        }
                    }
                }.padding(.horizontal, 24).padding(.top, 26).padding(.bottom, 25)
            }
        }.background(c.hero, in: RoundedRectangle(cornerRadius: 26, style: .circular))
            .accessibilityIdentifier("referral-hero")
    }
    private func section(_ title: String, _ subtitle: String, _ count: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                text(title, 19, 700).accessibilityAddTraits(.isHeader)
                ReferralText(value: count, size: 12, color: c.muted)
            }
            text(subtitle, 12, 400, c.muted)
        }
    }
    private var rewards: some View {
        VStack(alignment: .leading, spacing: 24) {
            summary
            VStack(alignment: .leading, spacing: 0) {
                section("wallet", "wallet_subtitle", String(format: "%02d", s.cards.count))
                if (s.activeUntil ?? 0) > now {
                    note(copy.text("active_until", copy.date(s.activeUntil ?? 0, time: true))).padding(.top, 20)
                }
                if s.cards.isEmpty {
                    empty("wallet_empty", "wallet_empty_desc", args: [String(s.currentRules.cardValidDays ?? 30)]).padding(.top, 16)
                }
                ForEach(s.cards) { card in walletCard(card).padding(.top, 16) }
            }.id("referral-wallet").accessibilityIdentifier("referral-wallet")
        }
    }
    private var summary: some View {
        VStack(alignment: .leading, spacing: 0) {
            text("summary", 14, 600)
            HStack(alignment: .bottom, spacing: 8) {
                ReferralText(value: String(s.earnedDays), size: 55, weight: 600, color: c.ink).monospacedDigit()
                text("earned", 12, 400, c.muted)
            }.padding(.top, 18)
            HStack(alignment: .top, spacing: 0) {
                statistic(s.effective ?? 0, "effective")
                statistic(s.cards.filter { $0.usable(at: now) }.count, "unused")
                statistic(s.claimable, "unclaimed")
            }.padding(.top, 18)
            text("expiry_hint", 11, 400, c.muted, args: [String(s.currentRules.cardValidDays ?? 30)])
                .frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(.top, 13)
        }.referralCard(c, horizontal: 22, vertical: 22)
    }
    private func statistic(_ count: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ReferralText(value: String(count), size: 19, weight: 500, color: c.ink)
            text(label, 11, 400, c.muted)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func walletCard(_ card: ReferralReward) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            text(card.duration <= 7 ? "card_week" : "card_month", 18, 600, args: [referralPlanLabel(card.plan)])
            text("card_from", 12, 400, c.muted, args: [copy.text(card.kind?.titleKey ?? "welcome_title")]).padding(.top, 10)
            text(card.activated ? "card_active" : card.usable(at: now) ? "card_deadline" : "card_expired", 12, 400, c.muted,
                 args: [copy.date(card.activated ? card.activatedAt ?? 0 : card.expiresAt ?? 0, time: true)]).padding(.top, 10)
            if card.usable(at: now) {
                ReferralButton(label: copy.text("activate", String(card.duration), referralPlanLabel(card.plan)), palette: c, primary: true) {
                    open(.activate, task: card.kind ?? .invite, cardID: card.id)
                }.disabled(model.busy).padding(.top, 16)
            }
        }.referralCard(c)
    }
    private func tasks(scroll: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            section("tasks", "tasks_subtitle", "04")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(ReferralFilter.allCases, id: \.self) { item in
                        Button { filter = item } label: {
                            ReferralText(value: copy.text(item.rawValue) + (item == .all ? "  4" : item == .ready ? "  \(s.claimable)" : ""), size: 12, weight: 600, color: filter == item ? c.ink : c.muted)
                                .padding(.horizontal, 14).padding(.vertical, 8).frame(minHeight: 48)
                                .background(filter == item ? c.surface : .clear, in: Capsule())
                        }.buttonStyle(ReferralPressStyle()).accessibilityAddTraits(filter == item ? .isSelected : [])
                    }
                }.padding(5).background(c.surface2, in: Capsule())
            }.padding(.top, 19)
            if visibleTasks.isEmpty {
                empty(filter == .ready ? "empty_ready" : "empty_progress", filter == .ready ? "empty_ready_desc" : "empty_progress_desc", action: { filter = .all }).padding(.top, 13)
            }
            ForEach(visibleTasks) { task in
                taskCard(task) {
                    if s.status(task) == .claimed { scroll.scrollTo("referral-wallet", anchor: .top) }
                    else { open(s.status(task) == .ready ? .claim : .task, task: task) }
                }.padding(.top, 12)
            }
            HStack(spacing: 6) {
                ReferralIcon(glyph: .heart).stroke(c.muted, lineWidth: 1.7).frame(width: 13, height: 13)
                text("gentle", 10, 400, c.muted)
            }.frame(maxWidth: .infinity).padding(.vertical, 8).padding(.top, 16)
        }
    }
    private var visibleTasks: [ReferralTask] {
        ReferralTask.listed.filter {
            filter == .all || (filter == .ready ? s.status($0) == .ready : [.progress, .pending, .rejected].contains(s.status($0)))
        }
    }
    private func taskCard(_ task: ReferralTask, action: @escaping () -> Void) -> some View {
        let state = s.status(task)
        let foreground = task == .invite ? c.green : task == .circle ? c.blue : task == .tutorial ? c.peach : c.onTint
        let background = task == .invite ? c.greenBg : task == .circle ? c.blueBg : task == .tutorial ? c.peachBg : c.tint
        return VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .top, spacing: 0) {
                ReferralIcon(glyph: task == .invite ? .user : task == .circle ? .heart : task == .tutorial ? .play : .stack)
                    .stroke(foreground, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                    .frame(width: 20, height: 20).frame(width: 40, height: 40)
                    .background(background, in: RoundedRectangle(cornerRadius: task == .invite ? 20 : 14, style: .circular)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    ReferralText(value: copy.text(task.rawValue + "_category") + " · " + copy.text(state.labelKey), size: 11, color: state == .ready ? c.green : c.muted)
                    text(task.titleKey, 15, 600).padding(.top, 6)
                    ReferralText(value: copy.text(task.rawValue + "_description"), size: 12, color: c.muted, lineHeight: 12 * 1.8).padding(.top, 7)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 11)
                text("days", 12, 700, c.onTint, args: [String(s.task(task)?.days ?? 7)])
                    .padding(7).background(c.surface2, in: RoundedRectangle(cornerRadius: 10, style: .circular))
                    .fixedSize(horizontal: fontScale <= 1.3, vertical: true)
            }
            let layout = fontScale > 1.3 ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
            layout {
                progress(task).frame(maxWidth: .infinity)
                ReferralButton(label: copy.text(state.actionKey), palette: c, primary: state == .ready, icon: state == .ready ? .ticket : .arrow, expand: false, action: action)
                    .accessibilityLabel(copy.text(state.actionKey) + "：" + copy.text(task.titleKey)).disabled(model.busy)
            }
        }.referralCard(c)
    }
    private func progress(_ task: ReferralTask) -> some View {
        let status = s.status(task)
        let key = [.pending, .rejected, .claimed].contains(status) ? "status_\(status.rawValue)" : task.rawValue + "_caption"
        return VStack(spacing: 8) {
            HStack(spacing: 0) {
                text(key, 11, 400, c.muted).frame(maxWidth: .infinity, alignment: .leading)
                text("progress_format", 11, args: [String(s.progress(task)), String(s.target(task))])
            }
            GeometryReader { geometry in
                Capsule().fill(c.surface3)
                Capsule().fill(status == .ready ? c.green : c.primary)
                    .frame(width: geometry.size.width * min(1, CGFloat(s.progress(task)) / CGFloat(s.target(task))))
            }.frame(height: 4).accessibilityHidden(true)
        }
    }
    private var journey: some View {
        VStack(alignment: .leading, spacing: 0) {
            ReferralText(value: copy.text("journey_eyebrow"), size: 8, weight: 700, color: c.primary, tracking: 0.8)
            text("journey_title", 21, 700).padding(.top, 10).accessibilityAddTraits(.isHeader)
            ForEach(1...3, id: \.self) { index in
                HStack(alignment: .top, spacing: 13) {
                    ReferralText(value: "0\(index)", size: 10, weight: 500, color: c.primary)
                        .frame(width: 29, height: 29).background(c.bg, in: Circle()).overlay(Circle().strokeBorder(c.line, lineWidth: 1))
                    VStack(alignment: .leading, spacing: 6) {
                        text("step\(index)", 13, 600)
                        text("step\(index)_desc", 12, 400, c.muted)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.top, 24)
            }
            Button { open(.materials) } label: {
                HStack(spacing: 10) {
                    text("materials", 12, 600, c.onTint)
                    ReferralIcon(glyph: .arrow).stroke(c.onTint, lineWidth: 1.7).frame(width: 16, height: 16)
                }.frame(maxWidth: .infinity, minHeight: 48)
            }.buttonStyle(ReferralPressStyle()).padding(.top, 16)
        }.padding(.horizontal, 10)
    }
    private var footer: some View {
        VStack(spacing: 0) {
            c.line.frame(height: 1)
            text("footer", 10, 400, c.muted).multilineTextAlignment(.center).padding(.top, 22)
            if s.inviterUID == nil && s.enabled == true && s.task(.invite)?.enabled != false {
                ReferralButton(label: copy.text("bind_entry"), palette: c, outline: true) { open(.bind) }.padding(.top, 10)
            } else if !s.inviteRejected, let uid = s.inviterUID {
                text("bound_already", 10, 400, c.muted, args: [String(uid)]).padding(.top, 10)
            }
        }
    }
    private func note(_ value: String, danger: Bool = false) -> some View {
        ReferralText(value: value, size: 12, color: danger ? c.danger : c.muted)
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(c.surface2, in: RoundedRectangle(cornerRadius: 16, style: .circular))
    }
    private func empty(_ title: String, _ description: String, args: [String] = [], action: (() -> Void)? = nil) -> some View {
        VStack(spacing: 0) {
            ReferralText(value: "✧", size: 40, color: c.primary).accessibilityHidden(true)
            text(title, 16, 600).padding(.top, 12)
            text(description, 13, 400, c.muted, args: args).padding(.top, 10)
            if let action { ReferralButton(label: copy.text("go_tasks"), palette: c, primary: true, action: action).padding(.top, 20) }
        }.frame(maxWidth: .infinity).multilineTextAlignment(.center).referralCard(c, horizontal: 24, vertical: 36)
    }
    private func suggestBinding() {
        guard sheet == nil, let code = bindingPrompt.suggestion(
            snapshot: s, loading: model.loading,
            uid: s.uid ?? KeychainTokenStore.shared.load()?.user?.id ?? 0,
            initialCode: initialCode, clipboard: readClipboard
        ) else { return }
        sheet = ReferralSheetSelection(kind: .bind, code: code)
    }
}
