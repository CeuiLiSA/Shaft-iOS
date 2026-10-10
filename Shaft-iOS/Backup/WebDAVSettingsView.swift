import SwiftUI
import UniformTypeIdentifiers

struct WebDAVSettingsView: View {
    @State private var preferences = WebDAVPreferences.shared
    @State private var config = WebDAVConfig()
    @State private var saved = WebDAVConfig()
    @State private var showPassword = false
    @State private var busy = false
    @State private var operationLabel: LocalizedKey = .webdavBtnBackup
    @State private var operation: Task<Void, Never>?
    @State private var status: String?
    @State private var backups: [WebDAVRemoteBackup] = []
    @State private var showBackups = false
    @State private var selected: WebDAVRemoteBackup?
    @State private var showRestoreConfirmation = false
    @State private var showUnsaved = false
    @Environment(OnboardingStore.self) private var l10n
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    init(preferences: WebDAVPreferences? = nil) { _preferences = State(initialValue: preferences ?? .shared) }

    private var dirty: Bool { ((try? config.normalized()) ?? config) != saved }
    var body: some View {
        Form {
            Section { Text(l10n.t(.webdavIntroBody)).font(.subheadline).foregroundStyle(Theme.v3Text2) }
            Section(l10n.t(.webdavServerSection)) {
                TextField(l10n.t(.webdavUrlLabel), text: $config.baseURL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                adaptiveControls {
                    Button(l10n.t(.webdavPresetJianguoyun)) { config.baseURL = "https://dav.jianguoyun.com/dav/" }
                    Button("pCloud") { config.baseURL = "https://webdav.pcloud.com/" }
                    Button("pCloud EU") { config.baseURL = "https://ewebdav.pcloud.com/" }
                }.buttonStyle(.borderless).font(.caption)
                Text(l10n.t(.webdavUrlDesc)).font(.caption).foregroundStyle(Theme.v3Text2)
                TextField(l10n.t(.webdavUsernameLabel), text: $config.username)
                    .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                HStack {
                    Group {
                        if showPassword { TextField(l10n.t(.webdavPasswordLabel), text: $config.password) }
                        else { SecureField(l10n.t(.webdavPasswordLabel), text: $config.password) }
                    }.textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button { showPassword.toggle() } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye").frame(width: 44, height: 44)
                    }.buttonStyle(.borderless).accessibilityLabel(l10n.t(.webdavTogglePasswordVisibility))
                }
                TextField(l10n.t(.webdavFolderLabel), text: $config.folder)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                adaptiveControls {
                    Button(l10n.t(.aria2BtnSave)) { _ = save() }
                    if !typeSize.isAccessibilitySize { Spacer() }
                    Button(l10n.t(.aria2BtnTest)) {
                        guard let destination = validated() else { return }
                        run(.aria2BtnTest) {
                            let client = try WebDAVClient(config: destination)
                            try await client.testConnection()
                            status = l10n.t(.webdavTestSuccess)
                        }
                    }
                }.buttonStyle(.borderless)
            }.disabled(busy)
            Section(l10n.t(.webdavBackupSection)) {
                Toggle(isOn: Binding(get: { preferences.includeHistory }, set: { value in
                    do { try preferences.setIncludeHistory(value) } catch { status = describe(error) }
                })) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(l10n.t(.webdavIncludeHistoryTitle))
                        Text(l10n.t(.webdavIncludeHistoryDesc)).font(.caption).foregroundStyle(Theme.v3Text2)
                    }
                }
                Toggle(isOn: Binding(get: { preferences.automatic }, set: { value in
                    guard !value || save() else { return }
                    do { try preferences.setAutomatic(value); WebDAVBackupScheduler.shared.sync() }
                    catch { status = describe(error) }
                    if value { Task { await WebDAVBackupScheduler.shared.runIfDue() } }
                })) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(l10n.t(.webdavAutoBackupTitle))
                        Text(l10n.t(.webdavAutoBackupDesc)).font(.caption).foregroundStyle(Theme.v3Text2)
                    }
                }
                Text(lastRun).font(.footnote).foregroundStyle(Theme.v3Text2)
                Button(l10n.t(.webdavBtnBackup)) { backup() }.buttonStyle(.borderedProminent)
                Button(l10n.t(.webdavBtnRestore)) { listBackups() }
            }.disabled(busy)
            if busy { Section { ProgressView(l10n.t(operationLabel)) } }
            if let status { Section { Text(status).font(.subheadline).foregroundStyle(Theme.v3Text2).textSelection(.enabled) } }
        }
        .tint(Theme.brand)
        .scrollContentBackground(.hidden).background(Theme.v3Bg)
        .toolbarBackground(Theme.v3Bg, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
        .navigationTitle(l10n.t(.webdavSettingsTitle)).navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(dirty || busy)
        .toolbar {
            if dirty && !busy { ToolbarItem(placement: .navigation) { Button { showUnsaved = true } label: { Image(systemName: "chevron.backward") } } }
        }
        .interactiveDismissDisabled(busy || dirty)
        .onAppear { if !busy { config = preferences.config; saved = config } }
        .onDisappear { operation?.cancel() }
        .confirmationDialog(l10n.t(.webdavUnsavedMessage), isPresented: $showUnsaved, titleVisibility: .visible) {
            Button(l10n.t(.aiTranslateUnsavedSave)) { if save() { dismiss() } }
            Button(l10n.t(.aiTranslateUnsavedDiscard), role: .destructive) { dismiss() }
            Button(l10n.t(.actionCancel), role: .cancel) {}
        }
        .sheet(isPresented: $showBackups, onDismiss: { if selected != nil { showRestoreConfirmation = true } }) {
            NavigationStack {
                List(backups) { backup in
                    Button {
                        selected = backup; showBackups = false
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(backup.date, format: .dateTime.year().month().day().hour().minute())
                            Text("\(backup.device) · \(ByteCountFormatter.string(fromByteCount: backup.size, countStyle: .file))")
                                .font(.caption).foregroundStyle(Theme.v3Text2)
                        }.foregroundStyle(Theme.v3Text1)
                    }
                }
                .navigationTitle(l10n.t(.webdavPickBackupTitle)).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(l10n.t(.actionCancel)) { showBackups = false } } }
            }
        }
        .alert(l10n.t(.webdavRestoreConfirmTitle), isPresented: $showRestoreConfirmation) {
            Button(l10n.t(.actionCancel), role: .cancel) { selected = nil }
            Button(l10n.t(.webdavBtnRestore)) {
                guard let backup = selected else { return }
                run(.webdavRestoring) {
                    try await WebDAVBackupService.shared.restore(config: saved, name: backup.name)
                    status = l10n.t(.webdavRestoreSuccessMessage)
                    selected = nil
                }
            }
        } message: { Text(l10n.t(.webdavRestoreConfirmMessage)) }
    }

    private var adaptiveControls: AnyLayout {
        typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 8))
    }
    private var lastRun: String {
        guard let run = preferences.lastRun else { return l10n.t(.webdavLastRunNever) }
        let date = run.time.formatted(date: .abbreviated, time: .shortened)
        return run.success ? l10n.t(.webdavLastRunSuccess, date) : l10n.t(.webdavLastRunFailed, date, run.message)
    }
    private func validated() -> WebDAVConfig? {
        do {
            let normalized = try config.normalized()
            guard normalized.isComplete else { status = l10n.t(.webdavConfigRequired); return nil }
            return normalized
        } catch { status = describe(error); return nil }
    }
    @discardableResult private func save() -> Bool {
        guard let normalized = validated() else { return false }
        do {
            if normalized != saved { try preferences.save(normalized) }
            config = normalized; saved = normalized
            status = l10n.t(.aria2Saved)
            return true
        } catch { status = describe(error); return false }
    }
    private func backup() {
        guard save() else { return }
        let destination = saved
        run {
            do {
                let result = try await WebDAVBackupService.shared.backup(config: destination, includeHistory: preferences.includeHistory, skipUnchanged: false)
                if case .uploaded(_, let size) = result { status = l10n.t(.webdavBackupSuccess, ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
            } catch {
                if !Task.isCancelled { try? preferences.record(run: .init(time: Date(), success: false, message: describe(error)), config: destination) }
                throw error
            }
        }
    }
    private func listBackups() {
        guard save() else { return }
        run(.webdavBtnRestore) {
            backups = try await WebDAVBackupService.shared.list(config: saved)
            if backups.isEmpty { status = l10n.t(.webdavNoBackups) }
            else { selected = nil; showBackups = true }
        }
    }
    private func run(_ label: LocalizedKey = .webdavBtnBackup, _ block: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; status = nil; operationLabel = label
        operation = Task { @MainActor in
            defer { busy = false; operation = nil }
            do { try await block() }
            catch is CancellationError {}
            catch { if !Task.isCancelled { status = l10n.t(.webdavOperationFailed, describe(error)) } }
        }
    }
    private func describe(_ error: Error) -> String {
        switch error {
        case WebDAVError.authentication: return l10n.t(.webdavErrorAuth)
        case WebDAVError.notFound: return l10n.t(.webdavErrorNotFound)
        case WebDAVError.badURL: return l10n.t(.webdavUrlInvalid)
        default: return error.localizedDescription
        }
    }
}

private struct ShaftBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, UTType(filenameExtension: "gz") ?? .data] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw ShaftBackupError.invalid }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct LocalBackupSettingsView: View {
    var startRestoring = false
    @State private var operation: Task<Void, Never>?
    @State private var includeHistory = true
    @State private var busy = false
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var confirmRestore = false
    @State private var file: URL?
    @State private var document: ShaftBackupDocument?
    @State private var message: String?
    @Environment(OnboardingStore.self) private var l10n
    var body: some View {
        Form {
            Section {
                Toggle(l10n.t(.webdavIncludeHistoryTitle), isOn: $includeHistory)
                Button(l10n.t(.stBackup)) {
                    busy = true
                    operation = Task { @MainActor in
                        defer { busy = false }
                        do { document = ShaftBackupDocument(data: try await WebDAVBackupService.shared.localExport(includeHistory: includeHistory)); showExporter = true }
                        catch { if !Task.isCancelled { message = error.localizedDescription } }
                    }
                }
                Button(l10n.t(.stRestore)) { showImporter = true }
            }.disabled(busy)
            if busy { Section { ProgressView() } }
            if let message { Section { Text(message).textSelection(.enabled) } }
        }
        .navigationTitle(l10n.t(.stBackup)).navigationBarTitleDisplayMode(.inline)
        .tint(Theme.brand)
        .navigationBarBackButtonHidden(busy)
        .interactiveDismissDisabled(busy)
        .onDisappear { operation?.cancel() }
        .task { if startRestoring { showImporter = true } }
        .fileExporter(isPresented: $showExporter, document: document, contentType: UTType(filenameExtension: "gz") ?? .data,
                      defaultFilename: "Shaft-Backup.json") { result in
            if case .failure(let error) = result { message = error.localizedDescription }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json, .data]) { result in
            switch result {
            case .success(let selected): file = selected; confirmRestore = true
            case .failure(let error): message = error.localizedDescription
            }
        }
        .alert(l10n.t(.webdavRestoreConfirmTitle), isPresented: $confirmRestore) {
            Button(l10n.t(.actionCancel), role: .cancel) { file = nil }
            Button(l10n.t(.stRestore)) {
                guard let file else { return }
                busy = true
                operation = Task { @MainActor in
                    defer { busy = false }
                    do { try await WebDAVBackupService.shared.localRestore(file: file); message = l10n.t(.webdavRestoreSuccessMessage) }
                    catch { if !Task.isCancelled { message = error.localizedDescription } }
                }
            }
        } message: { Text(l10n.t(.webdavRestoreConfirmMessage)) }
    }
}
