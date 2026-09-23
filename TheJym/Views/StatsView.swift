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
    /// Which of the Workout Duration section's two pages is showing —
    /// drives its dots. Optional because .scrollPosition(id:) is.
    @State private var dayDurationPage: DayDurationPage? = .standard

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

    /// By Year's own miles format: one decimal, no unit — that table's row
    /// is already labelled "Miles", and a fixed decimal keeps the column
    /// aligned. Deliberately separate from `milesLabel` above, which still
    /// carries "mi" everywhere else on the page.
    private func yearlyMilesLabel(_ miles: Double) -> String {
        String(format: "%.1f", miles)
    }

    /// A current-streak row's "Since <date>" subtitle, shared by both
    /// current-streak rows so they can't drift apart in format. Callers
    /// unwrap the optional start date first — a nil one means the streak
    /// is 0 and the row shows no subtitle at all.
    private func streakSinceLabel(_ start: Date) -> String {
        "Since \(Formatters.date.string(from: start))"
    }

    /// A max-streak row's date-range subtitle, shared by both streak rows
    /// so they can't drift apart in format.
    ///
    /// An ongoing streak reads "Sep 8 – Present" rather than repeating
    /// today's date, which would go stale-looking the moment you read it
    /// tomorrow and reads as a finished span rather than a live one.
    /// MaxStreakDateRange.followingBreakDate being nil is what says the
    /// streak is still open (see its own doc), so there's no extra flag.
    ///
    /// A finished single-day streak collapses to one date — "Sep 8", not
    /// "Sep 8 – Sep 8", which reads like a rendering bug. A one-day streak
    /// that's still running keeps the range form ("Sep 18 – Present"),
    /// since there the second half is saying something the first doesn't.
    private func streakRangeLabel(_ range: MaxStreakDateRange) -> String {
        let start = Formatters.date.string(from: range.start)
        guard range.followingBreakDate != nil else { return "\(start) – Present" }
        let end = Formatters.date.string(from: range.end)
        return start == end ? start : "\(start) – \(end)"
    }

    private func hoursLabel(_ hours: Double) -> String {
        String(format: "%.1f hr", hours)
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
                if !stats.yearlyTotals.isEmpty {
                    yearlyTotalsSection
                }
                milestonesSection
                if !stats.bigLiftGroups.isEmpty {
                    bigLiftsSection
                }
                // Either page having content is enough — a phase that only
                // ever ran deloads with the stopwatch on would otherwise
                // hide the section that has its numbers.
                if !stats.dayDurationGroups.isEmpty || !stats.deloadDayDurationGroups.isEmpty {
                    dayDurationSection
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
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        ClaudeStatsView()
                    } label: {
                        Image(systemName: "sparkles")
                    }
                    .accessibilityLabel("Claude Stats")
                }
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
            // Kept out of the table below on purpose: it's the same number
            // in every column, and it's the figure the Rest column is
            // derived against (Rest = Days since start - Active).
            statRow("Days since start", "\(stats.daysSinceStart)")
            // The rest-BANK streak, which spends banked rest days to carry
            // a streak through a day off — a different measure from the
            // table's plain consecutive-days streak, not the same number
            // shown twice. Labelled "(banked)" so the two can't be read as
            // contradicting each other, since the table below has rows
            // called Current streak and Max streak as well.
            //
            // Days logged and the plain active streaks used to sit here as
            // standalone rows; the table's Active column is now exactly
            // those, so they'd have been the same figures twice.
            VStack(alignment: .leading, spacing: 2) {
                statRow("Current streak (banked)", "\(stats.currentStreak) 🔥")
                if let start = stats.currentStreakStartDate {
                    Text(streakSinceLabel(start))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                statRow("Max streak (banked)", "\(stats.maxStreak)")
                if let range = stats.maxStreakRange {
                    Text(streakRangeLabel(range))
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
            ])
            consistencyTable
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
                              : "\(progress.perfectCount) of \(progress.completedCount)"))
        }
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

    /// One column per calendar year with anything in it, newest first.
    /// "Active days" counts distinct DAYS on which anything was logged —
    /// training or a rest-day activity, with both on the same date
    /// counting once. Same basis as "All-time active days" in Milestones
    /// below, so these columns sum to it. See StatsEngine.compute's own
    /// note for which sessions qualify.
    private var yearlyTotalsSection: some View {
        Section {
            YearlyTotalsTable(rows: stats.yearlyTotals,
                              projection: stats.currentYearProjection,
                              milesLabel: yearlyMilesLabel)
        } header: {
            Text("By Year")
        } footer: {
            Text(stats.currentYearProjection == nil
                 ? "An active day is any day you trained or logged a rest-day activity; both on one day still counts once. The current year is to date."
                 : "An active day is any day you trained or logged a rest-day activity; both on one day still counts once. The current year is to date; Proj. adds your last 3 months' pace across the days remaining.")
        }
    }

    /// The Consistency table: four statistics × four kinds of day —
    /// Active, Lift, Walk, Rest. Same Grid/GridRow structure and
    /// accessibility fallback as yearMonthSection above (and the Big Lifts
    /// / Workout Duration / By Year tables) — a label column plus value
    /// columns at standard sizes, falling back to one labelled row per
    /// value where a 5-column grid has no room to stay readable.
    ///
    /// Two identities run across the columns, and they're why the table
    /// exists at all: Lift + Walk == Active, and Active + Rest == Days
    /// since start. So Walk is strictly walk-ONLY days (a day with both a
    /// lift and a walk counts in Lift), and Rest is every day with nothing
    /// logged. See ConsistencyColumn.
    ///
    /// Days since start is deliberately NOT a row here — it's the same
    /// number in all four columns, and it stays the standalone row above
    /// that the Rest column is derived against.
    @ViewBuilder
    private var consistencyTable: some View {
        if dynamicTypeSize.isAccessibilitySize {
            // A 5-column grid has nowhere near the room at AX sizes, so it
            // unrolls into one labelled row per cell — 16 of them, grouped
            // by row rather than by column so each statistic's four
            // columns stay adjacent and comparable while scrolling.
            ForEach(consistencyRows, id: \.label) { row in
                ForEach(consistencyColumns, id: \.header) { col in
                    statRow("\(row.label) — \(col.header)", row.value(col.column))
                }
            }
        } else {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    Text("")
                    ForEach(consistencyColumns, id: \.header) { col in
                        Text(col.header).font(.caption2.bold()).foregroundStyle(.secondary)
                            .gridColumnAlignment(.center)
                    }
                }
                ForEach(consistencyRows, id: \.label) { row in
                    GridRow {
                        Text(row.label).font(.caption).foregroundStyle(.secondary)
                            .gridColumnAlignment(.leading)
                        ForEach(consistencyColumns, id: \.header) { col in
                            Text(row.value(col.column))
                                .font(.system(.subheadline, design: .monospaced)).bold()
                                .fixedSize()
                                .gridColumnAlignment(.center)
                        }
                    }
                }
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        }
    }

    /// Column order is the partition's order: the whole, then its parts.
    private var consistencyColumns: [(header: String, column: ConsistencyColumn)] {
        [("Active", stats.consistencyActive),
         ("Lift", stats.consistencyLift),
         ("Walk", stats.consistencyWalk),
         ("Rest", stats.consistencyRest)]
    }

    /// Rows are (label, how to read one column) so the grid and the
    /// accessibility unroll render from one list and can't drift.
    private var consistencyRows: [(label: String, value: (ConsistencyColumn) -> String)] {
        [("Days per week", { String(format: "%.2f", $0.daysPerWeek) }),
         ("Days logged", { "\($0.daysLogged)" }),
         ("Current streak", { "\($0.currentStreak)" }),
         ("Max streak", { "\($0.maxStreak)" })]
    }

    private func yearMonthCell(_ value: String, py: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(.subheadline, design: .monospaced)).bold()
            Text("PY: \(py)").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var milestonesSection: some View {
        Section {
            statGrid([
                ("Perfect weeks", "\(stats.perfectWeeks)"),
                ("Perfect months", "\(stats.perfectMonths)"),
                // All-time, unbounded window — see consistencySection's own
                // note on why this is kept separate from "Miles walked"
                // (since-start) rather than merged into it.
                ("All-time miles", milesLabel(stats.allTimeMiles)),
                ("Best month all-time", stats.bestMonthLabel.map { "\($0) (\(stats.bestMonthWorkouts))" } ?? "—"),
                ("All-time active days", "\(stats.allTimeActiveDayCount)"),
                ("All-time hours trained", hoursLabel(stats.allTimeHoursTrained)),
            ])
        } header: {
            Text("Milestones")
        } footer: {
            // Same "omit rather than show a false number" rule as
            // everywhere else — a session logged before duration tracking
            // existed has no recorded duration and is excluded from this
            // sum, not counted as 0, so the total understates true
            // lifetime training time until enough history accumulates.
            Text("Hours trained only counts sessions logged after duration tracking began.")
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

    /// One group per workout day template, each its own All-Time row plus
    /// one row per phase (including the active one) that has a session with
    /// a recorded duration — see StatsEngine.compute's own note on exactly
    /// how a group's rows are built. Same single-section-per-flagged-thing
    /// shape as bigLiftsSection, grouped by day name instead of exercise
    /// name.
    /// Two horizontally-paged views of the same table: normal sessions,
    /// then deload sessions only. A horizontally-paging ScrollView rather
    /// than a TabView(.page) on purpose — a TabView needs an explicit
    /// height, and this content's height varies with the number of day
    /// templates, the number of phases each has history in, AND Dynamic
    /// Type size (the accessibility fallback is several times taller,
    /// being one labelled row per scope per metric). A horizontal
    /// ScrollView hugs its content's intrinsic height instead, so nothing
    /// clips at AX5. Both pages share the taller one's height, so swiping
    /// doesn't make the section jump.
    private var dayDurationSection: some View {
        Section {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    dayDurationPage(
                        groups: stats.dayDurationGroups,
                        title: "Standard",
                        emptyMessage: "No non-deload sessions with a recorded duration yet.")
                        .containerRelativeFrame(.horizontal)
                        .id(DayDurationPage.standard)
                    dayDurationPage(
                        groups: stats.deloadDayDurationGroups,
                        title: "Deload",
                        emptyMessage: "No deload sessions with a recorded duration yet.")
                        .containerRelativeFrame(.horizontal)
                        .id(DayDurationPage.deload)
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
            .scrollPosition(id: $dayDurationPage)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 0, trailing: 16))
            dayDurationPageDots
        } header: {
            Text("Workout Duration")
        } footer: {
            Text("Swipe for deload times.")
        }
    }

    private enum DayDurationPage: Hashable, CaseIterable {
        case standard, deload
    }

    /// One page of the Workout Duration section. Carries its own title so
    /// the page is self-describing even mid-swipe, rather than relying on
    /// the dots alone to say which half you're looking at.
    @ViewBuilder
    private func dayDurationPage(groups: [DayDurationGroup], title: String,
                                 emptyMessage: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            if groups.isEmpty {
                Text(emptyMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(groups) { group in
                    DayDurationGroupTable(group: group)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dayDurationPageDots: some View {
        HStack(spacing: 6) {
            ForEach(DayDurationPage.allCases, id: \.self) { page in
                Circle()
                    .fill(Color.secondary.opacity((dayDurationPage ?? .standard) == page ? 0.8 : 0.25))
                    .frame(width: 6, height: 6)
            }
        }
        .frame(maxWidth: .infinity)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 6, trailing: 16))
        .accessibilityHidden(true)
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
                    ("Perfect cycles", "\(summary.perfectCount) of \(summary.completedCount)"),
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

    /// "170" in bold monospaced (weight only, no reps — see BigLiftResult's
    /// own doc), plus the date that set was logged in a smaller secondary
    /// weight, e.g. "170 (1/5/26)" — Formatters.shortDate is the same
    /// compact numeric format History already uses in its own tight date
    /// column, chosen here so the parenthetical doesn't force a wrap at
    /// normal Dynamic Type sizes.
    private func heaviestValue(_ result: BigLiftResult) -> Text {
        Text("\(Formatters.trim(result.heaviestWeight)) ")
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
                        LabeledContent("\(row.scopeLabel) — Heaviest") {
                            Text("No Data").font(.subheadline).foregroundStyle(.secondary)
                        }
                        LabeledContent("\(row.scopeLabel) — Est. 1RM") {
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
                                // Repeated under each value column rather
                                // than spanning both — matches the shape of
                                // a data row (one value per column) instead
                                // of reading as one merged cell.
                                Text("No Data")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .gridColumnAlignment(.center)
                                Text("No Data")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .gridColumnAlignment(.center)
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

/// The Workout Duration table inside the Stats page's "Workout Duration"
/// section: Scope x Shortest x Average x Longest, one row per scope plus a
/// header row — same Grid/GridRow structure and accessibility fallback as
/// BigLiftGroupTable (see its own doc for why a 3-value-column table falls
/// back to one label/value row per scope per metric at an accessibility
/// Dynamic Type size), with a third value column since there's no date to
/// pair with each number here — just a plain duration. Its own `struct`
/// (not a private StatsView method) so a test can render it directly with
/// synthetic data.
struct DayDurationGroupTable: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let group: DayDurationGroup

    private func durationText(_ seconds: Double) -> Text {
        Text(Formatters.durationRoundedToMinute(seconds))
            .font(.system(.subheadline, design: .monospaced)).bold()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(group.dayName).font(.subheadline.bold())
            if dynamicTypeSize.isAccessibilitySize {
                ForEach(group.rows) { row in
                    if let result = row.result {
                        LabeledContent("\(row.scopeLabel) — Shortest") {
                            durationText(Double(result.shortestSeconds))
                        }
                        LabeledContent("\(row.scopeLabel) — Average") {
                            durationText(result.averageSeconds)
                        }
                        LabeledContent("\(row.scopeLabel) — Longest") {
                            durationText(Double(result.longestSeconds))
                        }
                    } else {
                        LabeledContent("\(row.scopeLabel) — Shortest") {
                            Text("No Data").font(.subheadline).foregroundStyle(.secondary)
                        }
                        LabeledContent("\(row.scopeLabel) — Average") {
                            Text("No Data").font(.subheadline).foregroundStyle(.secondary)
                        }
                        LabeledContent("\(row.scopeLabel) — Longest") {
                            Text("No Data").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("Scope").font(.caption2.bold()).foregroundStyle(.secondary)
                        Text("Shortest").font(.caption2.bold()).foregroundStyle(.secondary)
                            .gridColumnAlignment(.center)
                        Text("Average").font(.caption2.bold()).foregroundStyle(.secondary)
                            .gridColumnAlignment(.center)
                        Text("Longest").font(.caption2.bold()).foregroundStyle(.secondary)
                            .gridColumnAlignment(.center)
                    }
                    ForEach(group.rows) { row in
                        GridRow {
                            Text(row.scopeLabel).font(.caption).foregroundStyle(.secondary)
                            if let result = row.result {
                                durationText(Double(result.shortestSeconds))
                                    .fixedSize()
                                    .gridColumnAlignment(.center)
                                durationText(result.averageSeconds)
                                    .fixedSize()
                                    .gridColumnAlignment(.center)
                                durationText(Double(result.longestSeconds))
                                    .fixedSize()
                                    .gridColumnAlignment(.center)
                            } else {
                                // Repeated under each value column rather
                                // than spanning all three — matches the
                                // shape of a data row (one value per column)
                                // instead of reading as one merged cell.
                                Text("No Data")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .gridColumnAlignment(.center)
                                Text("No Data")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .gridColumnAlignment(.center)
                                Text("No Data")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .gridColumnAlignment(.center)
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

/// The per-year table inside the Stats page's "By Year" section. Metrics
/// run down the side (Workouts, Miles) and years run across the top,
/// newest first, with the current year's full-year projection sitting
/// immediately to the right of that year's own actuals so the two read as
/// a pair. Same Grid/GridRow structure and accessibility fallback as
/// BigLiftGroupTable/DayDurationGroupTable (see BigLiftGroupTable's own
/// doc for why a multi-value-column table falls back to one label/value
/// row per value at an accessibility Dynamic Type size). Its own `struct`
/// (not a private StatsView method) so a test can render it directly with
/// synthetic data.
///
/// Only the projection column is annotated. The actual-year columns are
/// left plain — newest-first ordering already makes the in-progress year
/// evident, and the projection beside it is what actually needs calling
/// out, since it's the one column that isn't a measured number.
struct YearlyTotalsTable: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let rows: [YearTotal]
    /// Rendered as an extra column right after whichever year it projects.
    /// nil when there isn't enough of the year on record yet — see
    /// StatsEngine.compute's own note.
    let projection: YearTotal?
    /// Same formatting every other miles figure on the page uses — passed
    /// in rather than re-derived here so this table can't drift from them.
    let milesLabel: (Double) -> String

    private struct Column: Identifiable {
        let id: String
        let header: String
        let activeDayCount: Int
        let miles: Double
    }

    private var columns: [Column] {
        rows.flatMap { row -> [Column] in
            // String(_:), not "\(row.year)" — the latter renders a
            // locale-grouped "2,026".
            let yearText = String(row.year)
            var out = [Column(id: yearText, header: yearText,
                              activeDayCount: row.activeDayCount, miles: row.milesWalked)]
            if let projection, projection.year == row.year {
                out.append(Column(id: "\(yearText)-proj", header: "\(yearText) Proj.",
                                  activeDayCount: projection.activeDayCount, miles: projection.milesWalked))
            }
            return out
        }
    }

    private func valueText(_ s: String) -> Text {
        Text(s).font(.system(.subheadline, design: .monospaced)).bold()
    }

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            ForEach(columns) { column in
                LabeledContent("\(column.header) — Active days") {
                    valueText("\(column.activeDayCount)")
                }
                LabeledContent("\(column.header) — Miles") {
                    valueText(milesLabel(column.miles))
                }
            }
        } else {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("")
                    ForEach(columns) { column in
                        Text(column.header).font(.caption2.bold()).foregroundStyle(.secondary)
                            .fixedSize()
                            .gridColumnAlignment(.center)
                    }
                }
                GridRow {
                    Text("Active days").font(.caption).foregroundStyle(.secondary)
                    ForEach(columns) { column in
                        valueText("\(column.activeDayCount)")
                            .fixedSize()
                            .gridColumnAlignment(.center)
                    }
                }
                GridRow {
                    Text("Miles").font(.caption).foregroundStyle(.secondary)
                    ForEach(columns) { column in
                        valueText(milesLabel(column.miles))
                            .fixedSize()
                            .gridColumnAlignment(.center)
                    }
                }
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        }
    }
}
