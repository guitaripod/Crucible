import AVFoundation
@testable import CrucibleCore
import Foundation
import ImageIO
import Testing
@testable import CrucibleDemo

struct DemoMediaTests {
    private func dimensions(_ data: Data) throws -> (Int, Int) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return (try #require(properties[kCGImagePropertyPixelWidth] as? Int), try #require(properties[kCGImagePropertyPixelHeight] as? Int))
    }

    private func isJPEG(_ data: Data) -> Bool {
        data.starts(with: [0xFF, 0xD8, 0xFF])
    }

    @Test func imagesComeBackAsSmallJPEGs() async throws {
        try await withDemo { demo in
            let poster = try await demo.get("/photo/:/transcode?url=%2Flibrary%2Fmetadata%2F1001%2Fthumb%2F1700001001&width=300&height=450&minSize=1")
            #expect(poster.1.statusCode == 200)
            #expect(poster.1.value(forHTTPHeaderField: "Content-Type") == "image/jpeg")
            #expect(isJPEG(poster.0))
            let posterSize = try dimensions(poster.0)
            #expect(posterSize.0 <= 400 && posterSize.1 <= 600 && posterSize.0 >= 200)
            #expect(poster.0.count < 120_000)

            let backdrop = try await demo.get("/library/metadata/1001/art/1700001001")
            let backdropSize = try dimensions(backdrop.0)
            #expect(isJPEG(backdrop.0) && backdropSize.0 <= 1280 && backdropSize.1 <= 720 && backdropSize.0 >= 640)
            #expect(backdrop.0.count < 250_000)

            let avatar = try await demo.get("/actors/maren-vale.jpg")
            let avatarSize = try dimensions(avatar.0)
            #expect(isJPEG(avatar.0) && avatarSize.0 <= 200 && avatarSize.1 <= 200)

            let still = try await demo.get("/photo/:/transcode?url=/library/metadata/4001/thumb/1700004001&width=400&height=225")
            #expect(isJPEG(still.0))
            let seasonArt = try await demo.get("/library/metadata/3001/art/1")
            #expect(seasonArt.0 == (try await demo.get("/library/metadata/2001/art/1")).0)
            let missing = try await demo.get("/photo/:/transcode?url=/library/metadata/424242/thumb/1")
            #expect(missing.1.statusCode == 404)
        }
    }

    @Test func everyTitleHasArtwork() async throws {
        try await withDemo { demo in
            let keys = (try await demo.api.requestContainer(.sectionItems(sectionId: "1", size: 100)).Metadata ?? [])
                + (try await demo.api.requestContainer(.sectionItems(sectionId: "2", size: 100)).Metadata ?? [])
                + (try await demo.api.requestContainer(.sectionItems(sectionId: "3", size: 100)).Metadata ?? [])
            #expect(keys.count >= 40)
            for item in keys {
                for path in [item.thumb, item.art].compactMap({ $0 }) {
                    let (data, response) = try await demo.get(path)
                    #expect(response.statusCode == 200 && isJPEG(data), "\(item.title) \(path)")
                }
                for role in item.cast {
                    guard let thumb = role.thumb else { continue }
                    #expect(try await demo.get(thumb).1.statusCode == 200)
                }
            }
            for episode in try await demo.api.requestContainer(.folderPath("/library/metadata/2001/allLeaves")).Metadata ?? [] {
                #expect(try await demo.get(try #require(episode.thumb)).1.statusCode == 200)
            }
        }
    }

    @Test func directPlayPartAnswersRangesWithTheRightBytes() async throws {
        try await withDemo { demo in
            let movie = try await demo.metadata("1001")
            let key = try #require(movie.Media?.first?.Part?.first?.key)
            let file = try Data(contentsOf: DemoAssets.bundled().clip)

            let whole = try await demo.get(key)
            #expect(whole.1.statusCode == 200)
            #expect(whole.1.value(forHTTPHeaderField: "Accept-Ranges") == "bytes")
            #expect(whole.1.value(forHTTPHeaderField: "Content-Type") == "video/mp4")
            #expect(whole.0 == file)

            let slice = try await demo.get(key, headers: ["Range": "bytes=100-199"])
            #expect(slice.1.statusCode == 206)
            #expect(slice.1.value(forHTTPHeaderField: "Content-Range") == "bytes 100-199/\(file.count)")
            #expect(slice.1.value(forHTTPHeaderField: "Content-Length") == "100")
            #expect(slice.0 == file.subdata(in: 100..<200))

            let openEnded = try await demo.get(key, headers: ["Range": "bytes=\(file.count - 10)-"])
            #expect(openEnded.1.statusCode == 206)
            #expect(openEnded.0 == file.suffix(10))

            let suffix = try await demo.get(key, headers: ["Range": "bytes=-50"])
            #expect(suffix.1.statusCode == 206 && suffix.0 == file.suffix(50))

            let beyond = try await demo.get(key, headers: ["Range": "bytes=\(file.count + 5)-"])
            #expect(beyond.1.statusCode == 416)

            let head = try await demo.get(key, method: "HEAD")
            #expect(head.1.statusCode == 200 && head.0.isEmpty)
            #expect(head.1.value(forHTTPHeaderField: "Content-Length") == "\(file.count)")
            #expect(file.count > 100_000 && file.count < 3_000_000)
        }
    }

    @Test func theStreamResolverDirectPlaysFreshTitlesAndTranscodesResumedOnes() async throws {
        try await withDemo { demo in
            let fresh = try await StreamResolver.resolve(api: demo.api, ratingKey: "1001", startSecs: nil, selectedSubtitleId: nil, selectedAudioStreamId: nil)
            #expect(fresh.isDirectPlay)
            #expect(fresh.url.path.hasSuffix("/file.mp4"))
            #expect(fresh.markers.count == 1)
            #expect(fresh.subtitles.count == 5 && fresh.audioTracks.count == 3)
            let (_, response) = try await URLSession.shared.data(from: fresh.url)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)

            let resumed = try await StreamResolver.resolve(api: demo.api, ratingKey: "1002", startSecs: 3150, selectedSubtitleId: nil, selectedAudioStreamId: nil)
            #expect(!resumed.isDirectPlay)
            #expect(resumed.url.path.hasSuffix("/start.m3u8"))

            let forced = try await StreamResolver.resolve(api: demo.api, ratingKey: "1001", startSecs: nil, selectedSubtitleId: nil, selectedAudioStreamId: nil, forceTranscode: true)
            #expect(!forced.isDirectPlay)
            let burned = try await StreamResolver.resolve(api: demo.api, ratingKey: "1001", startSecs: nil, selectedSubtitleId: 10015, selectedAudioStreamId: nil)
            #expect(!burned.isDirectPlay)
        }
    }

    @Test func theHLSPlaylistParsesAndEverySegmentExists() async throws {
        try await withDemo { demo in
            let stream = try await StreamResolver.resolve(api: demo.api, ratingKey: "1001", startSecs: nil, selectedSubtitleId: nil, selectedAudioStreamId: nil, forceTranscode: true)
            let masterText = String(decoding: try await URLSession.shared.data(from: stream.url).0, as: UTF8.self)
            #expect(masterText.hasPrefix("#EXTM3U"))
            #expect(masterText.contains("#EXT-X-STREAM-INF"))
            let mediaLine = try #require(masterText.split(whereSeparator: \.isNewline).first { !$0.hasPrefix("#") })
            let mediaURL = try #require(URL(string: String(mediaLine), relativeTo: stream.url)?.absoluteURL)
            let (mediaData, mediaResponse) = try await URLSession.shared.data(from: mediaURL)
            #expect((mediaResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") == "application/vnd.apple.mpegurl")
            let media = String(decoding: mediaData, as: UTF8.self)
            #expect(media.contains("#EXT-X-ENDLIST") && media.contains("#EXT-X-TARGETDURATION:2"))
            let uris = media.split(whereSeparator: \.isNewline).map { String($0) }.filter { !$0.hasPrefix("#") }
            #expect(uris.count == 15)
            let initLine = try #require(media.split(whereSeparator: \.isNewline).first { $0.hasPrefix("#EXT-X-MAP") })
            #expect(initLine.contains("init.mp4"))
            for name in ["init.mp4"] + uris {
                let url = try #require(URL(string: name, relativeTo: mediaURL.deletingLastPathComponent())?.absoluteURL)
                let (data, response) = try await URLSession.shared.data(from: url)
                #expect((response as? HTTPURLResponse)?.statusCode == 200 && !data.isEmpty, "\(name)")
            }
            let (_, ping) = try await demo.get("/video/:/transcode/universal/ping?session=abc")
            #expect(ping.statusCode == 200)
            try await demo.api.requestVoid(.stopTranscode(session: "abc"))
            let decision = try await demo.json("/video/:/transcode/universal/decision?path=/library/metadata/1001")
            #expect(decision["MediaContainer"] != nil)
        }
    }

    @Test func subtitleStreamsAreServedAsSubRip() async throws {
        try await withDemo { demo in
            let movie = try await demo.metadata("1001")
            let srt = try #require(movie.subtitleStreams.first { $0.format == "srt" })
            let (data, response) = try await demo.get(try #require(srt.key))
            #expect(response.statusCode == 200)
            let text = String(decoding: data, as: UTF8.self)
            #expect(text.contains("-->") && text.hasPrefix("1\n"))
            let spanish = try #require(movie.subtitleStreams.first { $0.language == "Spanish" })
            #expect(String(decoding: try await demo.get(try #require(spanish.key)).0, as: UTF8.self).contains("No deberíamos"))
        }
    }

    @Test func avFoundationPlaysTheDirectPartAndTheHLSRendition() async throws {
        try await withDemo { demo in
            let direct = try await StreamResolver.resolve(api: demo.api, ratingKey: "1001", startSecs: nil, selectedSubtitleId: nil, selectedAudioStreamId: nil)
            let hls = try await StreamResolver.resolve(api: demo.api, ratingKey: "1001", startSecs: nil, selectedSubtitleId: nil, selectedAudioStreamId: nil, forceTranscode: true)
            let asset = AVURLAsset(url: direct.url)
            let (playable, duration) = try await asset.load(.isPlayable, .duration)
            #expect(playable)
            #expect(abs(duration.seconds - 30) < 1.5)
            #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
            #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)

            let ready = await readyDuration(of: hls.url)
            #expect(abs((ready ?? 0) - 30) < 1.5)
        }
    }

    @MainActor
    private func readyDuration(of url: URL) async -> Double? {
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        defer { player.pause() }
        for _ in 0..<100 {
            if item.status == .readyToPlay { return item.duration.seconds }
            if item.status == .failed { return nil }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    @Test func theBundleStaysUnderTwelveMegabytes() throws {
        let root = try DemoAssets.bundled().root
        var total: Int64 = 0
        for case let url as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])! {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        #expect(total > 1_000_000 && total <= 12 * 1_048_576)
    }
}
