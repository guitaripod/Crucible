import Foundation
import Testing
@testable import CrucibleCore

struct AppPlatformTests {
    @Test func platformNameMatchesFlag() {
        #expect(AppPlatform.plexName == (AppPlatform.isTV ? "tvOS" : "iOS"))
    }

    @Test func persistentDirectoryExists() {
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: AppPlatform.persistentDirectory.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }
}
