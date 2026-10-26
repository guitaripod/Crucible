import Foundation

/// Why the end of an item produced no further playback.
package enum PlaybackFinish: Sendable {
    case noNextEpisode
    case standalone
}

/// What a playback session tells its player surface.
package enum PlaybackEvent: Sendable {
    case position(absolute: Double, rate: Double)
    /// The viewer paused, played or scrubbed: someone is watching.
    case viewerActed
    case skipAvailable(SkipMarker, progress: Double)
    case skipHidden
    case autoSkipped(SkipMarker, returnTo: Double)
    case autoSkipUndoExpired
    case upNext(UpNextOffer)
    case failed(String)
    case finished(PlaybackFinish)
}
