#if os(iOS) && canImport(ActivityKit)
import ActivityKit
import CrucibleActivity
import SwiftUI
import WidgetKit

@main
struct CrucibleWidgetBundle: WidgetBundle {
    var body: some Widget {
        DownloadLiveActivity()
    }
}

struct DownloadLiveActivity: Widget {
    private static let accent = Color(red: 1.0, green: 0.58, blue: 0.0)

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            lockScreen(context.state)
                .padding()
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.isPaused ? "pause.circle.fill" : "arrow.down.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Self.accent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.percentText)
                        .font(.title3).monospacedDigit().bold()
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.state.title)
                            .font(.subheadline).bold()
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(subtitle(context.state))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                        ProgressView(value: clampedFraction(context.state))
                            .tint(Self.accent)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.isPaused ? "pause.fill" : "arrow.down.circle.fill")
                    .foregroundStyle(Self.accent)
            } compactTrailing: {
                Text(context.state.percentText)
                    .monospacedDigit()
                    .foregroundStyle(.white)
            } minimal: {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(Self.accent)
            }
            .keylineTint(Self.accent)
        }
    }

    @ViewBuilder
    private func lockScreen(_ state: DownloadActivityAttributes.ContentState) -> some View {
        HStack(spacing: 14) {
            Image(systemName: state.isPaused ? "pause.circle.fill" : "arrow.down.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(Self.accent)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(state.title)
                        .font(.subheadline).bold()
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer()
                    Text(state.percentText)
                        .font(.subheadline).monospacedDigit().bold()
                        .foregroundStyle(.white)
                }
                Text(subtitle(state))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                ProgressView(value: clampedFraction(state))
                    .tint(Self.accent)
            }
        }
    }

    private func subtitle(_ state: DownloadActivityAttributes.ContentState) -> String {
        if state.isPaused { return state.detail.isEmpty ? "Paused" : state.detail }
        var parts = [String]()
        if let queue = state.queueText { parts.append(queue) }
        if !state.detail.isEmpty { parts.append(state.detail) }
        return parts.isEmpty ? "Downloading" : parts.joined(separator: " · ")
    }

    private func clampedFraction(_ state: DownloadActivityAttributes.ContentState) -> Double {
        min(1, max(0, state.fractionCompleted))
    }
}
#endif
