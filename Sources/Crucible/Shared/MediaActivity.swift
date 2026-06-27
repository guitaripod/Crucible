import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

enum MediaActivity {
    static let type = "com.guitaripod.crucible.viewMedia"
    static let ratingKeyKey = "ratingKey"
    static let typeKey = "mediaType"

    static func make(ratingKey: String, mediaType: String, title: String, subtitle: String?, summary: String?, thumbPath: String?) -> NSUserActivity {
        let activity = NSUserActivity(activityType: Self.type)
        let identifier = "\(mediaType):\(ratingKey)"
        activity.title = title
        activity.userInfo = [ratingKeyKey: ratingKey, typeKey: mediaType]
        activity.requiredUserInfoKeys = [ratingKeyKey, typeKey]
        activity.persistentIdentifier = identifier
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = true
        activity.isEligibleForPrediction = true

        let attributes = CSSearchableItemAttributeSet(contentType: .audiovisualContent)
        attributes.title = title
        attributes.contentDescription = summary ?? subtitle
        attributes.relatedUniqueIdentifier = identifier
        activity.contentAttributeSet = attributes
        activity.keywords = Set([title, subtitle].compactMap { $0 })
        return activity
    }

    static func route(_ activity: NSUserActivity) -> (ratingKey: String, mediaType: String)? {
        guard activity.activityType == Self.type else { return nil }
        if let ratingKey = activity.userInfo?[ratingKeyKey] as? String {
            let mediaType = activity.userInfo?[typeKey] as? String ?? "movie"
            return (ratingKey, mediaType)
        }
        if let identifier = activity.persistentIdentifier {
            return parse(identifier)
        }
        return nil
    }

    private static func parse(_ identifier: String) -> (ratingKey: String, mediaType: String)? {
        let parts = identifier.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return (String(parts[1]), String(parts[0]))
    }
}
