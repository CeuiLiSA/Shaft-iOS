import SwiftUI

struct SettingsView: View {
    @Environment(OnboardingStore.self) private var store
    @State private var directConnect = false
    @State private var hideR18 = true
    @State private var lineCount: Double = 2

    var body: some View {
        Form {
            Section(store.t(.settingsLanguage)) {
                Picker(store.t(.settingsLanguage), selection: Binding(
                    get: { store.activeTag },
                    set: { store.apply(tag: $0) }
                )) {
                    ForEach(AppLocales.supportedTags, id: \.self) { tag in
                        Text(AppLocales.displayName(tag)).tag(tag)
                    }
                }
                .pickerStyle(.menu)
            }

            Section(store.t(.settingsContent)) {
                Toggle(store.t(.settingsHideR18), isOn: $hideR18)
                Stepper(value: $lineCount, in: 1...4, step: 1) {
                    Text("\(store.t(.settingsColumns)): \(Int(lineCount))")
                }
            }

            Section(store.t(.settingsNetwork)) {
                Toggle(store.t(.settingsDirectConnect), isOn: $directConnect)
            }
        }
        .navigationTitle(store.t(.settingsTitle))
        .navigationBarTitleDisplayMode(.inline)
    }
}
