#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// SponsorBlock (sponsor.ajay.app), the open database of the stretches of YouTube videos that viewers marked as
/// sponsor reads, intros, outros and the like. A video is asked for by the first characters of its ID's hash, so the
/// service is never told which video is being watched.
package enum SponsorBlock {
    package enum Category: String, Sendable, CaseIterable, Codable {
        case sponsor
        case selfPromotion = "selfpromo"
        case interaction
        case intro
        case outro
        case preview
        case hook
        case filler
        case offTopicMusic = "music_offtopic"
    }

    package struct Segment: Sendable, Equatable {
        package let category: Category
        package let start: Double
        package let end: Double

        package init(category: Category, start: Double, end: Double) {
            self.category = category
            self.start = start
            self.end = end
        }
    }

    /// The address that answers for every video whose hashed ID starts like `videoID`'s.
    package static func address(videoID: String, categories: [Category]) -> URL? {
        let hash = SHA256.hash(data: Data(videoID.utf8)).map { String(format: "%02x", $0) }.joined()
        let names = "[" + categories.map { "\"\($0.rawValue)\"" }.joined(separator: ",") + "]"
        var components = URLComponents(string: "https://sponsor.ajay.app/api/skipSegments/\(hash.prefix(4))")
        components?.queryItems = [URLQueryItem(name: "categories", value: names), URLQueryItem(name: "actionTypes", value: "[\"skip\"]")]
        return components?.url
    }

    /// The marked stretches of `videoID` among what the service answered, in order, overlapping ones merged into the
    /// one that starts first.
    package static func segments(for videoID: String, in data: Data) -> [Segment] {
        guard let videos = try? JSONDecoder().decode([Lossy<Video>].self, from: data) else { return [] }
        let found = videos.compactMap(\.value).first { $0.videoID == videoID }?.segments.compactMap(\.value) ?? []
        var merged: [Segment] = []
        for entry in found.sorted(by: { $0.segment.first ?? 0 < $1.segment.first ?? 0 }) {
            guard entry.segment.count == 2, let category = Category(rawValue: entry.category), entry.segment[1] > entry.segment[0] else { continue }
            if let last = merged.last, entry.segment[0] < last.end {
                merged[merged.count - 1] = Segment(category: last.category, start: last.start, end: max(last.end, entry.segment[1]))
            } else {
                merged.append(Segment(category: category, start: entry.segment[0], end: entry.segment[1]))
            }
        }
        return merged
    }

    private struct Video: Decodable, Sendable {
        let videoID: String
        let segments: [Lossy<Entry>]
    }

    private struct Entry: Decodable, Sendable {
        let category: String
        let segment: [Double]
    }
}
