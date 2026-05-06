import SwiftUI

struct SettingsView: View {
    @Environment(OnboardingStore.self) private var store
    @State private var mute = MuteStore.shared
    @State private var directConnect = false

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
                Toggle(store.t(.settingsHideR18), isOn: Binding(
                    get: { mute.hideR18 },
                    set: { mute.setHideR18($0) }
                ))
                Stepper(value: Binding(
                    get: { mute.waterfallColumns },
                    set: { mute.setWaterfallColumns($0) }
                ), in: 1...4, step: 1) {
                    Text("\(store.t(.settingsColumns)): \(mute.waterfallColumns)")
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
