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

private typealias State = DownloadActivityAttributes.ContentState

private struct ArtworkView: View {
    let path: String?
    let size: CGFloat
    let cornerRadius: CGFloat
    let symbol: String
    let accent: Color

    var body: some View {
        Group {
            if let path, let image = UIImage(contentsOfFile: path) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.white.opacity(0.12))
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.42))
                        .foregroundStyle(accent)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

struct DownloadLiveActivity: Widget {
    fileprivate static let accent = Color(red: 1.0, green: 0.58, blue: 0.0)

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            lockScreen(context.state)
                .padding()
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ArtworkView(path: state.artworkPath, size: 42, cornerRadius: 6,
                                symbol: state.isPaused ? "pause.circle.fill" : "arrow.down.circle.fill",
                                accent: Self.accent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(state.itemPercentText)
                            .font(.title3).monospacedDigit().bold()
                            .foregroundStyle(.white)
                        if let eta = state.etaText {
                            Text(eta).font(.caption2).foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(state.showTitle)
                            .font(.subheadline).bold().foregroundStyle(.white).lineLimit(1)
                        Text(state.subtitleText)
                            .font(.caption2).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: state.clampedItemFraction).tint(Self.accent)
                        HStack {
                            if let batch = state.batchText {
                                Text(batch).font(.caption2).foregroundStyle(.white.opacity(0.7))
                            }
                            Spacer()
                            Text(state.bytesText)
                                .font(.caption2).monospacedDigit().foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: state.isPaused ? "pause.fill" : "arrow.down.circle.fill")
                    .foregroundStyle(Self.accent)
            } compactTrailing: {
                Text(state.itemPercentText)
                    .monospacedDigit()
                    .foregroundStyle(.white)
            } minimal: {
                Gauge(value: state.clampedItemFraction) {
                    Image(systemName: "arrow.down")
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(Self.accent)
            }
            .keylineTint(Self.accent)
        }
    }

    @ViewBuilder
    private func lockScreen(_ state: State) -> some View {
        HStack(spacing: 12) {
            ArtworkView(path: state.artworkPath, size: 58, cornerRadius: 8,
                        symbol: state.isPaused ? "pause.circle.fill" : "arrow.down.circle.fill",
                        accent: Self.accent)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(state.showTitle)
                        .font(.subheadline).bold().foregroundStyle(.white).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(state.itemPercentText)
                        .font(.subheadline).monospacedDigit().bold().foregroundStyle(.white)
                }
                Text(state.subtitleText)
                    .font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                ProgressView(value: state.clampedItemFraction).tint(Self.accent)
                HStack(spacing: 6) {
                    if let batch = state.batchText {
                        Text(batch)
                        Text("·")
                    }
                    Text(state.bytesText)
                    Spacer(minLength: 4)
                    if state.isPaused {
                        Text(state.statusText)
                    } else if let eta = state.etaText {
                        Text(eta)
                    }
                }
                .font(.caption2).monospacedDigit().foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
        }
    }
}
#endif
