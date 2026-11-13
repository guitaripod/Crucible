import Foundation

package struct PlexStream: Decodable, Sendable, Identifiable {
    package let id: Int?
    package let streamType: Int
    package let codec: String?
    package let language: String?
    let languageCode: String?
    let languageTag: String?
    package let channels: Int?
    package let bitrate: Int?
    package let title: String?
    package let selected: Bool?
    package let isDefault: Bool?
    package let forced: Bool?
    package let format: String?
    package let key: String?
    package let displayTitle: String?
    /// The picture's transfer function as the server reads it: "smpte2084" (PQ) for HDR10, HDR10+ and most Dolby Vision,
    /// "arib-std-b67" for HLG.
    package let colorTrc: String?
    package let bitDepth: Int?
    package let frameRate: Double?
    package let doviPresent: Bool
    package let doviProfile: Int?
    /// What a player without Dolby Vision sees in the base layer: 1 HDR10, 2 SDR, 4 HLG, 6 HDR10 on a UHD Blu-ray, 0 nothing usable.
    package let doviCompatibility: Int?
    package let hdr10PlusPresent: Bool

    enum CodingKeys: String, CodingKey {
        case id, streamType, codec, language, languageCode, languageTag
        case channels, bitrate, title, selected
        case isDefault = "default"
        case forced, format, key, displayTitle
        case colorTrc, bitDepth, frameRate
        case doviPresent = "DOVIPresent"
        case doviProfile = "DOVIProfile"
        case doviCompatibility = "DOVIBLCompatID"
        case hdr10PlusPresent = "HDR10PlusPresent"
    }

    /// The picture's facts decode leniently, as numbers, strings or flags, so a server that spells one differently costs that
    /// fact alone and never the stream.
    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func flag(_ key: CodingKeys) -> Bool {
            if let value = (try? container.decodeIfPresent(Bool.self, forKey: key)) ?? nil { return value }
            return (PlexNumber.decode(container, key, Int.self) ?? 0) != 0
        }
        id = try container.decodeIfPresent(Int.self, forKey: .id)
        streamType = try container.decode(Int.self, forKey: .streamType)
        codec = try container.decodeIfPresent(String.self, forKey: .codec)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        languageCode = try container.decodeIfPresent(String.self, forKey: .languageCode)
        languageTag = try container.decodeIfPresent(String.self, forKey: .languageTag)
        channels = try container.decodeIfPresent(Int.self, forKey: .channels)
        bitrate = try container.decodeIfPresent(Int.self, forKey: .bitrate)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        selected = try container.decodeIfPresent(Bool.self, forKey: .selected)
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault)
        forced = try container.decodeIfPresent(Bool.self, forKey: .forced)
        format = try container.decodeIfPresent(String.self, forKey: .format)
        key = try container.decodeIfPresent(String.self, forKey: .key)
        displayTitle = try container.decodeIfPresent(String.self, forKey: .displayTitle)
        colorTrc = (try? container.decodeIfPresent(String.self, forKey: .colorTrc)) ?? nil
        bitDepth = PlexNumber.decode(container, .bitDepth, Int.self)
        frameRate = PlexNumber.decode(container, .frameRate, Double.self)
        doviPresent = flag(.doviPresent)
        doviProfile = PlexNumber.decode(container, .doviProfile, Int.self)
        doviCompatibility = PlexNumber.decode(container, .doviCompatibility, Int.self)
        hdr10PlusPresent = flag(.hdr10PlusPresent)
    }

    /// The stream's language as a code, for finding the same language among another file's streams.
    package var languageKey: String? {
        (languageCode ?? languageTag ?? language)?.lowercased()
    }

    /// The stream's language as a BCP 47 tag where the server gave one, else its language code.
    package var bcp47Language: String? {
        languageTag ?? languageCode
    }

    package var isBitmap: Bool {
        guard let codec else { return false }
        let bitmapCodecs = ["dvd_subtitle", "hdmv_pgs_subtitle", "pgssub", "vobsub", "dvb_subtitle"]
        return bitmapCodecs.contains(codec)
    }

    var channelDescription: String {
        Formatters.channelDescription(channels)
    }
}

extension PlexStream: Hashable {
    package static func == (lhs: PlexStream, rhs: PlexStream) -> Bool {
        lhs.id == rhs.id
            && lhs.streamType == rhs.streamType
            && lhs.codec == rhs.codec
            && lhs.language == rhs.language
            && lhs.displayTitle == rhs.displayTitle
            && lhs.channels == rhs.channels
            && lhs.bitrate == rhs.bitrate
    }

    package func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(streamType)
        hasher.combine(codec)
        hasher.combine(language)
        hasher.combine(displayTitle)
    }
}
