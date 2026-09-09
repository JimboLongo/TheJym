//
//  TheJymWidgetLiveActivity.swift
//  TheJymWidget
//
//  Renders WorkoutActivityAttributes (shared with the main TheJym target —
//  see its own file, added to this target's Sources build phase too) on
//  the Lock Screen and in the Dynamic Island. Elapsed time ticks natively
//  via Text(timerInterval:) while running, driven by `virtualStart` below
//  — no per-second updates from the app are needed, only whenever the
//  content state itself changes (Start/Pause/Resume/Reset), matching
//  WorkoutStopwatch's own wall-clock-anchored model.
//

import ActivityKit
import WidgetKit
import SwiftUI

private extension WorkoutActivityAttributes.ContentState {
    /// The reference point Text(timerInterval:) counts up from so its
    /// displayed elapsed time equals accumulatedSeconds + (now - startDate)
    /// — exactly WorkoutStopwatch.elapsed's own formula — without the app
    /// needing to push a fresh value every second.
    var virtualStart: Date {
        (startDate ?? Date()).addingTimeInterval(-accumulatedSeconds)
    }
}

/// Same mm:ss / h:mm:ss shape as the app's own Formatters.duration — kept
/// as a private copy rather than a shared file, since this is the only
/// place in the widget extension that needs it and it's a two-line
/// function, not worth a second shared-file wiring for.
private func staticDuration(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

@ViewBuilder
private func elapsedText(_ state: WorkoutActivityAttributes.ContentState) -> some View {
    if state.isRunning {
        Text(timerInterval: state.virtualStart...state.virtualStart.addingTimeInterval(24 * 60 * 60),
             countsDown: false)
    } else {
        Text(staticDuration(state.accumulatedSeconds))
    }
}

struct TheJymWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            HStack {
                Label("Workout", systemImage: "figure.strengthtraining.traditional")
                    .font(.headline)
                Spacer()
                elapsedText(context.state)
                    .font(.system(.title2, design: .monospaced)).bold()
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.8))
            .activitySystemActionForegroundColor(Color.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Workout", systemImage: "figure.strengthtraining.traditional")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    elapsedText(context.state)
                        .font(.system(.title3, design: .monospaced)).bold()
                }
            } compactLeading: {
                Image(systemName: "figure.strengthtraining.traditional")
            } compactTrailing: {
                elapsedText(context.state)
                    .font(.system(.caption, design: .monospaced)).bold()
            } minimal: {
                Image(systemName: "figure.strengthtraining.traditional")
            }
        }
    }
}
