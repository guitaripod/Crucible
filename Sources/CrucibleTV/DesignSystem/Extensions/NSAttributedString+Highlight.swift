import CrucibleCore
import CrucibleDesign
import UIKit

extension NSAttributedString {
    /// `text` with the part the search `query` matched in the accent colour; plain when there is no query.
    static func highlighting(_ text: String, query: String?, font: UIFont, color: UIColor) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        guard let query, !query.isEmpty else { return result }
        for range in SearchHighlight.matchRanges(of: query, in: text) {
            result.addAttribute(.foregroundColor, value: Theme.Color.accentText, range: range)
        }
        return result
    }
}
