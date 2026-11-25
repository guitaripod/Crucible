import AVKit
import CrucibleCore
import CrucibleDesign
import CrucibleMedia
@preconcurrency import UIKit

/// What the keyboard and the remote ask the player for: the skip on screen, the next episode it
/// offers, and closing.
extension PlayerCoordinator {

    // MARK: - Keyboard

    /// What the on-screen skip button offers right now ("Skip Intro"), so the keyboard can take it too.
    var skipTitle: String? { shownSkip?.title }

    var offersNextEpisode: Bool { shownUpNext != nil }

    func performShownSkip() {
        guard let shownSkip else { return }
        Haptics.light()
        viewerActed()
        skip(to: shownSkip.target)
    }

    func close() {
        Task { await dismissPlayer() }
    }

    func playOfferedNextEpisode() {
        guard let shownUpNext else { return }
        playNext(shownUpNext, byViewer: true)
    }
}
