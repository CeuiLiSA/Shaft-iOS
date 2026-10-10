import SwiftUI

enum AIExemptAuthors {
    static func enabled(ids: [Int64], disabled: Set<Int64>) -> Set<Int64> {
        Set(ids.filter { $0 > 0 }).subtracting(disabled)
    }
    static func normalized(_ ids: [Int64]) -> [Int64] {
        var seen = Set<Int64>()
        return ids.filter { $0 > 0 && seen.insert($0).inserted }
    }
    static func current(defaults: UserDefaults = .standard) -> Set<Int64> {
        enabled(ids: defaults.array(forKey: "st_aiBlockExemptAuthorIds") as? [Int64] ?? [],
                disabled: Set(defaults.array(forKey: "st_aiBlockExemptDisabledIds") as? [Int64] ?? []))
    }
}

struct AIExemptAuthorsView: View {
    @State private var settings = AppSettingsStore.shared
    @State private var input = ""
    @State private var error: LocalizedKey?
    @Environment(OnboardingStore.self) private var l10n
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    var body: some View {
        NavigationStack {
            Form {
                Section { Text(l10n.t(.aiBlockExemptHint)).font(.subheadline).foregroundStyle(Theme.v3Text2) }
                Section {
                    TextField(l10n.t(.aiBlockExemptInputHint), text: $input)
                        .font(.body).keyboardType(.numberPad).focused($focused).onSubmit(add)
                    Button(l10n.t(.aiBlockExemptAdd), action: add)
                        .frame(maxWidth: .infinity, minHeight: 44).buttonStyle(.borderless)
                    if let error { Text(l10n.t(error)).font(.caption).foregroundStyle(Theme.v3Text2) }
                }
                Section {
                    if settings.aiBlockExemptAuthorIds.isEmpty { Text(l10n.t(.aiBlockExemptEmpty)).foregroundStyle(Theme.v3Text2) }
                    ForEach(settings.aiBlockExemptAuthorIds, id: \.self) { id in
                        HStack(spacing: 8) {
                            let enabled = !settings.aiBlockExemptDisabledIds.contains(id)
                            Button {
                                if enabled { settings.aiBlockExemptDisabledIds.insert(id) }
                                else { settings.aiBlockExemptDisabledIds.remove(id) }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                                        .frame(width: 24).foregroundStyle(enabled ? Theme.brand : Theme.v3Text3)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(String(id)).font(.montserratSemiBold(14)).fixedSize(horizontal: false, vertical: true)
                                        Text(l10n.t(enabled ? .aiBlockExemptStateOn : .aiBlockExemptStateOff))
                                            .font(.caption).foregroundStyle(Theme.v3Text2)
                                    }
                                    Spacer(minLength: 0)
                                }.frame(minHeight: 44).foregroundStyle(Theme.v3Text1).contentShape(.rect)
                            }.buttonStyle(.borderless)
                            Button(role: .destructive) {
                                settings.aiBlockExemptAuthorIds.removeAll { $0 == id }
                                settings.aiBlockExemptDisabledIds.remove(id)
                            } label: { Image(systemName: "trash").frame(width: 44, height: 44) }
                            .buttonStyle(.borderless).accessibilityLabel(l10n.t(.actionDelete))
                        }
                    }
                }
            }
            .tint(Theme.brand).scrollContentBackground(.hidden).background(Theme.v3Bg)
            .toolbarBackground(Theme.v3Bg, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
            .navigationTitle(l10n.t(.aiBlockExemptAuthors)).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(l10n.t(.actionDone)) { dismiss() } } }
        }
        .presentationDetents([.large])
    }
    private func add() {
        guard let id = Int64(input.trimmingCharacters(in: .whitespacesAndNewlines)), id > 0 else { error = .aiBlockExemptInvalid; return }
        guard !settings.aiBlockExemptAuthorIds.contains(id) else { error = .aiBlockExemptDuplicate; return }
        settings.aiBlockExemptAuthorIds.append(id)
        input = ""; error = nil; focused = false
    }
}
