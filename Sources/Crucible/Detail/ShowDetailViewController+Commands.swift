import CrucibleCore
@preconcurrency import UIKit

extension ShowDetailViewController: CommandHandling, MediaScreen {
    var mediaRoute: (ratingKey: String, mediaType: String) { (showRatingKey, "show") }

    func canPerform(_ command: AppCommand) -> Bool {
        switch command {
        case .play: return model?.isPrimaryEnabled == true && model?.upNext != nil
        case .rate: return model != nil
        case .refresh: return true
        default: return false
        }
    }

    func perform(_ command: AppCommand) {
        switch command {
        case .play: playUpNext()
        case .rate: rate()
        case .refresh: loadData()
        default: break
        }
    }

    func title(for command: AppCommand) -> String? {
        command == .play ? model?.primaryTitle : nil
    }
}
