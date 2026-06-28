#if canImport(ActivityKit)
import ActivityKit
import Foundation

/// Shared between the app (which starts/updates the Live Activity) and the widget extension
/// (which renders it on the Lock Screen and in the Dynamic Island).
public struct DownloadActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var title: String
        public var detail: String
        public var fractionCompleted: Double
        public var completedCount: Int
        public var totalCount: Int
        public var isPaused: Bool

        public init(
            title: String,
            detail: String,
            fractionCompleted: Double,
            completedCount: Int,
            totalCount: Int,
            isPaused: Bool
        ) {
            self.title = title
            self.detail = detail
            self.fractionCompleted = fractionCompleted
            self.completedCount = completedCount
            self.totalCount = totalCount
            self.isPaused = isPaused
        }

        public var percentText: String { "\(Int((fractionCompleted * 100).rounded()))%" }
        public var queueText: String? { totalCount > 1 ? "\(completedCount + 1) of \(totalCount)" : nil }
    }

    public init() {}
}
#endif
