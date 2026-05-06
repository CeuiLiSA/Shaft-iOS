import SwiftUI

/// Sheet for bookmarking with explicit restrict (public/private) and a tag
/// list. Mirrors Pixiv-Shaft's "bookmark with tags" flow.
///
/// `existingTags` are the work's own tags shown as quick-pick chips so the
/// user can compose the bookmark tag list with one tap per tag.
struct BookmarkTagsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(OnboardingStore.self) private var l10n

    let existingTags: [String]
    let onSave: (_ restrict: String, _ tags: [String]) async -> Void

    @State private var draftTags: String = ""
    @State private var restrict: String = "public"
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section(l10n.t(.bookmarkRestrictTitle)) {
                    Picker("", selection: $restrict) {
                        Text(l10n.t(.bookmarkPublic)).tag("public")
                        Text(l10n.t(.bookmarkPrivate)).tag("private")
                    }
                    .pickerStyle(.segmented)
                }

                Section(l10n.t(.bookmarkTagsTitle)) {
                    TextField(l10n.t(.bookmarkTagsPlaceholder), text: $draftTags, axis: .vertical)
                        .lineLimit(1...4)
                        .textInputAutocapitalization(.never)
                }

                if !existingTags.isEmpty {
                    Section(l10n.t(.bookmarkTagsSuggested)) {
                        FlowLayout(spacing: 6) {
                            ForEach(Array(existingTags.enumerated()), id: \.offset) { _, tag in
                                Button {
                                    addTag(tag)
                                } label: {
                                    Text("#\(tag)")
                                        .font(.caption.bold())
                                        .padding(.horizontal, 8).padding(.vertical, 5)
                                        .background(Color(.secondarySystemBackground), in: .capsule)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .navigationTitle(l10n.t(.bookmarkAction))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(l10n.t(.actionCancel)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(l10n.t(.actionDone)) {
                        Task {
                            isSaving = true
                            await onSave(restrict, parsedTags)
                            isSaving = false
                            dismiss()
                        }
                    }
                    .disabled(isSaving)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var parsedTags: [String] {
        draftTags
            .split(whereSeparator: { ",;\n ".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func addTag(_ tag: String) {
        if parsedTags.contains(tag) { return }
        if draftTags.isEmpty {
            draftTags = tag
        } else {
            draftTags += ", \(tag)"
        }
    }
}
