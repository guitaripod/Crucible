import Foundation

/// Which Home rail a card belongs to; decides its caption copy and tap behaviour.
package enum HomeBucket: String, Hashable, Sendable {
    case hero
    case continueWatching
    case upNext
    case recentlyAdded
}
