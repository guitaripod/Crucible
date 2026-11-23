import Foundation

/// What one decoded frame shows, measured over a grid of its pixels: the colour it is painted in and how far that
/// colour varies. A server whose decoder cannot handle the file's codec paints every frame one colour, most often a
/// dead green, and never changes it, so the stream is played without a word of error: the player is happy, the sound
/// plays, and the picture is gone. Content that is right varies; only a broken decode is that flat.
package struct PictureSample: Equatable, Sendable {
    /// The mean luma of the frame, in the buffer's own code values.
    package let luma: Double
    /// The mean blue-difference chroma (Cb) of the frame; 128 is neutral.
    package let blue: Double
    /// The mean red-difference chroma (Cr) of the frame; 128 is neutral.
    package let red: Double
    /// How far the luma varies across the frame.
    package let lumaSpread: Double
    /// How far either chroma varies across the frame.
    package let chromaSpread: Double

    package init(luma: Double, blue: Double, red: Double, lumaSpread: Double, chromaSpread: Double) {
        self.luma = luma
        self.blue = blue
        self.red = red
        self.lumaSpread = lumaSpread
        self.chromaSpread = chromaSpread
    }
}

/// Judges a run of frames for a dead picture. A single flat frame means nothing: a fade to black, a title card and a cut
/// are all flat. A frame that is flat *and* painted a colour no picture is painted in is a decoder's uninitialized
/// surface, and no real scene holds one for more than a second, so a short run of them is proof.
package struct PictureWatchdog: Sendable {
    /// How many samples in a row must show the same dead colour: a little over a second of video.
    package static let samplesNeeded = 4
    /// How far a frame's code values may vary and still count as one flat colour.
    package static let flatSpread = 3.0
    /// How far off neutral a flat frame's chroma sits to be an impossible picture: a fade or a title card is black and
    /// neutral, and only a decoder's dead surface is flat green or flat blue.
    package static let cast = 20.0

    private var deadRun = 0

    package init() {}

    /// Judges one frame. Returns true the moment the run of dead frames is long enough to call the picture broken, and
    /// keeps returning false for every frame before it and after it.
    package mutating func observe(_ sample: PictureSample) -> Bool {
        guard Self.isFlat(sample), Self.isCast(sample) else {
            deadRun = 0
            return false
        }
        deadRun += 1
        return deadRun == Self.samplesNeeded
    }

    /// Whether the frame is a single colour, within the noise an encoder leaves.
    package static func isFlat(_ sample: PictureSample) -> Bool {
        sample.lumaSpread <= flatSpread && sample.chromaSpread <= flatSpread
    }

    /// Whether the frame is painted a colour away from neutral grey and black.
    package static func isCast(_ sample: PictureSample) -> Bool {
        abs(sample.blue - 128) >= cast || abs(sample.red - 128) >= cast
    }
}

/// A converted stream whose picture is dead, and what the viewer can do about it. The conversion is the server's work, so
/// the fix is the server's too: Plex's hardware decoding takes a codec its graphics card cannot decode and answers with
/// an empty surface.
package struct PictureTrouble: Sendable, Equatable {
    /// The file's picture codec as Plex names it ("vc1", "mpeg2video"), for the explanation.
    package let videoCodec: String?
    /// The file's container as Plex names it, kept for the log and nothing the viewer reads.
    package let container: String?

    package init(videoCodec: String?, container: String?) {
        self.videoCodec = videoCodec
        self.container = container
    }

    /// The picture codecs a recent graphics card may fail to decode in hardware, which is the only way a converted stream
    /// arrives painted one colour: VC-1 and MPEG-2, which NVDEC dropped on Blackwell and Intel's media engine after Gen 12,
    /// and the older MPEG-4 and WMV family the same engines have left behind. Only a file in one of these is watched.
    package static let fragileCodecs: Set<String> = [
        "vc1", "wmv3", "mpeg2video", "mpeg1video", "mpeg4", "msmpeg4v3", "msmpeg4v2", "wmv1", "wmv2", "flv1", "h263",
        "theora", "vp8",
    ]

    /// Whether the file's picture is one a server's hardware decoding may paint one flat colour (`fragileCodecs`).
    package static func canBreak(_ videoCodec: String?) -> Bool {
        videoCodec.map { fragileCodecs.contains($0.lowercased()) } ?? false
    }

    package var title: String {
        String(localized: "Your server can’t show this picture", comment: "Playback alert title when the server's converted stream has no picture in it, only a flat colour")
    }

    /// The whole explanation, the codec named when it is one known to fail: three short paragraphs, the last the fix.
    package var explanation: String {
        [String(localized: "Crucible is playing a stream your Plex server converted, and the conversion has no picture in it: every frame arrives as one flat colour, usually green.", comment: "Playback alert body when the converted stream is a flat colour"),
         codecNote,
         String(localized: "In Plex, open Settings, Transcoder and turn off “Use hardware acceleration when available”, then play it again. Converting the file to H.264 also fixes it for good.", comment: "Playback alert body: the two fixes for a server whose hardware decoding paints a flat colour")]
            .compactMap { $0 }
            .joined(separator: "\n\n")
    }

    /// The codec named when it is one recent graphics cards have stopped decoding in hardware (`fragileCodecs`), which is
    /// what makes Plex hand it to a decoder that cannot do it.
    private var codecNote: String? {
        guard Self.canBreak(videoCodec), let label = DetailFormat.videoCodecLabel(videoCodec) else { return nil }
        return String(localized: "This file is \(label), which recent graphics cards no longer decode in hardware.", comment: "Playback alert: the file's codec, which hardware decoding fails on")
    }

    /// What the log says, which is what tells this apart from a slow or stalled stream later.
    package var logLine: String {
        "picture dead codec=\(videoCodec ?? "unknown") container=\(container ?? "unknown")"
    }
}
