import AVFoundation
import CoreMedia
import CrucibleCore
import Foundation
import MidgarCore

extension PlaybackSession {
    /// Says in the log, once the picture has been up a moment, what the player is decoding next to the range the file
    /// carries, and what the surface says of the screen. The server's decision names the transfer function it sends; only
    /// this line shows whether the player took the stream as Dolby Vision, HDR10, HLG or SDR.
    func logPicture() {
        guard let item = player?.currentItem else { return }
        let ratingKey = request.ratingKey
        let source = stream?.media.map { DynamicRange(file: $0.Part?.first?.Stream).name } ?? "unknown"
        Task { [weak self] in
            try? await Task.sleep(for: PlaybackTiming.pictureLogDelay)
            guard let self, !isStopped, player?.currentItem === item else { return }
            let decoded = await DecodedPicture.describe(item)
            let display = describesDisplay?().map { " \($0)" } ?? ""
            MidgarLog.notice(
                "Picture ratingKey=\(ratingKey) \(decoded) eligible=\(AVPlayer.eligibleForHDRPlayback)\(display) source=\(source)",
                category: .playback
            )
        }
    }
}

/// What a player item's video track says of the picture being decoded.
@MainActor
enum DecodedPicture {
    static func describe(_ item: AVPlayerItem) async -> String {
        let size = item.presentationSize
        let shown = "size=\(Int(size.width))x\(Int(size.height))"
        for track in item.tracks {
            guard let asset = track.assetTrack, asset.mediaType == .video,
                  let format = try? await asset.load(.formatDescriptions).first else { continue }
            return "\(facts(of: format)) \(shown) fps=\(track.currentVideoFrameRate)"
        }
        return "codec=unknown \(shown)"
    }

    /// The codec as its four letters ("hvc1", "dvh1"), whether the sample description carries a Dolby Vision configuration,
    /// and the transfer function and primaries as Core Media names them.
    private static func facts(of format: CMFormatDescription) -> String {
        let code = format.mediaSubType.rawValue
        let letters = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((code >> $0) & 0xFF))) }
        let atoms = format.extensions[.sampleDescriptionExtensionAtoms]?.propertyListRepresentation as? [String: Any] ?? [:]
        let dolbyVision = atoms.keys.contains { $0.hasPrefix("dv") }
        let transfer = format.extensions[.transferFunction]?.propertyListRepresentation as? String ?? "none"
        let primaries = format.extensions[.colorPrimaries]?.propertyListRepresentation as? String ?? "none"
        return "codec=\(String(letters)) dolbyVision=\(dolbyVision) transfer=\(transfer) primaries=\(primaries)"
    }
}
