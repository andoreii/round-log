import Foundation
import Network
import Observation

@MainActor @Observable
final class GolfServices {
    let store: GolfStore
    let cloud: SupabaseGolfService
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var active = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var wakeAgain = false

    init(store: GolfStore? = nil, cloud: SupabaseGolfService = SupabaseGolfService()) {
        self.store = store ?? GolfStore(); self.cloud = cloud
        self.store.workAvailable = { [weak self] in self?.wake() }
    }

    func setActive(_ value: Bool) {
        active = value
        if !started {
            started = true
            monitor.pathUpdateHandler = { [weak self] path in
                guard path.status == .satisfied else { return }
                Task { @MainActor [weak self] in self?.wake() }
            }
            monitor.start(queue: DispatchQueue(label: "round-log.connectivity"))
        }
        if value { wake() }
        else { syncTask?.cancel() }
    }

    func signIn(email: String, password: String) async throws {
        syncTask?.cancel()
        if let syncTask { await syncTask.value }
        try await cloud.signIn(email: email, password: password)
        wake()
    }

    func signOut() async throws {
        syncTask?.cancel()
        if let syncTask { await syncTask.value }
        try await cloud.signOut()
    }

    func wake() {
        guard active else { return }
        guard syncTask == nil else { wakeAgain = true; return }
        wakeAgain = false
        syncTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.syncTask = nil
                if self.wakeAgain { self.wake() }
            }
            for attempt in 0..<4 {
                guard !Task.isCancelled, self.active else { return }
                await self.store.synchronize(using: self.cloud)
                guard self.store.hasPendingWork, !self.store.requiresSignIn else { return }
                if attempt < 3 { do { try await Task.sleep(for: .seconds(10)) } catch { return } }
            }
        }
    }
}
