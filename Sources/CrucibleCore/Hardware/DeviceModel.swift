import Foundation

package enum DeviceModel {
    /// The first Apple TV generation that can render Liquid Glass (Apple TV 4K, 2nd generation).
    private static let firstGlassCapableAppleTV = 11

    /// The hardware model identifier: the simulator reports the device it stands in for through
    /// `SIMULATOR_MODEL_IDENTIFIER`, real devices through `uname`. In DEBUG builds
    /// `CRUCIBLE_MODEL_IDENTIFIER` overrides both, so UI tests can render the classic look on a
    /// simulator that could draw Liquid Glass.
    package static var identifier: String? {
        #if DEBUG
        if let forced = ProcessInfo.processInfo.environment["CRUCIBLE_MODEL_IDENTIFIER"], !forced.isEmpty {
            return forced
        }
        #endif
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty {
            return simulated
        }
        var info = utsname()
        guard uname(&info) == 0 else { return nil }
        let machine = withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        return machine.isEmpty ? nil : machine
    }

    /// Apple TV HD and the 1st-generation Apple TV 4K (`AppleTV5,x`, `AppleTV6,x`) render the classic
    /// look; every other identifier, including one this build cannot parse, counts as capable.
    package static func supportsLiquidGlass(identifier: String?) -> Bool {
        guard let identifier, identifier.hasPrefix("AppleTV") else { return true }
        let generation = identifier.dropFirst("AppleTV".count).prefix { $0.isNumber }
        guard let major = Int(generation) else { return true }
        return major >= firstGlassCapableAppleTV
    }

    package static var supportsLiquidGlass: Bool {
        supportsLiquidGlass(identifier: identifier)
    }
}
