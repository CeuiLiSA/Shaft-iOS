import Foundation
import BackgroundTasks
import UIKit

@MainActor
final class WebDAVBackupScheduler {
    static let shared = WebDAVBackupScheduler()
    static let identifier = "com.shaft.ShaftiOS.webdav-backup"
    private var registered = false
    private var running = false

    func register() {
        guard !registered else { return }
        registered = true
        NetworkReachability.shared.warmUp()
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: .main) { task in
            Task { @MainActor in self.handle(task) }
        }
    }

    func sync() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier)
        let preferences = WebDAVPreferences.shared
        guard preferences.automatic, preferences.config.isComplete else { return }
        let request = BGProcessingTaskRequest(identifier: Self.identifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = max(Date().addingTimeInterval(30 * 60),
                                       (preferences.lastAutomaticCheck ?? .distantPast).addingTimeInterval(24 * 60 * 60))
        do { try BGTaskScheduler.shared.submit(request) }
        catch { /* Foreground due checks remain available when background refresh is disabled. */ }
    }

    @discardableResult func runIfDue() async -> Bool {
        let preferences = WebDAVPreferences.shared
        guard !running, preferences.automatic, preferences.config.isComplete,
              preferences.lastAutomaticCheck.map({ Date().timeIntervalSince($0) >= 24 * 60 * 60 }) ?? true else { return true }
        running = true
        defer { running = false }
        // A background launch may run before NWPathMonitor's first callback.
        for _ in 0..<20 where !NetworkReachability.shared.hasInitialPath {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
        }
        guard !Task.isCancelled, NetworkReachability.shared.isUnmetered, !ProcessInfo.processInfo.isLowPowerModeEnabled else { return false }
        let device = UIDevice.current
        let wasMonitoring = device.isBatteryMonitoringEnabled
        device.isBatteryMonitoringEnabled = true
        let batteryOK = device.batteryLevel < 0 || device.batteryLevel > 0.2 || device.batteryState == .charging || device.batteryState == .full
        device.isBatteryMonitoringEnabled = wasMonitoring
        guard batteryOK else { return false }
        let config = preferences.config
        do {
            _ = try await WebDAVBackupService.shared.backup(config: config, includeHistory: preferences.includeHistory,
                                                          skipUnchanged: true, unmeteredOnly: true)
            try preferences.recordAutomaticCheck(Date())
            return true
        } catch is CancellationError { return false }
        catch {
            guard !Task.isCancelled else { return false }
            try? preferences.record(run: .init(time: Date(), success: false, message: error.localizedDescription), config: config)
            return false
        }
    }

    private func handle(_ task: BGTask) {
        let operation = Task { @MainActor in
            let success = await runIfDue()
            task.setTaskCompleted(success: success)
            sync()
        }
        task.expirationHandler = { operation.cancel() }
    }
}
