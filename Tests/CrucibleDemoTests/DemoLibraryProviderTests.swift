import CrucibleCore
import Foundation
import Testing
@testable import CrucibleDemo

struct DemoLibraryProviderTests {
    @Test func theLibraryIsNotBuiltYet() async {
        await #expect(throws: DemoError.unavailable) { try await DemoLibraryProvider().start() }
    }
}
