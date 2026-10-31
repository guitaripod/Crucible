import CrucibleCore
import CrucibleStore
import Foundation
import MidgarCommerce
import MidgarCore
import StoreKit
import StoreKitTest
import Testing

/// Runs Crucible Pro's store against `Products.storekit`, the two products the App Store sells, so the offers, the
/// entitlement mapping and the status the screens read are checked on a real StoreKit. StoreKit is process-wide, so
/// the suite runs serially. Test transactions are signed with Xcode's local certificate and never reach the ledger;
/// the identity and the ledger here are stubs that never leave the process.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct MidgarProAccessStoreKitTests {
    private struct Harness {
        let access: MidgarProAccess
        let session: SKTestSession
    }

    private static let configurationURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Products.storekit")

    private func makeHarness() throws -> Harness {
        let session = try SKTestSession(contentsOf: Self.configurationURL)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        session.askToBuyEnabled = false
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("crucible-pro-" + UUID().uuidString, isDirectory: true)
        let store = MidgarStore(
            configuration: MidgarProAccess.storeConfiguration(directory: directory),
            identity: StubIdentity(),
            http: OfflineLedger.client()
        )
        return Harness(access: MidgarProAccess(store: store), session: session)
    }

    @Test func theOffersAreTheLifetimeAndTheYearlyPlanWithNoTrial() async throws {
        let harness = try makeHarness()
        let offers = try await harness.access.loadOffers()

        #expect(offers.map(\.kind) == [.lifetime, .annual])
        #expect(offers.map(\.id) == [MidgarProAccess.lifetimeID, MidgarProAccess.yearlyID])
        #expect(offers.allSatisfy { $0.trial == nil })
        #expect(offers.first { $0.kind == .annual }?.monthlyEquivalentText != nil)
    }

    @Test func aNewInstallIsFree() async throws {
        let harness = try makeHarness()

        #expect(await harness.access.refreshStatus() == .free)
        #expect(await harness.access.restore() == .nothingToRestore)
    }

    @Test func theLifetimePurchaseUnlocksProForGood() async throws {
        let harness = try makeHarness()
        try harness.session.buyProduct(productIdentifier: MidgarProAccess.lifetimeID)

        let status = try #require(await harness.access.refreshStatus())
        let entitlement = try #require(status.entitlement)
        #expect(entitlement.kind == .lifetime)
        #expect(entitlement.productIdentifier == MidgarProAccess.lifetimeID)
        #expect(entitlement.expiresAt == nil)
        #expect(await harness.access.managementURL() == nil)
        #expect(await harness.access.purchase(offerID: MidgarProAccess.yearlyID) == .alreadyOwned)
    }

    @Test func theYearlyPlanUnlocksProAsARenewingSubscription() async throws {
        let harness = try makeHarness()
        try harness.session.buyProduct(productIdentifier: MidgarProAccess.yearlyID)

        let status = try #require(await harness.access.refreshStatus())
        let entitlement = try #require(status.entitlement)
        #expect(entitlement.kind == .subscription)
        #expect(entitlement.productIdentifier == MidgarProAccess.yearlyID)
        #expect(entitlement.expiresAt != nil)
        #expect(entitlement.willRenew)
        #expect(!entitlement.isTrial)
        #expect(await harness.access.managementURL() != nil)
    }

    @Test func anExpiredYearlyPlanLeavesProLocked() async throws {
        let harness = try makeHarness()
        try harness.session.buyProduct(productIdentifier: MidgarProAccess.yearlyID)
        try harness.session.expireSubscription(productIdentifier: MidgarProAccess.yearlyID)

        #expect(await harness.access.refreshStatus() == .free)
    }
}

private struct StubIdentity: MidgarStoreIdentity {
    var midgarId: String {
        get async throws { "00000000-0000-4000-8000-000000000001" }
    }
}

/// A ledger that answers every call with an empty success, so the store never waits on the network in tests.
private final class OfflineLedger: URLProtocol, @unchecked Sendable {
    private static let host = "ledger.crucible-tests.invalid"

    static func client() -> MidgarHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineLedger.self]
        return MidgarHTTPClient(configuration: MidgarHTTPConfiguration(
            baseURL: URL(string: "https://\(host)")!,
            appID: MidgarProAccess.appID,
            session: URLSession(configuration: configuration),
            timeout: 5
        ))
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body = url.path.hasSuffix("/entitlements") ? #"{"entitlements":[]}"# : #"{"ok":true}"#
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
