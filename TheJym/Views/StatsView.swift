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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Query private var settingsList: [AppSettings]
    @Query(sort: \WorkoutSession.date) private var sessions: [WorkoutSession]
    @Query private var restActivities: [RestDayActivity]
    @Query(sort: \ActiveRecovery.date) private var activeRecoveries: [ActiveRecovery]
    @Query(sort: \TrainingDaysPerWeekChange.date) private var tdpwChanges: [TrainingDaysPerWeekChange]
    @Query private var phases: [Phase]
    @Query(sort: \ExerciseDef.name) private var exerciseDefs: [ExerciseDef]

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
    /// Per-phase override of a completed phase's DisclosureGroup expansion,
    /// only populated once the user actually taps one — until then, the
    /// most recently completed phase defaults open and every other one
    /// defaults closed (see completedPhaseSection's isMostRecent).
    @State private var expandedPhaseOverrides: [Int: Bool] = [:]

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
                            defaultTrainingDaysPerWeek: settings?.trainingDaysPerWeek ?? 3,
                            allSessions: sessions,
                            bigLiftNames: exerciseDefs.filter(\.isBigLift).map(\.name))
    }

    private func milesLabel(_ miles: Double) -> String {
        "\(Formatters.trim(miles)) mi"
    }

    var body: some View {
        NavigationStack {
            List {
                consistencySection
                if let activePhase {
                    currentPhaseSection(activePhase)
                } else if let fallback = stats.perfectWeekFallback {
                    // No active phase to judge cycles against — a simpler,
                    // phase-independent progress stat instead.
                    progressFallbackSection(fallback)
                }
                yearMonthSection
                milestonesSection
                if !stats.bigLiftGroups.isEmpty {
                    bigLiftsSection
                }
                ForEach(Array(stats.completedPhaseSummaries.enumerated()), id: \.element.id) { index, summary in
                    completedPhaseSection(summary, isMostRecent: index == 0)
                }
            }
            .listSectionSpacing(.compact)
            .environment(\.defaultMinListRowHeight, 28)
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

    // MARK: - Sections

    // Purely Training-Start-Date-based — no phase concepts here. Anything
    // specific to whatever Phase is currently active lives in its own
    // section below instead.
    private var consistencySection: some View {
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
                // Lowering defaultMinListRowHeight below shrinks every row
                // that doesn't ask for more — this one's the only tappable
                // row in the whole page, so it keeps a real touch target.
                .frame(minHeight: 44)
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
            statGrid([
                ("Rest days banked", String(format: "%.1f", stats.bankBalance)),
                ("% of days logged", String(format: "%.1f%%", stats.percentLogged * 100)),
                // Since-start window — deliberately kept alongside
                // Milestones' All-time miles rather than merged into it:
                // Training Start Date can (and here does) postdate a lot of
                // imported history, so the two numbers genuinely diverge
                // rather than being the same figure twice.
                ("Miles walked", milesLabel(stats.milesSinceStart)),
                ("Days per week", String(format: "%.2f", stats.daysPerWeek)),
            ])
        }
    }

    private func currentPhaseSection(_ activePhase: Phase) -> some View {
        var pairs: [(String, String)] = []
        if let delta = stats.cyclePaceDelta {
            pairs.append(("Cycle pace", delta == 0 ? "On pace" : "\(abs(delta)) \(delta > 0 ? "ahead" : "behind")"))
        }
        if let adherence = stats.adherencePercent {
            pairs.append(("Adherence", String(format: "%.0f%%", adherence)))
        }
        if let progress = stats.activePhaseCycleProgress {
            pairs.append(("Phase \(progress.number)",
                          progress.completedCount == 0
                              ? "No completed cycles yet"
                              : "\(progress.perfectCount) of \(progress.completedCount) perfect"))
        }
        pairs.append(("Lifetime perfect cycles", "\(stats.perfectCycleLifetimeCount ?? 0)"))
        pairs.append(("Current perfect-cycle streak", "\(stats.perfectCycleCurrentStreak ?? 0)"))
        if let miles = stats.milesThisPhase {
            pairs.append(("Miles walked", milesLabel(miles)))
        }
        return Section("Current Phase — Phase \(activePhase.number)") {
            statGrid(pairs)
        }
    }

    private func progressFallbackSection(_ fallback: PerfectWeekFallback) -> some View {
        Section("Progress") {
            statGrid([
                ("Lifetime perfect weeks", "\(fallback.lifetimeCount)"),
                ("Current perfect-week streak", "\(fallback.currentStreak)"),
            ])
        }
    }

    /// Same two metrics (workouts, miles) x two periods (YTD, MTD) as a
    /// small table instead of four separate rows, PY comparison as a
    /// caption under each figure. At an accessibility Dynamic Type size the
    /// 3-column grid (row label + 2 data columns) doesn't have room to
    /// stay readable, so it falls back to the original one-stat-per-row
    /// layout instead of letting values truncate.
    @ViewBuilder
    private var yearMonthSection: some View {
        Section("Year / Month to Date") {
            if dynamicTypeSize.isAccessibilitySize {
                statRow("YTD workouts", "\(stats.ytdWorkoutDays) (PY: \(stats.priorYearYtdWorkoutDays))")
                statRow("MTD workouts", "\(stats.mtdWorkoutDays) (PY: \(stats.priorYearMtdWorkoutDays))")
                statRow("YTD miles", "\(milesLabel(stats.ytdMiles)) (PY: \(milesLabel(stats.priorYearYtdMiles)))")
                statRow("MTD miles", "\(milesLabel(stats.mtdMiles)) (PY: \(milesLabel(stats.priorYearMtdMiles)))")
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("")
                        Text("YTD").font(.caption2.bold()).foregroundStyle(.secondary)
                        Text("MTD").font(.caption2.bold()).foregroundStyle(.secondary)
                    }
                    GridRow {
                        Text("Workouts").font(.caption).foregroundStyle(.secondary)
                        yearMonthCell("\(stats.ytdWorkoutDays)", py: "\(stats.priorYearYtdWorkoutDays)")
                        yearMonthCell("\(stats.mtdWorkoutDays)", py: "\(stats.priorYearMtdWorkoutDays)")
                    }
                    GridRow {
                        Text("Miles").font(.caption).foregroundStyle(.secondary)
                        yearMonthCell(milesLabel(stats.ytdMiles), py: milesLabel(stats.priorYearYtdMiles))
                        yearMonthCell(milesLabel(stats.mtdMiles), py: milesLabel(stats.priorYearMtdMiles))
                    }
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            }
        }
    }

    private func yearMonthCell(_ value: String, py: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(.subheadline, design: .monospaced)).bold()
            Text("PY: \(py)").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var milestonesSection: some View {
        Section("Milestones") {
            statGrid([
                ("Perfect weeks", "\(stats.perfectWeeks)"),
                ("Perfect months", "\(stats.perfectMonths)"),
                // All-time, unbounded window — see consistencySection's own
                // note on why this is kept separate from "Miles walked"
                // (since-start) rather than merged into it.
                ("All-time miles", milesLabel(stats.allTimeMiles)),
                ("Best month all-time", stats.bestMonthLabel.map { "\($0) (\(stats.bestMonthWorkouts))" } ?? "—"),
            ])
        }
    }

    /// One group per flagged exercise, each its own All-Time row plus one
    /// row per phase (including the active one) that has a qualifying set —
    /// see StatsEngine.compute's own note on exactly how a group's rows are
    /// built. A single section for every flagged exercise, rather than a
    /// table scattered across each phase's own section, so phase-over-phase
    /// progress on the same lift reads top-to-bottom in one place.
    private var bigLiftsSection: some View {
        Section("Big Lifts") {
            ForEach(stats.bigLiftGroups) { group in
                BigLiftGroupTable(group: group)
            }
        }
    }

    /// Collapsed by default, except the most recently completed phase
    /// (first in stats.completedPhaseSummaries' newest-first order) —
    /// that's the one still worth glancing at right after finishing;
    /// everything older is reference material. The header (phase number +
    /// date range) stays visible either way, so identifying a phase
    /// doesn't require expanding it.
    private func completedPhaseSection(_ summary: PhaseSummary, isMostRecent: Bool) -> some View {
        Section {
            DisclosureGroup(isExpanded: expandedBinding(for: summary.number, defaultExpanded: isMostRecent)) {
                let delta = summary.cyclePaceDelta
                statGrid([
                    ("Final cycle pace", delta == 0 ? "On pace" : "\(abs(delta)) \(delta > 0 ? "ahead" : "behind")"),
                    ("Adherence", String(format: "%.0f%%", summary.adherencePercent)),
                    ("Perfect cycles", "\(summary.perfectCount) of \(summary.completedCount) perfect"),
                    ("Miles walked", milesLabel(summary.milesWalked)),
                ])
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Phase \(summary.number)").font(.headline)
                    Text("\(Formatters.date.string(from: summary.startDate)) – \(Formatters.date.string(from: summary.endDate))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func expandedBinding(for phaseNumber: Int, defaultExpanded: Bool) -> Binding<Bool> {
        Binding(
            get: { expandedPhaseOverrides[phaseNumber] ?? defaultExpanded },
            set: { expandedPhaseOverrides[phaseNumber] = $0 }
        )
    }

    // MARK: - Row helpers

    private func statRow(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value).font(.system(.subheadline, design: .monospaced)).bold()
        }
    }

    /// Two per row normally, one per row at an accessibility Dynamic Type
    /// size so a wide value never truncates against a cramped column —
    /// shared by statGrid and bigLiftGrid so they can't drift apart.
    private var statGridColumns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]
    }

    /// Short label/value pairs, two per row (one per row at an
    /// accessibility Dynamic Type size, so a wide value never truncates
    /// against a cramped column). One List row per call — trimmed insets
    /// and the page's own lowered defaultMinListRowHeight are what
    /// actually make this more compact than a stack of statRows; neither
    /// helps unless the grid's own row doesn't ask for touch-target height.
    @ViewBuilder
    private func statGrid(_ pairs: [(String, String)]) -> some View {
        LazyVGrid(columns: statGridColumns, alignment: .leading, spacing: 10) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                VStack(alignment: .leading, spacing: 1) {
                    Text(pair.0)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(pair.1)
                        .font(.system(.subheadline, design: .monospaced))
                        .bold()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    }
}

/// The Big Lifts table inside one completed phase's summary: Exercise x
/// Heaviest x Est. 1RM, one row per flagged lift plus a header row — same
/// Grid/GridRow structure and accessibility fallback as yearMonthSection's
/// YTD/MTD table (see its own doc for why: a 3-column table has no room to
/// stay readable at an accessibility Dynamic Type size, so it falls back to
/// one label/value row per scope per metric instead of letting values
/// truncate) — Scope x Heaviest x Est. 1RM instead of Exercise x Heaviest x
/// Est. 1RM, with the exercise name promoted to a header above the table
/// instead of a row's own first column, since one group is already scoped
/// to a single exercise. Its own `struct` (not a private StatsView method)
/// so a test can render it directly with synthetic data.
struct BigLiftGroupTable: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let group: BigLiftGroup

    /// "170 x 5" in bold monospaced, plus the date that set was logged in a
    /// smaller secondary weight, e.g. "170 x 5 (1/5/26)" — Formatters.shortDate
    /// is the same compact numeric format History already uses in its own
    /// tight date column, chosen here so the parenthetical doesn't force a
    /// wrap at normal Dynamic Type sizes.
    private func heaviestValue(_ result: BigLiftResult) -> Text {
        Text("\(Formatters.trim(result.heaviestWeight)) x \(result.heaviestReps) ")
            .font(.system(.subheadline, design: .monospaced)).bold()
        + Text("(\(Formatters.shortDate.string(from: result.heaviestDate)))")
            .font(.caption2).foregroundStyle(.secondary)
    }

    /// Est. 1RM rounded to the nearest 2.5 — the smallest common plate
    /// pair — for DISPLAY ONLY, so it reads as a weight that could
    /// actually be loaded on a bar. BigLiftResult.estimatedOneRepMax
    /// itself stays exact: WorkoutLogView's oneRepMaxOverTime chart shares
    /// PaceEngine.epley1RM and needs the precise value for its own
    /// session-to-session record detection — quantizing the stored number
    /// would let two genuinely different sessions round to the same value
    /// and stop registering as a new record. Dated the same way as
    /// heaviestValue — often a different date, since the two numbers aren't
    /// necessarily won by the same set.
    private func estimateValue(_ result: BigLiftResult) -> Text {
        Text("\(Formatters.trim((result.estimatedOneRepMax / 2.5).rounded() * 2.5)) ")
            .font(.system(.subheadline, design: .monospaced)).bold()
        + Text("(\(Formatters.shortDate.string(from: result.estimatedOneRepMaxDate)))")
            .font(.caption2).foregroundStyle(.secondary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(group.exerciseName).font(.subheadline.bold())
            if dynamicTypeSize.isAccessibilitySize {
                ForEach(group.rows) { row in
                    if let result = row.result {
                        LabeledContent("\(row.scopeLabel) — Heaviest") {
                            heaviestValue(result)
                        }
                        LabeledContent("\(row.scopeLabel) — Est. 1RM") {
                            estimateValue(result)
                        }
                    } else {
                        // One combined row, not split Heaviest/Est. 1RM —
                        // there's nothing set-specific to say twice.
                        LabeledContent(row.scopeLabel) {
                            Text("No Data").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("Scope").font(.caption2.bold()).foregroundStyle(.secondary)
                        Text("Heaviest").font(.caption2.bold()).foregroundStyle(.secondary)
                            .gridColumnAlignment(.center)
                        Text("Est. 1RM").font(.caption2.bold()).foregroundStyle(.secondary)
                            .gridColumnAlignment(.center)
                    }
                    ForEach(group.rows) { row in
                        GridRow {
                            Text(row.scopeLabel).font(.caption).foregroundStyle(.secondary)
                            if let result = row.result {
                                // fixedSize keeps the number+date on one
                                // line by refusing to compress — the Scope
                                // column is short ("All-Time"/"Phase N"),
                                // but this still guards against it wrapping
                                // the date under the number if a row's
                                // Scope text were ever wider.
                                heaviestValue(result)
                                    .fixedSize()
                                    .gridColumnAlignment(.center)
                                estimateValue(result)
                                    .fixedSize()
                                    .gridColumnAlignment(.center)
                            } else {
                                // Spans both value columns — a single gap
                                // reads better than two separate "No Data"
                                // cells, and it's the point of the row:
                                // showing where this lift wasn't trained.
                                Text("No Data")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .gridCellColumns(2)
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    }
}
