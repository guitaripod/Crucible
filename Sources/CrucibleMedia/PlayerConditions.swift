import AVFoundation
import CoreMedia
import CrucibleCore
import Foundation
import Network
import os

/// Keeps `NetworkConditions.isCellular` current, so a stream started on cellular asks for the cellular quality.
enum CellularWatch {
    nonisolated(unsafe) private static let monitor = NWPathMonitor()
    private static let started = OSAllocatedUnfairLock(initialState: false)

    static func start() {
        let first = started.withLock { started -> Bool in
            defer { started = true }
            return !started
        }
        guard first else { return }
        monitor.pathUpdateHandler = { path in
            NetworkConditions.isCellular = path.usesInterfaceType(.cellular) && !path.usesInterfaceType(.wifi)
        }
        monitor.start(queue: DispatchQueue(label: "com.guitaripod.crucible.cellular"))
    }
}

/// Scales the subtitles the player draws itself to the size chosen in Settings; the server draws burned-in ones at it.
enum SubtitleStyle {
    static func apply(to item: AVPlayerItem) {
        let size = Preferences.subtitleSize
        guard size != .standard,
              let rule = AVTextStyleRule(textMarkupAttributes: [kCMTextMarkupAttribute_RelativeFontSize as String: Double(size.rawValue)]) else {
            item.textStyleRules = nil
            return
        }
        item.textStyleRules = [rule]
    }
}
