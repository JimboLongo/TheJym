//
//  ClaudeStatsView.swift
//  TheJym
//
//  A one-glance "how am I actually doing" page, distinct from the Stats
//  tab's exhaustive table/grid layout — narrative status line, a single
//  composite Momentum ring, a Consistency Calendar heatmap, and a short
//  feed of this week's wins. Every underlying number is read from
//  StatsEngine/StatsAndPlates exactly as StatsView itself does; the only
//  new logic here is presentation, plus the two small engines added
//  alongside StatsEngine in StatsAndPlates.swift (MomentumEngine,
//  StatsEngine.consistencyDayKind) for the two genuinely new pieces of
//  math this page needed.
//

import SwiftUI
import SwiftData

struct ClaudeStatsView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Query private var settingsList: [AppSettings]
    @Query(sort: \WorkoutSession.date) private var sessions: [WorkoutSession]
    @Query private var restActivities: [RestDayActivity]
    @Query(sort: \ActiveRecovery.date) private var activeRecoveries: [ActiveRecovery]
    @Query(sort: \TrainingDaysPerWeekChange.date) private var tdpwChanges: [TrainingDaysPerWeekChange]
    @Query private var phases: [Phase]
    @Query(sort: \ExerciseDef.name) private var exerciseDefs: [ExerciseDef]

    @State private var selectedDay: SelectedDay?

    private let calendarWeeks = 12

    private var settings: AppSettings? { settingsList.first }
    private var activePhase: Phase? { phases.first(where: \.isActive) }

    private var realSessionDates: [Date] {
        sessions.filter { !$0.exerciseLogs.isEmpty }.map(\.date)
    }

    private var stats: TrainingStats {
        StatsEngine.compute(startDate: settings?.trainingStartDate ?? .now,
                            sessionDates: realSessionDates,
                            restActivityDates: restActivities.map(\.date),
                            activeRecoveryDates: activeRecoveries.map(\.date),
                            phaseSchedules: phases.map {
                                StatsEngine.PhaseSchedule(startDate: $0.startDate, phase: $0)
                            },
                            allPhases: phases,
                            activePhase: activePhase,
                            restActivities: restActivities,
                            trainingDaysPerWeekChanges: tdpwChanges.map { (date: $0.date, value: $0.trainingDaysPerWeek) },
                            defaultTrainingDaysPerWeek: settings?.trainingDaysPerWeek ?? 3,
                            allSessions: sessions,
                            bigLiftNames: exerciseDefs.filter(\.isBigLift).map(\.name))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                statusLineSection
                momentumSection
                consistencyCalendarSection
                winsSection
            }
            .padding()
        }
        .navigationTitle("Claude Stats")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 1. Status line

    private var statusLine: String {
        guard let phase = activePhase else {
            return stats.currentStreak > 0
                ? "Between phases · \(stats.currentStreak)-day streak going"
                : "Between phases · log a workout to start a new streak"
        }
        let dayCount = phase.filledSlotCount
        let paceLabel: String
        if let delta = stats.cyclePaceDelta {
            if delta > 0 { paceLabel = "\(delta) day\(delta == 1 ? "" : "s") ahead" }
            else if delta < 0 { paceLabel = "\(-delta) day\(delta == -1 ? "" : "s") behind" }
            else { paceLabel = "on pace" }
        } else {
            paceLabel = "on pace"
        }
        let streakLabel = stats.currentStreak > 0
            ? "\(stats.currentStreak)-day streak"
            : "no streak right now"
        return "Day \(dayCount) of Phase \(phase.number) · \(paceLabel) · \(streakLabel)"
    }

    private var statusLineSection: some View {
        Text(statusLine)
            .font(.headline)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 2. Momentum ring

    private var momentumScore: Int {
        MomentumEngine.score(adherencePercent: stats.adherencePercent,
                             cyclePaceDelta: stats.cyclePaceDelta,
                             currentStreak: stats.currentStreak,
                             percentLogged: stats.percentLogged)
    }

    private var momentumColor: Color {
        switch momentumScore {
        case 70...100: return .green
        case 40..<70: return .orange
        default: return .red
        }
    }

    private var momentumSection: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 14)
                Circle()
                    .trim(from: 0, to: CGFloat(momentumScore) / 100)
                    .stroke(momentumColor, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 2) {
                    Text("\(momentumScore)")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(momentumColor)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    Text("Momentum")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                }
                .padding(8)
            }
            .frame(width: 160, height: 160)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 3. Consistency calendar

    private var weeksGrid: [[Date]] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let todayWeekday = cal.component(.weekday, from: today)   // 1 (Sun) ... 7 (Sat)
        guard let currentWeekStart = cal.date(byAdding: .day, value: -(todayWeekday - 1), to: today) else { return [] }
        return (0..<calendarWeeks).map { weekOffset -> [Date] in
            let weeksAgo = calendarWeeks - 1 - weekOffset
            guard let weekStart = cal.date(byAdding: .day, value: -weeksAgo * 7, to: currentWeekStart) else { return [] }
            return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: weekStart) }
        }
    }

    private func color(for kind: ConsistencyDayKind) -> Color {
        switch kind {
        case .trained: return .green
        case .deload: return .green.opacity(0.4)
        case .rest: return .secondary.opacity(0.35)
        case .empty: return .secondary.opacity(0.08)
        }
    }

    private func detailLabel(for date: Date) -> String {
        let cal = Calendar.current
        let daySessions = sessions.filter { cal.isDate($0.date, inSameDayAs: date) }
        guard !daySessions.isEmpty else { return "Nothing logged" }
        if let trained = daySessions.first(where: { session in
            session.exerciseLogs.contains { $0.restDayActivity == nil }
        }) {
            return trained.isDeload ? "\(trained.dayLabel) (Deload)" : trained.dayLabel
        }
        if let activity = daySessions.flatMap(\.exerciseLogs).first(where: { $0.restDayActivity != nil })?.restDayActivity {
            return activity.name
        }
        return "Rest Day"
    }

    private var consistencyCalendarSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Consistency")
                .font(.title3.bold())
            VStack(spacing: 4) {
                ForEach(Array(weeksGrid.enumerated()), id: \.offset) { _, week in
                    HStack(spacing: 4) {
                        ForEach(week, id: \.self) { date in
                            dayCell(for: date)
                        }
                    }
                }
            }
        }
        .popover(item: $selectedDay) { day in
            VStack(alignment: .leading, spacing: 4) {
                Text(Formatters.date.string(from: day.date))
                    .font(.headline)
                Text(day.label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .presentationCompactAdaptation(.popover)
        }
    }

    private struct SelectedDay: Identifiable {
        let date: Date
        let label: String
        var id: Date { date }
    }

    @ViewBuilder
    private func dayCell(for date: Date) -> some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        if date > today {
            // Not-yet-happened day within the current (incomplete) week —
            // blank rather than "empty," which is reserved for a past day
            // that genuinely had nothing logged.
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.clear)
                .frame(width: 20, height: 20)
        } else {
            let kind = StatsEngine.consistencyDayKind(on: date, sessions: sessions)
            Button {
                selectedDay = SelectedDay(date: date, label: detailLabel(for: date))
            } label: {
                RoundedRectangle(cornerRadius: 4)
                    .fill(color(for: kind))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 4. This week's wins

    private struct Win: Identifiable {
        let id = UUID()
        let text: String
    }

    private var thisWeeksWins: [Win] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        guard let weekAgo = cal.date(byAdding: .day, value: -6, to: today) else { return [] }
        func inWindow(_ date: Date) -> Bool {
            let day = cal.startOfDay(for: date)
            return day >= weekAgo && day <= today
        }

        var wins: [Win] = []

        for name in exerciseDefs.filter(\.isBigLift).map(\.name) {
            guard let result = StatsEngine.bigLiftResult(named: name, in: sessions) else { continue }
            if inWindow(result.heaviestDate) {
                wins.append(Win(text: "New \(name) Heaviest: \(Formatters.trim(result.heaviestWeight)) lb (\(Formatters.date.string(from: result.heaviestDate)))"))
            }
            if inWindow(result.estimatedOneRepMaxDate) {
                wins.append(Win(text: "New \(name) Est. 1RM: \(Formatters.trim(result.estimatedOneRepMax)) lb (\(Formatters.date.string(from: result.estimatedOneRepMaxDate)))"))
            }
        }

        for session in sessions where inWindow(session.date) {
            for log in session.exerciseLogs where log.restDayActivity == nil && log.goalKindRaw == 0 {
                guard let def = exerciseDefs.first(where: { $0.name == log.exerciseName }),
                      let ceiling = def.ceiling(for: log.targetReps),
                      ProgressionEngine.qualifiesForUpperTarget(log, upperTargetReps: ceiling.upperTargetReps) else { continue }
                wins.append(Win(text: "Hit Ceiling: \(log.exerciseName) (\(Formatters.date.string(from: session.date)))"))
            }
        }

        if let range = stats.maxStreakRange, range.followingBreakDate == nil,
           stats.maxStreak > 0, inWindow(range.end) {
            wins.append(Win(text: "New \(stats.maxStreak)-day streak record!"))
        }

        return wins
    }

    private var winsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This Week's Wins")
                .font(.title3.bold())
            if thisWeeksWins.isEmpty {
                Text("Nothing new this week — keep going")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(thisWeeksWins) { win in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "star.fill")
                                .foregroundStyle(.yellow)
                                .font(.caption)
                            Text(win.text)
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}
