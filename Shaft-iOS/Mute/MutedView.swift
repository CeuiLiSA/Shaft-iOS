import SwiftUI

struct MutedView: View {
    @State private var store = MuteStore.shared
    @State private var section: Section = .users
    @State private var newTag: String = ""
    @Environment(OnboardingStore.self) private var l10n

    enum Section: Hashable, CaseIterable { case users, tags }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $section) {
                Text(l10n.t(.muteUsers)).tag(Section.users)
                Text(l10n.t(.muteTags)).tag(Section.tags)
            }
            .pickerStyle(.segmented)
            .padding(8)

            if section == .tags {
                HStack {
                    TextField(l10n.t(.muteAddTag), text: $newTag)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        let trimmed = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        if !store.mutedTags.contains(trimmed) { store.toggleTag(trimmed) }
                        newTag = ""
                    } label: {
                        Image(systemName: "plus.circle.fill").font(.title2)
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 8)
            }

            List {
                if section == .users {
                    if store.mutedUserIDs.isEmpty {
                        ContentUnavailableView(l10n.t(.nothingHere), systemImage: "speaker.slash")
                    }
                    ForEach(Array(store.mutedUserIDs).sorted(), id: \.self) { id in
                        NavigationLink(value: AppRoute.userProfile(id)) {
                            HStack {
                                Text("User #\(id)")
                                Spacer()
                                Button(role: .destructive) {
                                    store.toggleUser(id)
                                } label: {
                                    Image(systemName: "speaker.wave.2")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                } else {
                    if store.mutedTags.isEmpty {
                        ContentUnavailableView(l10n.t(.nothingHere), systemImage: "tag.slash")
                    }
                    ForEach(Array(store.mutedTags).sorted(), id: \.self) { tag in
                        HStack {
                            Text("#\(tag)")
                            Spacer()
                            Button(role: .destructive) {
                                store.toggleTag(tag)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
        .navigationTitle(l10n.t(.mutedTitle))
        .navigationBarTitleDisplayMode(.inline)
    }
}
