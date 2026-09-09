//
//  TheJymWidgetLiveActivity.swift
//  TheJymWidget
//
//  Renders RestActivityAttributes (shared with the main TheJym target —
//  see its own file, added to this target's Sources build phase too) on
//  the Lock Screen and in the Dynamic Island. Elapsed/remaining time ticks
//  natively via Text(timerInterval:) while running, driven by
//  `virtualStart` below — no per-second updates from the app are needed,
//  only whenever the content state itself changes (resetAndStart on a
//  logged set, or retarget on a swipe to a different exercise), matching
//  RestStopwatch's own wall-clock-anchored model.
//
//  One simplification vs. the in-app view: RestStopwatch counts past 0
//  into negative numbers once a rest period is overdue, but
//  Text(timerInterval:) can't tick a live counter past the end of its own
//  range — it just holds at the range's boundary. So a countdown here
//  ticks down to 0:00 and holds there rather than continuing to count the
//  overdue time, which needs a fresh push from the app to update further
//  anyway (see RestActivityController) — a reasonable "best effort" match
//  for a Live Activity, not full parity with the in-app countdown.
//

import ActivityKit
import WidgetKit
import SwiftUI

private extension RestActivityAttributes.ContentState {
    /// The reference point Text(timerInterval:) counts from so its
    /// displayed value equals accumulatedSeconds + (now - startDate) —
    /// exactly RestStopwatch's own elapsed formula — without the app
    /// needing to push a fresh value every second.
    var virtualStart: Date {
        (startDate ?? Date()).addingTimeInterval(-accumulatedSeconds)
    }
}

@ViewBuilder
private func timerText(_ state: RestActivityAttributes.ContentState) -> some View {
    if let targetSeconds = state.targetSeconds {
        let start = state.virtualStart
        let end = start.addingTimeInterval(max(0, Double(targetSeconds)))
        Text(timerInterval: start...max(end, start), countsDown: true)
    } else {
        Text(timerInterval: state.virtualStart...state.virtualStart.addingTimeInterval(24 * 60 * 60),
             countsDown: false)
    }
}

/// Matches RestStopwatchBar's own icon choice: a plain stopwatch while
/// counting up with no target, a countdown timer glyph once there's one.
private func iconName(_ state: RestActivityAttributes.ContentState) -> String {
    state.targetSeconds == nil ? "stopwatch" : "timer"
}

struct TheJymWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RestActivityAttributes.self) { context in
            HStack {
                Label("Rest", systemImage: iconName(context.state))
                    .font(.headline)
                Spacer()
                timerText(context.state)
                    .font(.system(.title2, design: .monospaced)).bold()
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.8))
            .activitySystemActionForegroundColor(Color.white)
        } dynamicIsland: { context in
            DynamicIsland {
                // A lone .center region (no .leading/.trailing at all)
                // leaves the system with nothing to size the expanded pill
                // around and renders empty — .leading + .trailing is the
                // combination that actually works. The compact pill below
                // is physically split by the camera cutout either way, so
                // compactLeading/compactTrailing can never span or center
                // across it regardless of what the expanded region does.
                DynamicIslandExpandedRegion(.leading) {
                    Label("Rest", systemImage: iconName(context.state))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    timerText(context.state)
                        .font(.system(.title3, design: .monospaced)).bold()
                }
            } compactLeading: {
                Image(systemName: iconName(context.state))
            } compactTrailing: {
                timerText(context.state)
                    .font(.system(.caption, design: .monospaced)).bold()
            } minimal: {
                Image(systemName: iconName(context.state))
            }
        }
    }
}
