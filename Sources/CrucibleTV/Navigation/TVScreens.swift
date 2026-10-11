import UIKit

/// The one catalogue of screens. Every feature adds its factories in its own
/// `Screens+<Feature>.swift` extension, so features construct each other's screens without
/// importing each other's types, and this file never changes when a screen is built.
@MainActor
enum TVScreens {
    /// The detail screen for any item: the show screen for shows, the movie/episode screen otherwise.
    static func detail(_ env: TVAppEnvironment, ratingKey: String, mediaType: String) -> UIViewController {
        if mediaType == "show" {
            return showDetail(env, ratingKey: ratingKey, initialSeasonKey: nil)
        }
        return movieDetail(env, ratingKey: ratingKey, mediaType: mediaType)
    }
}
