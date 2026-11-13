import CrucibleCore
import MidgarCore
import Photos
@preconcurrency import UIKit

/// Adds an image to the photo library with add-only access, asking for it the first time, as a lossless PNG so text on
/// the image stays sharp.
enum PhotoLibrarySaver {
    enum Outcome {
        case saved
        case denied
        case failed
    }

    static func save(_ image: UIImage) async -> Outcome {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            MidgarLog.notice("Photo library add access not granted status=\(status.rawValue)", category: .persistence)
            return .denied
        }
        guard let data = image.pngData() else { return .failed }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }
            return .saved
        } catch {
            MidgarLog.error("Saving an image to Photos failed: \(error.localizedDescription)", category: .persistence)
            return .failed
        }
    }
}
