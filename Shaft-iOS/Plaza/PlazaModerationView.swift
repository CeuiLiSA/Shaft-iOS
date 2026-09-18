import SwiftUI
import PhotosUI

struct PlazaReportView: View {
    let post: PlazaPost
    let store: PlazaStore
    @State private var model: PlazaComposerModel
    @State private var type = "post"
    @State private var reason = ""
    @State private var selection: [PhotosPickerItem] = []
    @State private var receipt: PlazaReportReceipt?
    @State private var busy = false
    @Environment(\.dismiss) private var dismiss
    @Environment(OnboardingStore.self) private var language
    private var copy: PlazaCopy { .init(tag: language.activeTag) }
    private let reasons = ["child_safety", "sexual", "violence", "hate", "harassment", "privacy", "advertising", "spam", "illegal", "other"]
    init(post: PlazaPost, store: PlazaStore) {
        self.post = post; self.store = store
        _model = State(initialValue: PlazaComposerModel(uid: store.uid, draftKey: "report-\(post.id)"))
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let receipt {
                    PlazaStateView(text: copy.format(receipt.status == "pending" ? "report_success" : "report_reviewed", String(receipt.id)),
                                   actionTitle: copy.text("report_finish")) { dismiss() }
                } else {
                    PlazaText(value: copy.text("report_notice"), color: Theme.v3Text2)
                    VStack(alignment: .leading, spacing: 12) {
                        PlazaSectionLabel(text: copy.text("report_target_label"))
                        Picker(copy.text("report_target_label"), selection: $type) {
                            Text(copy.text("report_post")).tag("post")
                            Text(copy.text("report_user")).tag("user")
                        }.pickerStyle(.segmented)
                        PlazaSectionLabel(text: copy.text("report_reason_label"))
                        ForEach(Array(reasons.enumerated()), id: \.element) { index, item in
                            Button { reason = item } label: {
                                HStack {
                                    PlazaText(value: copy.text("report_reasons_\(index)"), size: 15)
                                    Spacer()
                                    Image(systemName: reason == item ? "checkmark.circle.fill" : "circle").foregroundStyle(PlazaPalette.accent)
                                }.frame(minHeight: 44).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityAddTraits(reason == item ? .isSelected : [])
                        }
                    }.plazaCard()
                    VStack(alignment: .leading, spacing: 8) {
                        PlazaSectionLabel(text: copy.text("report_details_label"))
                        TextEditor(text: Binding(get: { model.draft.text }, set: { value in model.edit { $0.text = value } }))
                            .font(.custom("Montserrat-Regular", size: 15)).frame(minHeight: 110).scrollContentBackground(.hidden)
                            .accessibilityLabel(copy.text("report_details_hint"))
                        PlazaText(value: "\(model.draft.text.unicodeScalars.count) / 1000", size: 12, color: Theme.v3Text3).frame(maxWidth: .infinity, alignment: .trailing)
                    }.plazaCard()
                    VStack(alignment: .leading, spacing: 12) {
                        PlazaSectionLabel(text: copy.text("report_photos_label"))
                        PlazaText(value: copy.text("report_photos_hint"), size: 12, color: Theme.v3Text2)
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                ForEach(model.draft.images) { image in
                                    ZStack(alignment: .topTrailing) {
                                        PlazaLocalThumbnail(url: model.directory.appendingPathComponent(image.fileName))
                                            .frame(width: 80, height: 80).clipped().clipShape(RoundedRectangle(cornerRadius: 12))
                                        Button { model.remove(image) } label: { PlazaIcon(glyph: .close).frame(width: 40, height: 40).background(.ultraThinMaterial, in: Circle()) }
                                            .accessibilityLabel(copy.text("discard"))
                                    }
                                }
                                if model.draft.images.count < 3 {
                                    PhotosPicker(selection: $selection, maxSelectionCount: 3 - model.draft.images.count, matching: .images, preferredItemEncoding: .compatible) {
                                        PlazaIcon(glyph: .add).frame(width: 80, height: 80).background(PlazaPalette.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                                    }.accessibilityLabel(copy.format("add_photos", "3"))
                                }
                            }
                        }
                    }.plazaCard()
                    if let error = model.error { PlazaText(value: copy.error(error), color: Theme.v3Danger) }
                    Button { submit() } label: {
                        HStack {
                            if busy { ProgressView().tint(.white) }
                            PlazaText(value: copy.text(busy ? "report_sending" : "report_submit"), weight: 600, color: .white)
                        }.frame(maxWidth: .infinity, minHeight: 48).background(PlazaPalette.primary, in: Capsule())
                    }.disabled(reason.isEmpty || busy || model.importing || model.draft.text.unicodeScalars.count > 1000)
                }
            }.padding(16).frame(maxWidth: 720).frame(maxWidth: .infinity)
                .disabled(busy)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            PlazaToolbar(back: { if !busy { dismiss() } }) {
                PlazaText(value: copy.text("report_title"), size: 18, color: .white)
            } trailing: { EmptyView() }
        }.background(Theme.v3Bg).interactiveDismissDisabled(busy)
            .onChange(of: selection) { _, items in
                if !items.isEmpty { Task { await model.importPhotos(items, limit: 3); selection = [] } }
            }
    }
    private func submit() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                model.error = nil
                let ids = try await model.reportMedia(store: store)
                let result = try await store.api.report(uid: store.uid, id: post.id,
                    body: .init(targetType: type, reason: reason, details: model.draft.text.trimmingCharacters(in: .whitespacesAndNewlines), mediaIds: ids))
                try store.check(); receipt = result; model.discard()
            } catch { model.error = error }
        }
    }
}

struct PlazaBlocksView: View {
    let store: PlazaStore
    @State private var users: [PlazaBlockedUser] = []
    @State private var loading = true
    @State private var error: Error?
    @Environment(OnboardingStore.self) private var language
    @Environment(\.dismiss) private var dismiss
    private var copy: PlazaCopy { .init(tag: language.activeTag) }
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                PlazaText(value: copy.text("blocks_notice"), color: Theme.v3Text2).frame(maxWidth: .infinity, alignment: .leading).plazaCard()
                if loading { ProgressView().padding(40) }
                else if let error {
                    PlazaStateView(text: copy.error(error), error: true, actionTitle: copy.text("retry")) { Task { await load() } }
                } else if users.isEmpty { PlazaStateView(text: copy.text("blocks_empty")) }
                ForEach(users) { user in
                    HStack(spacing: 12) {
                        PlazaText(value: String(user.displayName.prefix(1)), size: 22, weight: 600, color: PlazaPalette.accent)
                            .frame(width: 48, height: 48).background(PlazaPalette.primary.opacity(0.12), in: Circle())
                        VStack(alignment: .leading, spacing: 4) {
                            PlazaText(value: user.displayName, size: 15, weight: 600)
                            PlazaText(value: "UID \(user.uid)", size: 12, color: Theme.v3Text2)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            Task { await store.block(user.uid, selected: false); if store.failure == nil { await load() } }
                        } label: {
                            PlazaText(value: copy.text("unblock_action"), size: 13, weight: 600, color: PlazaPalette.accent)
                                .padding(.horizontal, 12).frame(minHeight: 48).background(PlazaPalette.primary.opacity(0.08), in: Capsule())
                        }.frame(maxWidth: 150).disabled(store.busy)
                    }.plazaCard()
                }
            }.padding(16).frame(maxWidth: 720).frame(maxWidth: .infinity)
        }.refreshable { await load() }
            .safeAreaInset(edge: .top, spacing: 0) {
                PlazaToolbar(back: { dismiss() }) { PlazaText(value: copy.text("blocked_users"), size: 18, color: .white) } trailing: { EmptyView() }
            }.task { await load() }.plazaErrorAlert(store: store, copy: copy).plazaScreen()
    }
    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do { try store.check(); let result = try await store.api.blocks(uid: store.uid); try store.check(); users = result.items }
        catch { self.error = error }
    }
}
