import SwiftUI
import PhotosUI

struct PlazaComposeView: View {
    let store: PlazaStore
    var onSent: (PlazaPost) -> Void
    @State private var model: PlazaComposerModel
    @State private var selection: [PhotosPickerItem] = []
    @State private var discarding = false
    @State private var policy = false
    @State private var reference = false
    @State private var objectType = "illust"
    @State private var objectID = ""
    @State private var referenceError = false
    @Environment(\.dismiss) private var dismiss
    @Environment(OnboardingStore.self) private var language
    private var copy: PlazaCopy { .init(tag: language.activeTag) }
    init(store: PlazaStore, model: PlazaComposerModel? = nil, onSent: @escaping (PlazaPost) -> Void) {
        self.store = store; self.onSent = onSent
        _model = State(initialValue: model ?? PlazaComposerModel(uid: store.uid))
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                textCard
                photosCard
                referenceRow
                if let error = model.error { PlazaText(value: copy.error(error), size: 13, weight: 500, color: Theme.v3Danger).padding(.horizontal, 4) }
                if model.draft.title.unicodeScalars.count > 120 {
                    PlazaText(value: copy.format("title_limit", "120"), size: 13, color: Theme.v3Danger)
                }
                if model.draft.text.unicodeScalars.count > 2000 {
                    PlazaText(value: copy.format("body_limit", "2000"), size: 13, color: Theme.v3Danger)
                }
            }.padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 24)
                .frame(maxWidth: 720).frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .top, spacing: 0) {
            PlazaToolbar(back: close, backID: "plaza-compose-back") {
                PlazaText(value: copy.text("compose_title"), size: 18, color: .white)
            } trailing: {
                Button {
                    if PlazaPolicy.accepted(uid: store.uid) { publish() } else { policy = true }
                } label: {
                    if model.sending { ProgressView().tint(.white).frame(width: 56, height: 48) }
                    else { PlazaText(value: copy.text("send_post"), size: 14, weight: 600, color: .white).padding(.horizontal, 12).frame(minHeight: 48) }
                }.disabled(!model.canSend || store.busy).opacity(model.canSend ? 1 : 0.5)
                    .accessibilityIdentifier("plaza-publish")
            }
        }
        .background(Theme.v3Bg).tint(PlazaPalette.accent)
        .interactiveDismissDisabled(!model.draft.isEmpty || model.sending || model.importing)
        .alert(copy.text("discard_confirm"), isPresented: $discarding) {
            Button(copy.text("discard"), role: .destructive) { model.discard(); dismiss() }
            Button(copy.text("keep_editing"), role: .cancel) {}
        }
        .alert(copy.text("policy_title"), isPresented: $policy) {
            Button(copy.text("cancel"), role: .cancel) {}
            Button(copy.text("policy_accept")) {
                do { try PlazaPolicy.accept(uid: store.uid); publish() } catch { model.error = error }
            }
        } message: { Text(copy.text("policy_body")) }
        .sheet(isPresented: $reference) { referenceSheet }
        .task { await model.loadAvatar() }
        .onChange(of: selection) { _, items in
            guard !items.isEmpty else { return }
            Task { await model.importPhotos(items); selection = [] }
        }
    }
    private var textCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            PlazaSectionLabel(text: copy.text("title_label"))
            TextField(copy.text("title_hint"), text: Binding(get: { model.draft.title }, set: { value in model.edit { $0.title = value } }))
                .font(.custom("Montserrat-SemiBold", size: 20)).foregroundStyle(Theme.v3Text1)
                .frame(minHeight: 44).padding(.top, 2).accessibilityIdentifier("plaza-title-input")
            Rectangle().fill(PlazaPalette.hairline).frame(height: 0.5).padding(.top, 8).padding(.bottom, 14)
            PlazaSectionLabel(text: copy.text("body_label"))
            ZStack(alignment: .topLeading) {
                if model.draft.text.isEmpty {
                    PlazaText(value: copy.text("body_hint"), size: 15, color: Theme.v3Text3).padding(.top, 8)
                }
                PlazaTextEditor(text: Binding(get: { model.draft.text }, set: { value in model.edit { $0.text = value } }))
                    .accessibilityLabel(copy.text("body_label")).accessibilityIdentifier("plaza-body-input")
            }.padding(.top, 2)
            PlazaText(value: copy.format("char_count", String(model.draft.text.unicodeScalars.count), "2000"), size: 12, weight: 500, color: Theme.v3Text3)
                .monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing).padding(.top, 8)
        }.plazaCard().disabled(model.sending)
    }
    private var photosCard: some View {
        let importing = model.importing
        return VStack(alignment: .leading, spacing: 12) {
            PlazaSectionLabel(text: copy.format("photos_count", String(model.draft.images.count), "9"))
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    if model.draft.images.count < 9 {
                        PhotosPicker(selection: $selection, maxSelectionCount: 9 - model.draft.images.count,
                                     selectionBehavior: .ordered, matching: .images, preferredItemEncoding: .compatible) {
                            Group {
                                if importing { ProgressView() }
                                else { PlazaIcon(glyph: .add).foregroundStyle(PlazaPalette.accent) }
                            }.frame(width: 80, height: 80)
                                .background(PlazaPalette.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(PlazaPalette.primary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 3])) }
                        }.accessibilityLabel(copy.format("add_photos", "9")).accessibilityIdentifier("plaza-add-photos")
                    }
                    ForEach(Array(model.draft.images.enumerated()), id: \.element.id) { index, image in
                        ZStack(alignment: .topTrailing) {
                            PlazaLocalThumbnail(url: model.directory.appendingPathComponent(image.fileName))
                                .frame(width: 80, height: 80).clipped().clipShape(RoundedRectangle(cornerRadius: 12))
                            Button { model.remove(image) } label: {
                                PlazaIcon(glyph: .close, size: 14).foregroundStyle(PlazaPalette.accent).frame(width: 22, height: 22)
                                    .background(PlazaPalette.card.opacity(0.92), in: Circle()).padding(4)
                                    .frame(width: 40, height: 40, alignment: .topTrailing)
                            }.accessibilityLabel(copy.format("remove_photo", String(index + 1)))
                            if image.mediaId != nil || model.progress[image.id] != nil {
                                PlazaText(value: image.mediaId != nil ? copy.text("uploaded") : "\(Int((model.progress[image.id] ?? 0) * 100))%", size: 11, weight: 600, color: .white)
                                    .frame(width: 80, height: 20).background(PlazaPalette.primary)
                                    .frame(maxHeight: .infinity, alignment: .bottom)
                            }
                        }.frame(width: 80, height: 80)
                    }
                }
            }.scrollIndicators(.hidden).frame(height: 80)
        }.plazaCard().disabled(model.sending || model.importing)
    }
    private var referenceRow: some View {
        Button {
            objectType = model.draft.objectType ?? "illust"; objectID = model.draft.objectId.map(String.init) ?? ""
            referenceError = false; reference = true
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    PlazaText(value: copy.text("reference_section"), size: 15, weight: 500)
                    if model.draft.objectId == nil { PlazaText(value: copy.text("reference_hint"), size: 12, color: Theme.v3Text3) }
                    if let id = model.draft.objectId {
                        Button { model.edit { $0.objectId = nil; $0.objectType = nil } } label: {
                            PlazaText(value: copy.format("reference_removable", copy.text("object_\(model.draft.objectType ?? "illust")"), String(id)), size: 13, weight: 600, color: PlazaPalette.accent)
                                .padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 40)
                        }.buttonStyle(.plain)
                            .accessibilityLabel(copy.format("remove_reference", copy.text("object_\(model.draft.objectType ?? "illust")"), String(id)))
                            .background(PlazaPalette.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(PlazaPalette.primary.opacity(0.15), lineWidth: 0.5) }.padding(.top, 4)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                PlazaIcon(glyph: .chevron, size: 22).foregroundStyle(Theme.v3Text3)
            }.padding(.leading, 16).padding(.trailing, 12).padding(.vertical, 14).frame(minHeight: 64)
                .background(PlazaPalette.card, in: RoundedRectangle(cornerRadius: 20))
                .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(PlazaPalette.hairline, lineWidth: 0.5) }
        }.buttonStyle(PlazaPressStyle()).disabled(model.sending)
    }
    private var referenceSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            PlazaText(value: copy.text("reference_section"), size: 20, weight: 600)
            Picker(copy.text("reference_section"), selection: $objectType) {
                ForEach(["illust", "manga", "novel", "user"], id: \.self) { type in Text(copy.text("object_" + type)).tag(type) }
            }.pickerStyle(.segmented)
            TextField(copy.text("id_hint"), text: $objectID).keyboardType(.numberPad).textFieldStyle(.roundedBorder)
            if referenceError { PlazaText(value: copy.text("id_invalid"), color: Theme.v3Danger) }
            Button(copy.text("add_reference")) {
                guard let id = Int64(objectID.trimmingCharacters(in: .whitespacesAndNewlines)), id > 0, id <= 9_007_199_254_740_991 else { referenceError = true; return }
                model.edit { $0.objectType = objectType; $0.objectId = id }; reference = false
            }.buttonStyle(.borderedProminent).frame(minHeight: 48)
            Spacer(minLength: 0)
        }.padding(24).presentationDetents([.medium]).presentationDragIndicator(.visible)
            .background(Theme.v3MenuBg)
    }
    private func close() {
        guard !model.sending, !model.importing else { return }
        if model.draft.isEmpty { dismiss() } else { discarding = true }
    }
    private func publish() { Task { if let post = await model.send(store: store) { onSent(post) } } }
}

struct PlazaLocalThumbnail: View {
    let url: URL
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            PlazaPalette.primary.opacity(0.08)
            if let image { Image(uiImage: image).resizable().scaledToFill() }
        }.task(id: url) {
            image = await Task.detached(priority: .userInitiated) { PlazaPhotoFiles.thumbnail(url).map { UIImage(cgImage: $0) } }.value
        }
    }
}

/// UITextView expands like Android's wrap_content EditText instead of nesting a
/// second scrolling editor inside the compose page. Insets match field().
struct PlazaTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric private var size: CGFloat = 15
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.isScrollEnabled = false
        view.textContainerInset = UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.delegate = context.coordinator
        view.autocapitalizationType = .sentences
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        view.isEditable = isEnabled
        view.font = UIFont(name: "Montserrat-Regular", size: size) ?? .systemFont(ofSize: size)
        view.textColor = UIColor(Theme.v3Text1)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = size * 1.7; paragraph.maximumLineHeight = size * 1.7
        view.typingAttributes = [.font: view.font!, .foregroundColor: view.textColor!, .paragraphStyle: paragraph]
        if view.text != text { view.attributedText = NSAttributedString(string: text, attributes: view.typingAttributes) }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return CGSize(width: width, height: max(200, uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height))
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PlazaTextEditor
        init(_ parent: PlazaTextEditor) { self.parent = parent }
        func textViewDidChange(_ view: UITextView) { parent.text = view.text; view.invalidateIntrinsicContentSize() }
    }
}
