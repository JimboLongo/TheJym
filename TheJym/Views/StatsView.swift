//
//  StatsView.swift
//  TheJym
//
//  Consistency stats (days logged, streaks, % logged, days/week) and
//  body-weight tracking with a chart.
//

import SwiftUI
import SwiftData
import Charts

struct StatsView: View {
    @Environment(\.modelContext) private var context
    @Query private var settingsList: [AppSettings]
    @Query(sort: \WorkoutSession.date) private var sessions: [WorkoutSession]
    @Query(sort: \BodyWeightEntry.date) private var weights: [BodyWeightEntry]
    @Query private var restActivities: [RestDayActivity]
    @Query(sort: \ActiveRecovery.date) private var activeRecoveries: [ActiveRecovery]
    @Query(sort: \TrainingDaysPerWeekChange.date) private var tdpwChanges: [TrainingDaysPerWeekChange]
    @Query private var phases: [Phase]

    @State private var newWeightText = ""
    @State private var newWeightDate = Date()

    private var settings: AppSettings? { settingsList.first }
    private var activePhase: Phase? { phases.first(where: \.isActive) }

    /// Real, exercise-bearing sessions only — excludes the no-activity
    /// backfilled Rest Day sessions, which shouldn't count as (or mask) a
    /// genuinely missed training day anywhere in stats.
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
                            trainingDaysPerWeekChanges: tdpwChanges.map { (date: $0.date, value: $0.trainingDaysPerWeek) },
                            defaultTrainingDaysPerWeek: settings?.trainingDaysPerWeek ?? 3)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Consistency") {
                    if let s = settings {
                        DatePicker("Training start date",
                                   selection: Binding(
                                       get: { s.trainingStartDate },
                                       set: { s.trainingStartDate = $0; try? context.save() }),
                                   displayedComponents: .date)
                    }
                    statRow("Days since start", "\(stats.daysSinceStart)")
                    statRow("Days logged", "\(stats.daysLogged)")
                    statRow("Current streak", "\(stats.currentStreak) 🔥")
                    statRow("Max streak", "\(stats.maxStreak)")
                    statRow("Rest days banked", String(format: "%.1f", stats.bankBalance))
                    statRow("% of days logged", String(format: "%.1f%%", stats.percentLogged * 100))
                    statRow("Days per week", String(format: "%.2f", stats.daysPerWeek))
                    if let delta = stats.cyclePaceDelta {
                        statRow("Cycle pace", delta == 0 ? "On pace" : "\(abs(delta)) \(delta > 0 ? "ahead" : "behind")")
                    }
                    if let adherence = stats.adherencePercent {
                        statRow("Adherence", String(format: "%.0f%%", adherence))
                    }
                }

                Section("Year / Month to Date") {
                    statRow("YTD workouts", "\(stats.ytdWorkoutDays) (PY: \(stats.priorYearYtdWorkoutDays))")
                    statRow("MTD workouts", "\(stats.mtdWorkoutDays) (PY: \(stats.priorYearMtdWorkoutDays))")
                }

                Section("Milestones") {
                    statRow("Perfect weeks", "\(stats.perfectWeeks)")
                    statRow("Perfect months", "\(stats.perfectMonths)")
                    if let label = stats.bestMonthLabel {
                        statRow("Best month all-time", "\(label) (\(stats.bestMonthWorkouts))")
                    } else {
                        statRow("Best month all-time", "—")
                    }
                }

                Section("Body Weight") {
                    DatePicker("Date", selection: $newWeightDate, in: ...Date(), displayedComponents: .date)
                    HStack {
                        TextField("Weight (lbs)", text: $newWeightText)
                            .keyboardType(.decimalPad)
                        Button("Log") {
                            if let w = Double(newWeightText) {
                                context.insert(BodyWeightEntry(date: newWeightDate, weight: w))
                                try? context.save()
                                newWeightText = ""
                                newWeightDate = Date()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(Double(newWeightText) == nil)
                    }
                    if weights.count >= 2 {
                        Chart(weights, id: \.persistentModelID) { entry in
                            LineMark(x: .value("Date", entry.date),
                                     y: .value("Weight", entry.weight))
                            PointMark(x: .value("Date", entry.date),
                                      y: .value("Weight", entry.weight))
                        }
                        .chartYScale(domain: .automatic(includesZero: false))
                        .frame(height: 180)
                        .padding(.vertical, 4)
                    }
                    ForEach(weights.reversed(), id: \.persistentModelID) { e in
                        LabeledContent(Formatters.date.string(from: e.date),
                                       value: "\(Formatters.trim(e.weight)) lbs")
                    }
                    .onDelete { idx in
                        let reversed = Array(weights.reversed())
                        for i in idx { context.delete(reversed[i]) }
                        try? context.save()
                    }
                }
            }
            .navigationTitle("Stats")
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value).font(.system(.body, design: .monospaced)).bold()
        }
    }
}
