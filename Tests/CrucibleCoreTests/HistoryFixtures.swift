import Foundation
@testable import CrucibleCore

enum HistoryFixtures {
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static let now: Date = utc.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 12))!

    static var nowSeconds: Int { Int(now.timeIntervalSince1970) }

    static func ago(days: Int = 0, hours: Int = 0) -> Int {
        nowSeconds - days * 86_400 - hours * 3_600
    }

    static func json(
        key: String,
        type: String? = "movie",
        title: String = "Title",
        viewedAt: Int? = nil,
        lastViewedAt: Int? = nil,
        addedAt: Int? = nil,
        duration: Int? = nil,
        thumb: String? = nil,
        extra: String = ""
    ) -> String {
        var fields = [#""ratingKey": "\#(key)""#, #""title": "\#(title)""#]
        if let type { fields.append(#""type": "\#(type)""#) }
        if let viewedAt { fields.append(#""viewedAt": \#(viewedAt)"#) }
        if let lastViewedAt { fields.append(#""lastViewedAt": \#(lastViewedAt)"#) }
        if let addedAt { fields.append(#""addedAt": \#(addedAt)"#) }
        if let duration { fields.append(#""duration": \#(duration)"#) }
        if let thumb { fields.append(#""thumb": "\#(thumb)""#) }
        if !extra.isEmpty { fields.append(extra) }
        return "{" + fields.joined(separator: ", ") + "}"
    }

    static func container(total: Int?, rows: [String]) -> PlexMediaContainer {
        var fields = [#""Metadata": [\#(rows.joined(separator: ","))]"#]
        if let total { fields.append(#""totalSize": \#(total)"#) }
        let json = #"{"MediaContainer": {\#(fields.joined(separator: ", "))}}"#
        return try! JSONDecoder().decode(PlexResponse.self, from: Data(json.utf8)).MediaContainer
    }

    static func metadata(_ row: String) -> PlexMetadata {
        container(total: 1, rows: [row]).Metadata![0]
    }

    static func item(
        key: String = "1",
        type: String? = "movie",
        title: String = "Title",
        viewedAt: Int? = nil,
        duration: Int? = nil,
        thumb: String? = nil,
        grandparentThumb: String? = nil,
        grandparentTitle: String? = nil,
        grandparentRatingKey: String? = nil,
        parentRatingKey: String? = nil,
        parentIndex: Int? = nil,
        index: Int? = nil
    ) -> HistoryItem {
        HistoryItem(
            ratingKey: key,
            title: title,
            type: type,
            viewedAt: viewedAt,
            thumb: thumb,
            grandparentThumb: grandparentThumb,
            grandparentTitle: grandparentTitle,
            grandparentRatingKey: grandparentRatingKey,
            parentRatingKey: parentRatingKey,
            parentIndex: parentIndex,
            index: index,
            duration: duration,
            uniqueId: "\(key)-0"
        )
    }
}
