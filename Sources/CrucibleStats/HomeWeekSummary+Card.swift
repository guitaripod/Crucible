import CrucibleCore
import Foundation

extension HomeWeekSummary {
    /// The This Week card's display data; nil when there is no watch time this week or last.
    package var cardModel: HomeWeekCardModel? {
        guard !isEmpty else { return nil }
        return HomeWeekCardModel(
            dailySeconds: dailySeconds,
            todayIndex: todayIndex,
            thisWeekSeconds: thisWeekSeconds,
            deltaPercent: deltaPercent
        )
    }
}

extension StatsStore {
    /// `homeWeekSummary` with a failure logged and reported as no summary, which hides the card.
    package func homeWeekSummaryOrNil(now: Date = Date()) async -> HomeWeekSummary? {
        do {
            return try await homeWeekSummary(now: now)
        } catch {
            AppLogger.error("Home week summary failed: \(error.localizedDescription)", .stats)
            return nil
        }
    }
}
