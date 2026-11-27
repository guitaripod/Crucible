import CrucibleCore
import Foundation
import MidgarCore
#if canImport(UIKit)
import UIKit
#endif

/// Crucible's hosted model in the App Store build: aliases of Midgar's shared model service, asked as the anonymous
/// Midgar ID that Crucible Pro is recorded against. The service holds each alias's instructions and reply shape,
/// knows from the ledger whether that ID has Crucible Pro, and caps what one ID may ask in a day. Nothing is sent
/// unless a person asks for an answer, and what is sent is only the message the feature built.
package struct MidgarHostedBrain: HostedBrainProviding {
    private static let service = "intelligence"
    private static let path = "v1/run/chat.completion"
    private static let timeout: TimeInterval = 90
    private static let dailyLimitCode = "daily_limit_reached"

    private let identity: MidgarIdentity
    private let client: MidgarHTTPClient

    package init(identity: MidgarIdentity, appID: String = MidgarProAccess.appID) {
        self.identity = identity
        self.client = MidgarHTTPClient(configuration: identity.authorizing(MidgarHTTPConfiguration(appID: appID, timeout: Self.timeout)))
    }

    /// The model on an identity of its own, for a debug session that runs without the store.
    package static func live() -> MidgarHostedBrain {
        let configuration = MidgarHTTPConfiguration(appID: MidgarProAccess.appID)
        return MidgarHostedBrain(identity: MidgarIdentity(httpConfiguration: configuration, bundleID: MidgarProAccess.bundleID))
    }

    /// Steps aside where Midgar's servers make no model calls, so the features hide unless the device's own model answers.
    package var isReady: Bool { MidgarModelRegion.shared.modelsAvailable }

    package func ask(alias: String, input: String, language: String) async throws(HostedBrainError) -> String {
        let question = Question(alias: alias, input: input, language: language, idempotencyKey: UUID().uuidString)
        do {
            return try await send(question)
        } catch MidgarHTTPError.unauthorized {
            await identity.invalidateAccessToken()
            do {
                return try await send(question)
            } catch {
                throw Self.refused(error)
            }
        } catch {
            throw Self.refused(error)
        }
    }

    /// Asks Midgar again whether model calls are made where the device connects from.
    package func refreshRegion() async {
        await MidgarModelRegion.shared.refresh(client: client)
    }

    /// The person's reason for a failed call, after a refusal for the region is remembered so the features hide.
    private static func refused(_ error: any Error) -> HostedBrainError {
        MidgarModelRegion.shared.note(error)
        return failure(error)
    }

    private func send(_ question: Question) async throws -> String {
        let request = MidgarRequest(service: Self.service, path: Self.path, method: .post, body: question, neverRetries: true)
        let answer: Answer = try await client.send(request)
        return answer.content
    }

    /// What the person is told for each way the service or the network can refuse.
    static func failure(_ error: any Error, now: Date = Date()) -> HostedBrainError {
        guard let error = error as? MidgarHTTPError else { return error is CancellationError ? .failed : .offline }
        switch error {
        case .offline, .timeout: return .offline
        case .paymentRequired: return .needsPro
        case .rateLimited(let retryAfter, let code):
            guard code == dailyLimitCode else { return .busy }
            return .allowanceUsed(resetsAt: now.addingTimeInterval(retryAfter ?? 3_600))
        case .server(let status, let code, _):
            if MidgarModelRegion.isRefusal(error) { return .unavailableInRegion }
            return status == 422 && code == "content_blocked" ? .declined : .failed
        case .tokenUnavailable(let isTransient): return isTransient ? .offline : .failed
        case .unauthorized, .notFound, .decoding, .invalidRequest, .cancelled: return .failed
        @unknown default: return .failed
        }
    }

    private struct Question: Encodable, Sendable {
        let alias: String
        let input: String
        let language: String
        let idempotencyKey: String

        private enum CodingKeys: String, CodingKey {
            case alias, input, language
            case idempotencyKey = "idempotency_key"
        }
    }

    private struct Answer: Decodable, Sendable {
        let content: String
    }
}

/// The Midgar services of the App Store build, made once at launch on one anonymous identity: the store that sells
/// Crucible Pro and the hosted model that Pro includes. The anonymous usage counts and crash reports (MidgarSignals) start
/// first, so the store's tier and purchase notes reach them; Settings › Privacy & Data turns them off.
package struct MidgarServices {
    package let pro: MidgarProAccess
    package let brain: MidgarHostedBrain

    package static func live() -> MidgarServices {
        let configuration = MidgarHTTPConfiguration(appID: MidgarProAccess.appID)
        MidgarSignals.configure(configuration: configuration)
        let identity = MidgarIdentity(httpConfiguration: configuration, bundleID: MidgarProAccess.bundleID)
        return MidgarServices(pro: MidgarProAccess.live(configuration: configuration, identity: identity), brain: MidgarHostedBrain(identity: identity))
    }

    /// Puts both in place for the launch code that follows, and learns whether model calls are made here now and each time
    /// the app returns.
    @MainActor
    package func install() {
        ProAccess.shared.install(pro)
        HostedBrain.install(brain)
        let brain = brain
        Task { await brain.refreshRegion() }
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            Task { await brain.refreshRegion() }
        }
        #endif
    }
}
