import CrucibleCore
import UIKit

extension ConnectionTone {
    package var color: UIColor {
        switch self {
        case .neutral: return Theme.Color.labelTertiary
        case .ok: return Theme.Color.statusOK
        case .failure: return Theme.Color.destructive
        }
    }
}
