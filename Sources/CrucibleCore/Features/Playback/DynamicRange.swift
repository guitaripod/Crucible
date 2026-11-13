import Foundation

/// The dynamic range a video stream carries, read from the server's facts about it and, where an older server gave none,
/// from its label ("4K DoVi/HDR10").
package enum DynamicRange: Equatable, Sendable {
    case sdr
    case hdr10
    case hdr10Plus
    case hlg
    /// Dolby Vision with its profile (5, 7, 8) and base-layer compatibility (1 HDR10, 2 SDR, 4 HLG, 6 UHD Blu-ray HDR10).
    case dolbyVision(profile: Int?, compatibility: Int?)

    package init(_ stream: PlexStream?) {
        guard let stream else {
            self = .sdr
            return
        }
        let label = [stream.displayTitle, stream.title].compactMap { $0 }.joined(separator: " ").lowercased()
        if stream.doviPresent || label.contains("dovi") || label.contains("dolby vision") {
            self = .dolbyVision(profile: stream.doviProfile, compatibility: stream.doviCompatibility)
        } else if stream.hdr10PlusPresent || label.contains("hdr10+") {
            self = .hdr10Plus
        } else if let transfer = stream.colorTrc?.lowercased(), let range = Self.range(transfer: transfer) {
            self = range
        } else if label.contains("hlg") {
            self = .hlg
        } else if label.contains("hdr") {
            self = .hdr10
        } else {
            self = .sdr
        }
    }

    package var isHDR: Bool { self != .sdr }

    /// Dolby Vision profile 7, the dual-layer kind on UHD Blu-ray remuxes, which Apple's player will not decode at all.
    package var isDualLayerDolbyVision: Bool {
        if case .dolbyVision(profile: 7, _) = self { return true }
        return false
    }

    /// "Dolby Vision 8.1", "Dolby Vision 5", "HDR10+", "HDR10", "HLG" or "SDR": names the formats keep in every language.
    package var name: String {
        switch self {
        case .sdr: "SDR"
        case .hdr10: "HDR10"
        case .hdr10Plus: "HDR10+"
        case .hlg: "HLG"
        case .dolbyVision(let profile, let compatibility): ["Dolby Vision", Self.profileName(profile, compatibility)].compactMap { $0 }.joined(separator: " ")
        }
    }

    private static func range(transfer: String) -> DynamicRange? {
        switch transfer {
        case "smpte2084": .hdr10
        case "arib-std-b67": .hlg
        default: nil
        }
    }

    /// Profile 8 is named with its base layer ("8.1"), the way the profiles are known; the others stand alone.
    private static func profileName(_ profile: Int?, _ compatibility: Int?) -> String? {
        guard let profile else { return nil }
        guard profile == 8, let compatibility, compatibility > 0 else { return "\(profile)" }
        return "\(profile).\(compatibility)"
    }
}
