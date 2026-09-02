import Foundation
import Network
import Observation

/// 联网状态 —— Android 侧 `NetworkStateManager.networkState.isOnline` 的 iOS 版。
///
/// 分成两半：`NetworkReachability` 是可以从任意线程/actor 同步读的锁保护布尔
/// （收藏镜像引擎每个 tick 都要看一眼，不能为它跳主线程）；`NetworkState` 是给 SwiftUI
/// 观察的 MainActor 镜像（进度条上「当前无网络」那句话的真假只取决于它）。
final class NetworkReachability: @unchecked Sendable {
    static let shared = NetworkReachability()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var online = true

    var isOnline: Bool { lock.withLock { online } }

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let up = path.status == .satisfied
            let changed = self.lock.withLock { () -> Bool in
                let c = self.online != up
                self.online = up
                return c
            }
            Task { @MainActor in NetworkState.shared.isOnline = up }
            // 掉网时引擎每个 tick 直接返回 Idle 睡到兜底心跳；恢复联网要主动踢一脚，
            // 否则最长要等 15 分钟才会接着补页。
            if changed { BookmarkMirrorService.shared.kick(up ? "network online" : "network offline") }
        }
        monitor.start(queue: DispatchQueue(label: "com.shaft.network-monitor", qos: .utility))
    }

    /// 让单例尽早建起来（否则第一次读到的永远是默认的 true）。
    func warmUp() {}
}

@MainActor
@Observable
final class NetworkState {
    static let shared = NetworkState()
    var isOnline = true
    private init() {
        NetworkReachability.shared.warmUp()
    }
}
