import CrucibleCore
@testable import CrucibleStore
import MidgarCore
import Testing

struct MidgarHostedBrainRegionTests {
    @Test func aRefusalForTheRegionIsItsOwnReason() {
        let refusal = MidgarHTTPError.server(status: 451, code: "unavailable_in_region", message: "This is not available in your region. Nothing was charged.")
        #expect(MidgarHostedBrain.failure(refusal) == .unavailableInRegion)
    }

    @Test func otherServerFailuresKeepTheirReasons() {
        #expect(MidgarHostedBrain.failure(MidgarHTTPError.server(status: 422, code: "content_blocked", message: "")) == .declined)
        #expect(MidgarHostedBrain.failure(MidgarHTTPError.server(status: 500, code: nil, message: "")) == .failed)
    }
}
