import CrucibleCore
import Foundation
import Network

extension DownloadManager {
    // MARK: - Network changes

    func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let wifi = path.status == .satisfied
                && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.handlePathChange(isOnWiFi: wifi, isOnline: online)
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.guitaripod.crucible.netmon"))
    }

    private func handlePathChange(isOnWiFi wifi: Bool, isOnline online: Bool) {
        let wasWiFi = isOnWiFi
        isOnWiFi = wifi
        isOnline = online
        if canStartOnCurrentNetwork(), (wifi && !wasWiFi) || online {
            promoteWaitingAndPump()
        } else {
            pumpQueue()
        }
    }

    func promoteWaitingAndPump() {
        for i in items.indices where items[i].state == .waitingForWiFi {
            items[i].state = .queued
        }
        persist()
        emit(.changed)
        pumpQueue()
    }
}
