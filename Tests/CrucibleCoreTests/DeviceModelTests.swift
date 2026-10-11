import Testing

@testable import CrucibleCore

struct DeviceModelTests {
    @Test(arguments: ["AppleTV5,3", "AppleTV6,2", "AppleTV10,9"])
    func olderAppleTVsFallBackToTheClassicLook(identifier: String) {
        #expect(!DeviceModel.supportsLiquidGlass(identifier: identifier))
    }

    @Test(arguments: ["AppleTV11,1", "AppleTV14,1", "AppleTV16,3", "AppleTV100,1"])
    func appleTV4KSecondGenerationOnwardRendersGlass(identifier: String) {
        #expect(DeviceModel.supportsLiquidGlass(identifier: identifier))
    }

    @Test(arguments: [nil, "", "iPhone17,1", "arm64", "AppleTV", "AppleTVx,1"] as [String?])
    func unknownOrNonAppleTVIdentifiersCountAsCapable(identifier: String?) {
        #expect(DeviceModel.supportsLiquidGlass(identifier: identifier))
    }

    @Test func hostReportsSomeIdentifier() {
        #expect(DeviceModel.identifier != nil)
    }
}
