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
    /// The sleep timer ran out and paused playback.
    case sleepTimerFired
    /// The audio or subtitle playing changed, from the app's own menus or the system's controls and Siri.
    case tracksChanged
    /// A transcode's clock turned out to map onto the item differently than assumed (`TranscodeClock`): whatever the
    /// surface placed on the player's clock, such as chapters and an Up Next proposal, is placed again.
    case clockRemapped
}
