import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(os)
import os
#endif

/// The URLSession Core's requests go through: `URLSession.shared` unless a test or a platform installs another. Tests
/// install one with their stub protocols because swift-corelibs-foundation's shared session only consults the protocol
/// classes registered before it was first used.
package enum HTTPSession {
    private static let installed = OSAllocatedUnfairLock<URLSession?>(initialState: nil)

    package static var current: URLSession {
        installed.withLock { $0 } ?? .shared
    }

    package static func install(_ session: URLSession?) {
        installed.withLock { $0 = session }
    }
}
