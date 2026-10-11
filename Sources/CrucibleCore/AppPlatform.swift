import Foundation

package enum AppPlatform {
    package static var isTV: Bool {
        #if os(tvOS)
        return true
        #else
        return false
        #endif
    }

    package static var plexName: String {
        isTV ? "tvOS" : "iOS"
    }

    package static var fallbackDeviceName: String {
        isTV ? "Apple TV" : "iPhone"
    }

    package static var persistentDirectory: URL {
        let domain: FileManager.SearchPathDirectory = isTV ? .cachesDirectory : .applicationSupportDirectory
        return (try? FileManager.default.url(for: domain, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
    }

    package static var logsDirectory: URL {
        let domain: FileManager.SearchPathDirectory = isTV ? .cachesDirectory : .libraryDirectory
        guard let base = try? FileManager.default.url(for: domain, in: .userDomainMask, appropriateFor: nil, create: true) else {
            return FileManager.default.temporaryDirectory
        }
        return base.appendingPathComponent("Logs", isDirectory: true)
    }
}
