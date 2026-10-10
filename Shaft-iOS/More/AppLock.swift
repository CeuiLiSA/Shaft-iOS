import SwiftUI
import LocalAuthentication
import Observation

enum AppLockTimeout: Int, CaseIterable, Identifiable {
    case immediately = 0, oneMinute = 1, fiveMinutes = 5, fifteenMinutes = 15
    var id: Int { rawValue }
    var label: LocalizedKey {
        switch self {
        case .immediately: return .applockTimeoutImmediately
        case .oneMinute: return .applockTimeout1Minute
        case .fiveMinutes: return .applockTimeout5Minutes
        case .fifteenMinutes: return .applockTimeout15Minutes
        }
    }
    func requiresLock(authenticated: Bool, backgroundAt: TimeInterval?, now: TimeInterval) -> Bool {
        guard authenticated else { return true }
        guard let backgroundAt else { return false }
        let elapsed = now - backgroundAt
        return elapsed < 0 || elapsed >= Double(rawValue) * 60
    }
}

/// Device-local gate, never exported in a backup. An authentication dialog's
/// inactive phase only masks the UI; only a real background transition starts
/// the relock timer. Uptime avoids wall-clock changes extending an unlocked session.
@MainActor @Observable
final class AppLockController {
    static let shared = AppLockController()
    private(set) var enabled: Bool
    var timeout: AppLockTimeout { didSet { defaults.set(timeout.rawValue, forKey: "applock_timeout") } }
    private(set) var isLocked: Bool
    private(set) var privacyShield = false
    private(set) var authenticating = false
    private(set) var errorMessage: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let authenticationOverride: (@MainActor (String) async -> Bool)?
    @ObservationIgnored private var automaticUnlockPending: Bool
    @ObservationIgnored private var backgroundGeneration = 0
    @ObservationIgnored private var authenticated = false
    @ObservationIgnored private var backgroundAt: TimeInterval?
    @ObservationIgnored private var context: LAContext?
    @ObservationIgnored private var phase = ScenePhase.active

    init(defaults: UserDefaults = .standard, authenticationOverride: (@MainActor (String) async -> Bool)? = nil) {
        self.defaults = defaults
        self.authenticationOverride = authenticationOverride
        let isEnabled = defaults.bool(forKey: "applock_enabled")
        automaticUnlockPending = isEnabled
        enabled = isEnabled
        timeout = AppLockTimeout(rawValue: defaults.integer(forKey: "applock_timeout")) ?? .immediately
        isLocked = isEnabled
    }

    func update(_ phase: ScenePhase) {
        self.phase = phase
        if phase == .background { backgroundGeneration &+= 1; context?.invalidate() }
        guard enabled else { privacyShield = false; isLocked = false; return }
        switch phase {
        case .background:
            automaticUnlockPending = true
            privacyShield = true
            backgroundAt = ProcessInfo.processInfo.systemUptime
        case .inactive:
            privacyShield = true
        case .active:
            privacyShield = false
            if timeout.requiresLock(authenticated: authenticated, backgroundAt: backgroundAt,
                                    now: ProcessInfo.processInfo.systemUptime) { isLocked = true }
            if !isLocked { backgroundAt = nil; automaticUnlockPending = false }
        @unknown default: privacyShield = true
        }
    }

    func setEnabled(_ value: Bool, reason: String) async {
        guard !authenticating else { return }
        if !value {
            enabled = false; isLocked = false; privacyShield = false
            defaults.set(false, forKey: "applock_enabled")
            return
        }
        let generation = backgroundGeneration
        guard await authenticate(reason: reason), generation == backgroundGeneration, phase != .background else { return }
        automaticUnlockPending = false
        enabled = true
        authenticated = true
        isLocked = false
        backgroundAt = nil
        privacyShield = phase != .active
        defaults.set(true, forKey: "applock_enabled")
    }

    func unlockAutomatically(reason: String) async {
        guard automaticUnlockPending, enabled, isLocked, !authenticating, phase == .active else { return }
        automaticUnlockPending = false
        await unlock(reason: reason)
    }

    func unlock(reason: String) async {
        guard enabled, isLocked, !authenticating, phase == .active else { return }
        automaticUnlockPending = false
        let generation = backgroundGeneration
        if await authenticate(reason: reason), generation == backgroundGeneration, phase != .background {
            authenticated = true
            isLocked = false
            backgroundAt = nil
            privacyShield = phase != .active
        }
    }

    private func authenticate(reason: String) async -> Bool {
        if let authenticationOverride {
            authenticating = true
            defer { authenticating = false }
            return await authenticationOverride(reason)
        }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            errorMessage = error?.localizedDescription
            // Removing the device passcode must not permanently trap the owner.
            if error?.code == LAError.passcodeNotSet.rawValue {
                enabled = false; isLocked = false; privacyShield = false
                defaults.set(false, forKey: "applock_enabled")
            }
            return false
        }
        authenticating = true
        errorMessage = nil
        self.context = context
        defer { authenticating = false; self.context = nil }
        do { return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) }
        catch { errorMessage = error.localizedDescription; return false }
    }
}

/// SwiftUI sheets/full-screen covers are presented above the root hosting view.
/// A scene-local window covers those presentations without dismissing them or
/// losing their state. Key-window and accessibility ownership return on unlock.
struct AppLockWindowPresenter: UIViewRepresentable {
    let controller: AppLockController
    @Environment(OnboardingStore.self) private var l10n
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> Anchor { Anchor() }
    func updateUIView(_ view: Anchor, context: Context) {
        view.update(controller: controller, language: l10n, colorScheme: colorScheme)
    }
    static func dismantleUIView(_ view: Anchor, coordinator: Void) { view.stop() }

    final class Anchor: UIView {
        private weak var baseWindow: UIWindow?
        private weak var previousKeyWindow: UIWindow?
        private var previousAccessibilityHidden: Bool?
        private var cover: UIWindow?
        private var host: UIHostingController<AnyView>?
        private var visible = false
        private var content = AnyView(Color.clear)
        private var controller: AppLockController?
        private var language: OnboardingStore?
        private var colorScheme: ColorScheme = .light
        private var observing = false
        private weak var observedScene: UIWindowScene?
        private var sceneInactive = false
        private var sceneObservers: [NSObjectProtocol] = []

        func update(controller: AppLockController, language: OnboardingStore, colorScheme: ColorScheme) {
            self.controller = controller
            self.language = language
            self.colorScheme = colorScheme
            if observing { render() } else { observe() }
        }
        private func observe() {
            guard controller != nil else { return }
            observing = true
            // A full-screen presentation detaches the root view, so its
            // representable updates may stop. Observe the model independently.
            withObservationTracking { render() } onChange: { [weak self] in
                Task { @MainActor in self?.observing = false; self?.observe() }
            }
        }
        private func render() {
            guard let controller, let language else { return }
            if let scene = baseWindow?.windowScene { observeScene(scene) }
            // App scenePhase is aggregated across windows. A background iPad
            // window still needs its own shield while another stays active.
            let shield = controller.privacyShield || (controller.enabled && sceneInactive)
            visible = shield || controller.isLocked
            content = AnyView(Group {
                if shield { Theme.v3Bg.ignoresSafeArea() }
                else { AppLockScreen(controller: controller).ignoresSafeArea() }
            }
            .environment(language).environment(\.locale, language.currentLocale)
            .preferredColorScheme(colorScheme).tint(Theme.brand))
            sync()
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window { baseWindow = window }
            render()
        }
        override func layoutSubviews() { super.layoutSubviews(); sync() }
        private func sync() {
            guard let base = baseWindow, let scene = base.windowScene else { removeCover(); return }
            if let cover, cover.windowScene !== scene { removeCover() }
            guard visible else { removeCover(); return }
            if cover == nil {
                previousKeyWindow = scene.keyWindow
                previousAccessibilityHidden = base.accessibilityElementsHidden
                base.accessibilityElementsHidden = true
                let host = UIHostingController(rootView: content)
                let cover = UIWindow(windowScene: scene)
                cover.rootViewController = host
                cover.windowLevel = .alert + 1
                cover.accessibilityViewIsModal = true
                self.host = host
                self.cover = cover
            } else { host?.rootView = content }
            cover?.frame = base.bounds
            cover?.isHidden = false
            if cover?.isKeyWindow == false { cover?.makeKey() }
        }
        private func observeScene(_ scene: UIWindowScene) {
            guard observedScene !== scene else { return }
            sceneObservers.forEach(NotificationCenter.default.removeObserver)
            observedScene = scene
            sceneInactive = scene.activationState != .foregroundActive
            sceneObservers = [(UIScene.willDeactivateNotification, true), (UIScene.didActivateNotification, false)].map { name, inactive in
                NotificationCenter.default.addObserver(forName: name, object: scene, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.sceneInactive = inactive
                        self?.render()
                    }
                }
            }
        }
        func removeCover() {
            let restoreKey = cover?.isKeyWindow == true
            cover?.isHidden = true
            cover?.rootViewController = nil
            cover = nil
            host = nil
            if let previousAccessibilityHidden { baseWindow?.accessibilityElementsHidden = previousAccessibilityHidden }
            previousAccessibilityHidden = nil
            if restoreKey, let previousKeyWindow, !previousKeyWindow.isHidden { previousKeyWindow.makeKey() }
            previousKeyWindow = nil
        }
        func stop() {
            sceneObservers.forEach(NotificationCenter.default.removeObserver)
            sceneObservers.removeAll()
            observedScene = nil
            controller = nil
            language = nil
            removeCover()
            baseWindow = nil
        }
    }
}

extension View {
    func appLockPresentation(controller: AppLockController) -> some View {
        background(AppLockWindowPresenter(controller: controller).frame(width: 0, height: 0))
    }
}

struct AppLockScreen: View {
    @State private var lock = AppLockController.shared
    @Environment(OnboardingStore.self) private var l10n
    init(controller: AppLockController? = nil) { _lock = State(initialValue: controller ?? .shared) }
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "lock.fill").font(.system(size: 32))
                    .frame(width: 72, height: 72)
                    .foregroundStyle(Theme.v3TextAccent)
                    .background(Theme.brand.opacity(0.15), in: .rect(cornerRadius: 17))
                Text(l10n.t(.applockLockedTitle, "Pixiv-Shaft"))
                    .font(.montserratBold(28, relativeTo: .largeTitle)).multilineTextAlignment(.center)
                Text(l10n.t(.applockLockedDesc)).font(.subheadline)
                    .foregroundStyle(Theme.v3Text2).multilineTextAlignment(.center)
                Button {
                    Task { await lock.unlock(reason: l10n.t(.applockPromptTitle, "Pixiv-Shaft")) }
                } label: {
                    Label(l10n.t(.applockUnlock), systemImage: "faceid")
                        .font(.montserratSemiBold(16)).frame(maxWidth: .infinity, minHeight: 56)
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                .disabled(lock.authenticating)
                if let error = lock.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(Theme.v3Text2)
                        .multilineTextAlignment(.center).accessibilityAddTraits(.updatesFrequently)
                }
            }.frame(maxWidth: 400).padding(28).frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center)
        .background(Theme.v3Bg.ignoresSafeArea())
    }
}
