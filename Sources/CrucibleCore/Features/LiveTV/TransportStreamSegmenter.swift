import Foundation

/// Cuts a continuous MPEG transport stream (what most IPTV services send) into HLS segments, so AVPlayer, which plays HLS
/// but not a bare transport stream, can show it. Every segment starts on a video keyframe with the stream's PAT and PMT in
/// front, so each can be decoded on its own; a stream with no video is cut on its audio timestamps.
package struct TransportStreamSegmenter: Sendable {
    package struct Segment: Sendable, Equatable {
        package let sequence: Int
        package let data: Data
        package let duration: Double
        /// The stream's clock started over at this segment (a looped or restarted channel), which HLS must be told.
        package var discontinuity = false

        package init(sequence: Int, data: Data, duration: Double, discontinuity: Bool = false) {
            self.sequence = sequence
            self.data = data
            self.duration = duration
            self.discontinuity = discontinuity
        }
    }

    private static let packetSize = 188
    private static let syncByte: UInt8 = 0x47
    private static let clock = 90_000.0
    private static let ptsWrap: Int64 = 1 << 33

    package let targetDuration: Double
    /// The longest a segment may run when no keyframe comes, after which it is cut anyway.
    package let maximumDuration: Double
    private var pending: [UInt8] = []
    private var pat: [UInt8]?
    private var pmt: [UInt8]?
    private var pmtPID: Int?
    private var videoPID: Int?
    private var audioPID: Int?
    private var videoIsHEVC = false
    private var current: [UInt8] = []
    private var currentStartPTS: Int64?
    private var lastPTS: Int64?
    private var nextSequence = 0
    private var started = false
    private var currentIsDiscontinuity = false
    /// The bytes read so far, for the relay's log.
    package private(set) var bytesRead = 0

    /// `firstSequence` carries the numbering on when a dropped stream is read again from scratch.
    package init(targetDuration: Double = 2, maximumDuration: Double = 8, firstSequence: Int = 0) {
        self.targetDuration = targetDuration
        self.maximumDuration = maximumDuration
        nextSequence = firstSequence
    }

    /// The number the next segment will carry.
    package var nextSequenceNumber: Int { nextSequence }

    /// Whether the stream's tables named a video stream.
    package var hasVideo: Bool { videoPID != nil }

    /// Takes the next bytes of the stream and returns the segments they finished.
    package mutating func append(_ data: Data) -> [Segment] {
        bytesRead += data.count
        pending.append(contentsOf: data)
        var finished: [Segment] = []
        var offset = 0
        while pending.count - offset >= Self.packetSize {
            guard pending[offset] == Self.syncByte else {
                offset = resync(from: offset + 1) ?? (pending.count - Self.packetSize + 1)
                continue
            }
            let packet = Array(pending[offset..<(offset + Self.packetSize)])
            offset += Self.packetSize
            if let segment = take(packet) { finished.append(segment) }
        }
        pending.removeFirst(min(offset, pending.count))
        return finished
    }

    /// The segment in progress, cut where the stream stopped.
    package mutating func flush() -> Segment? {
        guard started, !current.isEmpty else { return nil }
        return cut(at: lastPTS)
    }

    /// The next offset at which three packets in a row start with the sync byte.
    private func resync(from start: Int) -> Int? {
        var offset = start
        while offset + Self.packetSize * 2 < pending.count {
            if pending[offset] == Self.syncByte, pending[offset + Self.packetSize] == Self.syncByte, pending[offset + Self.packetSize * 2] == Self.syncByte {
                return offset
            }
            offset += 1
        }
        return nil
    }

    private mutating func take(_ packet: [UInt8]) -> Segment? {
        let pid = Int(packet[1] & 0x1F) << 8 | Int(packet[2])
        let unitStart = packet[1] & 0x40 != 0
        let adaptation = (packet[3] >> 4) & 0x3
        let payloadStart = Self.payloadOffset(packet, adaptation: adaptation)
        if pid == 0 {
            if unitStart, let payloadStart { readPAT(packet, from: payloadStart) }
            pat = packet
            return nil
        }
        if pid == pmtPID {
            if unitStart, let payloadStart { readPMT(packet, from: payloadStart) }
            pmt = packet
            return nil
        }
        let timing = pid == (videoPID ?? audioPID)
        var segment: Segment?
        if timing, unitStart, let payloadStart, let pts = Self.pts(packet, from: payloadStart) {
            let isKey = videoPID == nil || Self.randomAccess(packet, adaptation: adaptation) || isKeyframe(packet, from: payloadStart)
            if !started {
                if isKey, pat != nil, pmt != nil {
                    started = true
                    begin(at: pts)
                }
            } else if let startPTS = currentStartPTS {
                let elapsed = Self.seconds(from: startPTS, to: pts)
                let jumped = elapsed < 0 || elapsed > maximumDuration * 4
                if jumped, isKey {
                    segment = cut(at: lastPTS ?? pts)
                    begin(at: pts)
                    currentIsDiscontinuity = true
                } else if !jumped, (isKey && elapsed >= targetDuration) || elapsed >= maximumDuration {
                    segment = cut(at: pts)
                    begin(at: pts)
                }
            }
            lastPTS = pts
        }
        if started { current.append(contentsOf: packet) }
        return segment
    }

    private mutating func begin(at pts: Int64) {
        current.removeAll(keepingCapacity: true)
        if let pat { current.append(contentsOf: pat) }
        if let pmt { current.append(contentsOf: pmt) }
        currentStartPTS = pts
    }

    private mutating func cut(at pts: Int64?) -> Segment? {
        guard let start = currentStartPTS else { return nil }
        let duration = pts.map { Self.seconds(from: start, to: $0) } ?? targetDuration
        let segment = Segment(sequence: nextSequence, data: Data(current), duration: max(duration, 0.1), discontinuity: currentIsDiscontinuity)
        currentIsDiscontinuity = false
        nextSequence += 1
        current.removeAll(keepingCapacity: true)
        currentStartPTS = nil
        return segment
    }

    private static func payloadOffset(_ packet: [UInt8], adaptation: UInt8) -> Int? {
        switch adaptation {
        case 1: return 4
        case 3:
            let offset = 5 + Int(packet[4])
            return offset < packet.count ? offset : nil
        default: return nil
        }
    }

    private static func randomAccess(_ packet: [UInt8], adaptation: UInt8) -> Bool {
        guard adaptation >= 2, packet[4] > 0 else { return false }
        return packet[5] & 0x40 != 0
    }

    private mutating func readPAT(_ packet: [UInt8], from payload: Int) {
        let table = payload + 1 + Int(packet[payload])
        guard table + 8 < packet.count else { return }
        let sectionLength = Int(packet[table + 1] & 0x0F) << 8 | Int(packet[table + 2])
        let end = min(table + 3 + sectionLength - 4, packet.count - 4)
        var entry = table + 8
        while entry + 4 <= end {
            let program = Int(packet[entry]) << 8 | Int(packet[entry + 1])
            let pid = Int(packet[entry + 2] & 0x1F) << 8 | Int(packet[entry + 3])
            if program != 0 {
                pmtPID = pid
                return
            }
            entry += 4
        }
    }

    private mutating func readPMT(_ packet: [UInt8], from payload: Int) {
        let table = payload + 1 + Int(packet[payload])
        guard table + 12 < packet.count else { return }
        let sectionLength = Int(packet[table + 1] & 0x0F) << 8 | Int(packet[table + 2])
        let programInfoLength = Int(packet[table + 10] & 0x0F) << 8 | Int(packet[table + 11])
        let end = min(table + 3 + sectionLength - 4, packet.count)
        var entry = table + 12 + programInfoLength
        var video: (pid: Int, hevc: Bool)?
        var audio: Int?
        while entry + 5 <= end {
            let type = packet[entry]
            let pid = Int(packet[entry + 1] & 0x1F) << 8 | Int(packet[entry + 2])
            let infoLength = Int(packet[entry + 3] & 0x0F) << 8 | Int(packet[entry + 4])
            switch type {
            case 0x1B, 0x02, 0x01, 0x10: if video == nil { video = (pid, false) }
            case 0x24: if video == nil { video = (pid, true) }
            case 0x0F, 0x03, 0x04, 0x81, 0x87, 0x11: if audio == nil { audio = pid }
            default: break
            }
            entry += 5 + infoLength
        }
        videoPID = video?.pid
        videoIsHEVC = video?.hevc ?? false
        audioPID = audio
    }

    /// A PES header's presentation timestamp.
    private static func pts(_ packet: [UInt8], from payload: Int) -> Int64? {
        guard payload + 14 <= packet.count, packet[payload] == 0, packet[payload + 1] == 0, packet[payload + 2] == 1 else { return nil }
        guard packet[payload + 7] & 0x80 != 0 else { return nil }
        let p = payload + 9
        let high = Int64(packet[p] >> 1 & 0x07) << 30
        let middle = (Int64(packet[p + 1]) << 7 | Int64(packet[p + 2] >> 1)) << 15
        let low = Int64(packet[p + 3]) << 7 | Int64(packet[p + 4] >> 1)
        return high | middle | low
    }

    /// Whether the first packet of a video PES carries a keyframe: an H.264 IDR or sequence parameter set, or an HEVC
    /// IRAP picture or parameter set.
    private func isKeyframe(_ packet: [UInt8], from payload: Int) -> Bool {
        guard payload + 9 < packet.count else { return false }
        var index = payload + 9 + Int(packet[payload + 8])
        while index + 3 < packet.count {
            if packet[index] == 0, packet[index + 1] == 0, packet[index + 2] == 1 {
                let header = packet[index + 3]
                if videoIsHEVC {
                    let type = (header >> 1) & 0x3F
                    if (16...21).contains(type) || (32...34).contains(type) { return true }
                } else {
                    let type = header & 0x1F
                    if type == 5 || type == 7 { return true }
                }
                index += 3
            } else {
                index += 1
            }
        }
        return false
    }

    private static func seconds(from start: Int64, to end: Int64) -> Double {
        var delta = end - start
        if delta < -ptsWrap / 2 { delta += ptsWrap }
        if delta > ptsWrap / 2 { delta -= ptsWrap }
        return Double(delta) / clock
    }
}

/// The sliding window of segments a live HLS playlist offers.
package struct LiveHLSWindow: Sendable {
    package let capacity: Int
    package private(set) var segments: [TransportStreamSegmenter.Segment] = []
    /// Segments that begin a stream read again after it dropped, which the playlist marks as a discontinuity.
    private var discontinuities: Set<Int> = []
    /// Discontinuities that slid out of the window, which `EXT-X-DISCONTINUITY-SEQUENCE` counts.
    private var passedDiscontinuities = 0

    package init(capacity: Int = 10) {
        self.capacity = capacity
    }

    package mutating func add(_ segment: TransportStreamSegmenter.Segment, discontinuity: Bool = false) {
        segments.append(segment)
        if discontinuity || segment.discontinuity { discontinuities.insert(segment.sequence) }
        if segments.count > capacity { segments.removeFirst(segments.count - capacity) }
        if let first = segments.first?.sequence {
            let passed = discontinuities.filter { $0 <= first }
            passedDiscontinuities += passed.count
            discontinuities.subtract(passed)
        }
    }

    package func segment(_ sequence: Int) -> TransportStreamSegmenter.Segment? {
        segments.first { $0.sequence == sequence }
    }

    /// The media playlist naming the segments as `segment-<n>.ts`, relative to the playlist.
    package var playlist: String {
        let target = Int((segments.map(\.duration).max() ?? 2).rounded(.up))
        let first = segments.first?.sequence ?? 0
        let discontinuitySequence = passedDiscontinuities
        var lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:\(max(target, 1))", "#EXT-X-MEDIA-SEQUENCE:\(first)"]
        if discontinuitySequence > 0 { lines.append("#EXT-X-DISCONTINUITY-SEQUENCE:\(discontinuitySequence)") }
        for segment in segments {
            if discontinuities.contains(segment.sequence) { lines.append("#EXT-X-DISCONTINUITY") }
            lines.append(String(format: "#EXTINF:%.3f,", segment.duration))
            lines.append("segment-\(segment.sequence).ts")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
