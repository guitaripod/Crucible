import Foundation

/// How sure the app is that the viewer is about to play a title, read off what they are doing rather than asked.
package enum PlayIntent: Int, Sendable, Comparable {
    /// The viewer rests on something that plays when chosen: focus that stopped on a card, a pointer held over it.
    case browsing
    /// Play is the next thing in reach: the title's own page is open with Play on it, or a finger is already down on what
    /// plays it.
    case poised

    package static func < (lhs: PlayIntent, rhs: PlayIntent) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// How far a title has been made ready ahead of Play.
package enum WarmDepth: Int, Sendable, Comparable {
    /// Nothing is done before Play.
    case none
    /// The stream is resolved: the server has been asked what it will send, so Play starts loading at once.
    case resolved
    /// A paused player has loaded the stream at the place playback starts from, so Play shows its picture at once.
    case loaded

    package static func < (lhs: WarmDepth, rhs: WarmDepth) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The word a log line names the depth by.
    package var logName: String {
        switch self {
        case .none: "cold"
        case .resolved: "resolved"
        case .loaded: "loaded"
        }
    }
}

/// What a stream costs the server while nobody is watching it yet.
package enum StreamCost: Sendable, Equatable {
    /// The file as it is: the server only hands out bytes that are asked for.
    case file
    /// The file's video repackaged into a stream, which takes a process on the server and little else.
    case remux
    /// The video encoded anew, which takes a good part of the server's processor or its encoder.
    case encode

    /// A stream served from this device itself, as the built-in demo library's is, costs no server anything however it
    /// is made.
    package init(_ stream: ResolvedStream) {
        if stream.isDirectPlay || ["127.0.0.1", "localhost", "::1"].contains(stream.url.host ?? "") {
            self = .file
        } else if let video = stream.decision?.videoDecision, video != "transcode" {
            self = .remux
        } else {
            self = .encode
        }
    }
}

/// What the device and the app are up to when a title could be made ready.
package struct WarmConditions: Sendable, Equatable {
    /// Instant Start is on in Settings.
    package var isEnabled: Bool
    /// The connection is cellular, where bytes nobody watches cost money.
    package var isCellular: Bool
    /// The device is in Low Power Mode.
    package var savesPower: Bool
    /// The device is hot enough that the system asks apps to do less.
    package var isHot: Bool
    /// Something is already playing here, which the network and the server's transcoder belong to.
    package var isPlaying: Bool

    /// Why nothing may be made ready at all, in a word for the log, or nil when it may.
    package var refusal: String? {
        if !isEnabled { return "switched off" }
        return isHot ? "the device is hot" : nil
    }

    package init(isEnabled: Bool = true, isCellular: Bool = false, savesPower: Bool = false, isHot: Bool = false, isPlaying: Bool = false) {
        self.isEnabled = isEnabled
        self.isCellular = isCellular
        self.savesPower = savesPower
        self.isHot = isHot
        self.isPlaying = isPlaying
    }
}

/// Instant Start: a title the viewer is about to play is made ready before they press Play, as far as it costs nobody
/// anything. Asking the server what it will send is free, so it happens for anything the viewer rests on. Loading the
/// stream is held back wherever it would spend what is not the app's to spend: mobile data, a low battery, the bandwidth of
/// something already playing, or a server's encoder for a title that may never be watched.
package enum WarmStartRule {
    /// How long a title made ready stays ready. After that its start position is no longer trusted and its stream is given back.
    package static let freshness: Duration = .seconds(60)

    /// How long focus or a pointer has to stay on something before it counts as resting there, so a viewer moving through a
    /// shelf makes nothing ready on the way.
    package static let rest: Duration = .milliseconds(400)

    /// How long a viewer has to stay on something that plays when chosen before they count as poised to choose it.
    package static let settle: Duration = .seconds(1)

    /// The seconds of stream a player loads ahead of Play, enough to start without a stall and little enough to throw away.
    package static let forwardBuffer = 10.0

    /// Whether anything may be made ready at all.
    package static func allows(_ conditions: WarmConditions) -> Bool {
        conditions.refusal == nil
    }

    /// How far a title whose stream costs `cost` is made ready for a viewer showing `intent`.
    package static func depth(intent: PlayIntent, cost: StreamCost, conditions: WarmConditions) -> WarmDepth {
        guard allows(conditions) else { return .none }
        guard !conditions.isCellular, !conditions.savesPower, !conditions.isPlaying else { return .resolved }
        switch cost {
        case .file: return .loaded
        case .remux: return intent == .poised ? .loaded : .resolved
        case .encode: return .resolved
        }
    }
}

/// What makes two requests the same playback: a title made ready for one is handed to a Play that asks for the other only
/// when the title, the tracks, the queue and the way the start is chosen all agree.
package struct WarmKey: Equatable, Sendable {
    package enum Start: Equatable, Sendable {
        /// Wherever the server has the title when the stream is resolved.
        case server(ServerStart)
        /// The second the caller named.
        case fixed(Int)
    }

    package let ratingKey: String
    package let mediaType: String
    package let subtitleId: Int?
    package let audioStreamId: Int?
    package let languages: TrackLanguages?
    package let queue: PlaybackQueue?
    package let start: Start

    /// Nil for a downloaded title, which plays from disk and has nothing to make ready.
    package init?(_ request: PlaybackRequest) {
        guard request.offline == nil else { return nil }
        ratingKey = request.ratingKey
        mediaType = request.mediaType
        subtitleId = request.selectedSubtitleId
        audioStreamId = request.selectedAudioStreamId
        languages = request.trackLanguages
        queue = request.queue
        start = request.serverStart.map(Start.server) ?? .fixed(Int(request.resumePosition.rounded()))
    }
}

/// Reads intent off where the viewer stops. A screen says what focus or a pointer moved onto; a move makes whatever the last
/// one started stale, so a viewer travelling along a shelf sets nothing off, and one who stops is first taken to be
/// browsing and, still there a moment later, to be poised to play.
@MainActor
package final class RestWatch {
    private let rest: Duration
    private let settle: Duration
    private let left: @MainActor (String) -> Void
    private var subject: String?
    private var task: Task<Void, Never>?

    /// `left` is told the subject the viewer moved away from, whatever had been made of their stay on it.
    package init(rest: Duration = WarmStartRule.rest, settle: Duration = WarmStartRule.settle, left: @escaping @MainActor (String) -> Void) {
        self.rest = rest
        self.settle = settle
        self.left = left
    }

    /// The viewer moved onto `subject`, or onto nothing that plays (nil). `rested` runs with each intent their stay earns.
    /// Moving onto the subject they are already on changes nothing.
    package func moved(onto subject: String?, rested: (@MainActor (PlayIntent) -> Void)? = nil) {
        guard subject != self.subject else { return }
        task?.cancel()
        task = nil
        if let previous = self.subject { left(previous) }
        self.subject = subject
        guard subject != nil, let rested else { return }
        task = Task { [rest, settle] in
            try? await Task.sleep(for: rest)
            guard !Task.isCancelled else { return }
            rested(.browsing)
            try? await Task.sleep(for: settle - rest)
            guard !Task.isCancelled else { return }
            rested(.poised)
        }
    }
}

extension Preferences {
    private static let instantStartKey = "instantStart"

    /// Makes a title ready before Play is pressed (`WarmStartRule`). On by default.
    package static var instantStart: Bool {
        get { UserDefaults.standard.object(forKey: instantStartKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: instantStartKey) }
    }
}
