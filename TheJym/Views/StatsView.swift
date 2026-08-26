//
//  StatsView.swift
//  TheJym
//
//  Consistency stats (days logged, streaks, % logged, days/week). Body
//  weight tracking lives in its own BodyWeightView.
//

import SwiftUI
import SwiftData

struct StatsView: View {
    @Binding var overflowTab: OverflowTab?

    @Environment(\.modelContext) private var context
    @Query private var settingsList: [AppSettings]
    @Query(sort: \WorkoutSession.date) private var sessions: [WorkoutSession]
    @Query private var restActivities: [RestDayActivity]
    @Query(sort: \ActiveRecovery.date) private var activeRecoveries: [ActiveRecovery]
    @Query(sort: \TrainingDaysPerWeekChange.date) private var tdpwChanges: [TrainingDaysPerWeekChange]
    @Query private var phases: [Phase]

    // @Query already keeps every stat live against real data changes (e.g.
    // edits made in History) — this just forces stats to also recompute
    // against the current wall-clock time on a manual pull, since "today"
    // (see StatsEngine.compute's loggedToday handling) can otherwise go
    // stale if the view sits open across a day rollover with no new data.
    @State private var refreshTick = false
    /// Presented as a sheet (instead of the default inline compact picker)
    /// so selecting a date can close it automatically — a bare DatePicker's
    /// own popover has no way to dismiss itself on selection.
    @State private var showTrainingStartDatePicker = false
    @State private var pendingTrainingStartDate = Date()

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
                            restActivities: restActivities,
                            trainingDaysPerWeekChanges: tdpwChanges.map { (date: $0.date, value: $0.trainingDaysPerWeek) },
                            defaultTrainingDaysPerWeek: settings?.trainingDaysPerWeek ?? 3)
    }

    private func milesLabel(_ miles: Double) -> String {
        "\(Formatters.trim(miles)) mi"
    }

    var body: some View {
        NavigationStack {
            List {
                // Purely Training-Start-Date-based — no phase concepts here.
                // Anything specific to whatever Phase is currently active
                // lives in its own section below instead.
                Section("Consistency") {
                    if let s = settings {
                        Button {
                            pendingTrainingStartDate = s.trainingStartDate
                            showTrainingStartDatePicker = true
                        } label: {
                            LabeledContent("Training start date") {
                                Text(Formatters.date.string(from: s.trainingStartDate))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    statRow("Days since start", "\(stats.daysSinceStart)")
                    statRow("Days logged", "\(stats.daysLogged)")
                    VStack(alignment: .leading, spacing: 2) {
                        statRow("Current streak", "\(stats.currentStreak) 🔥")
                        if let start = stats.currentStreakStartDate {
                            Text("Since \(Formatters.date.string(from: start))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        statRow("Max streak", "\(stats.maxStreak)")
                        if let range = stats.maxStreakRange {
                            Text("\(Formatters.date.string(from: range.start)) – \(Formatters.date.string(from: range.end))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    statRow("Rest days banked", String(format: "%.1f", stats.bankBalance))
                    statRow("% of days logged", String(format: "%.1f%%", stats.percentLogged * 100))
                    statRow("Days per week", String(format: "%.2f", stats.daysPerWeek))
                    statRow("Miles walked", milesLabel(stats.milesSinceStart))
                }

                if let activePhase {
                    Section("Current Phase — Phase \(activePhase.number)") {
                        if let delta = stats.cyclePaceDelta {
                            statRow("Cycle pace", delta == 0 ? "On pace" : "\(abs(delta)) \(delta > 0 ? "ahead" : "behind")")
                        }
                        if let adherence = stats.adherencePercent {
                            statRow("Adherence", String(format: "%.0f%%", adherence))
                        }
                        if let progress = stats.activePhaseCycleProgress {
                            statRow("Phase \(progress.number)",
                                    progress.completedCount == 0
                                        ? "No completed cycles yet"
                                        : "\(progress.perfectCount) of \(progress.completedCount) perfect")
                        }
                        statRow("Lifetime perfect cycles", "\(stats.perfectCycleLifetimeCount ?? 0)")
                        statRow("Current perfect-cycle streak", "\(stats.perfectCycleCurrentStreak ?? 0)")
                        if let miles = stats.milesThisPhase {
                            statRow("Miles walked", milesLabel(miles))
                        }
                    }
                } else if let fallback = stats.perfectWeekFallback {
                    // No active phase to judge cycles against — a simpler,
                    // phase-independent progress stat instead.
                    Section("Progress") {
                        statRow("Lifetime perfect weeks", "\(fallback.lifetimeCount)")
                        statRow("Current perfect-week streak", "\(fallback.currentStreak)")
                    }
                }

                Section("Year / Month to Date") {
                    statRow("YTD workouts", "\(stats.ytdWorkoutDays) (PY: \(stats.priorYearYtdWorkoutDays))")
                    statRow("MTD workouts", "\(stats.mtdWorkoutDays) (PY: \(stats.priorYearMtdWorkoutDays))")
                    statRow("YTD miles", "\(milesLabel(stats.ytdMiles)) (PY: \(milesLabel(stats.priorYearYtdMiles)))")
                    statRow("MTD miles", "\(milesLabel(stats.mtdMiles)) (PY: \(milesLabel(stats.priorYearMtdMiles)))")
                }

                Section("Milestones") {
                    statRow("Perfect weeks", "\(stats.perfectWeeks)")
                    statRow("Perfect months", "\(stats.perfectMonths)")
                    statRow("All-time miles", milesLabel(stats.allTimeMiles))
                    if let label = stats.bestMonthLabel {
                        statRow("Best month all-time", "\(label) (\(stats.bestMonthWorkouts))")
                    } else {
                        statRow("Best month all-time", "—")
                    }
                }
            }
            .id(refreshTick)
            .refreshable {
                refreshTick.toggle()
            }
            .navigationTitle("Stats")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    OverflowMenuButton(overflowTab: $overflowTab)
                }
            }
            .sheet(isPresented: $showTrainingStartDatePicker) {
                NavigationStack {
                    DatePicker("Training start date", selection: $pendingTrainingStartDate,
                              displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .padding()
                        .navigationTitle("Training Start Date")
                        .navigationBarTitleDisplayMode(.inline)
                }
                .presentationDetents([.medium])
                .onChange(of: pendingTrainingStartDate) { _, newValue in
                    settings?.trainingStartDate = newValue
                    try? context.save()
                    showTrainingStartDatePicker = false
                }
            }
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value).font(.system(.body, design: .monospaced)).bold()
        }
    }
}
