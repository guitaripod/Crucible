import Foundation

package enum SearchHighlight {
    /// The ranges of `text` that the query matched: the whole query when it occurs, otherwise each
    /// query word that does. Matching ignores case and diacritics.
    package static func matchRanges(of query: String, in text: String) -> [NSRange] {
        let nsText = text as NSString
        let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let whole = nsText.range(of: query, options: options)
        if whole.location != NSNotFound { return [whole] }
        return query.split(whereSeparator: \.isWhitespace).compactMap { word in
            let range = nsText.range(of: String(word), options: options)
            return range.location == NSNotFound ? nil : range
        }
    }
}
