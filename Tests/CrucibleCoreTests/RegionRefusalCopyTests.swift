import CrucibleCore
import Testing

struct RegionRefusalCopyTests {
    @Test func whatToWatchShowsTheNeutralRegionLineAndOffersNoRetry() {
        #expect(WatchCopy.failure(.brain(.unavailableInRegion)) == "Not available in your region.")
        #expect(WatchCopy.canRetry(.brain(.unavailableInRegion)) == false)
    }

    @Test func previouslyOnShowsTheNeutralRegionLine() {
        #expect(DescribedRecap.failure(.unavailableInRegion) == "Not available in your region.")
    }
}
