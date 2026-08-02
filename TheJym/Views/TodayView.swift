//
//  TodayView.swift
//  TheJym
//
//  Home of training: shows the active Phase, where you are in the cycle,
//  and launches today's workout. Also handles Phase completion -> AI plan
//  for the next Phase.
//

import SwiftUI
import SwiftData

struct TodayView: View {
    @Binding var overflowTab: OverflowTab?

    @Environment(\.modelContext) private var context
    @Query(sort: \Phase.number, order: .reverse) private var phases: [Phase]
    @Query private var settingsList: [AppSettings]
    /// Standalone workout templates not tied to any Phase — "Upper Day"
    /// style quick workouts you can start anytime or reuse.
    @Query(filter: #Predicate<PhaseDay> { $0.phase == nil }, sort: \PhaseDay.name)
    private var quickWorkoutDays: [PhaseDay]
    /// Used only to tell whether the currently-featured cycle day has
    /// already been logged today (featuredDayRow's fade/strikethrough) —
    /// the row itself doesn't otherwise need every session/recovery.
    @Query(sort: \WorkoutSession.date) private var allSessionsForToday: [WorkoutSession]
    @Query(sort: \ActiveRecovery.date) private var activeRecoveriesForToday: [ActiveRecovery]
    @Query(sort: \BodyWeightEntry.date) private var bodyWeightsForQuickAdd: [BodyWeightEntry]

    @State private var showingPhaseSetup = false
    @State private var showingNextPhasePlanner = false
    @State private var statsPhase: Phase?
    @State private var quickJumpDay: PhaseDay?
    /// Today's already-logged session for the featured day, opened for
    /// editing when that day is tapped after it's already done.
    @State private var editingTodaySession: WorkoutSession?
    @State private var expandedDayIDs: Set<PersistentIdentifier> = []
    @State private var startingQuickWorkout: PhaseDay?
    @State private var showingNewQuickWorkout = false
    @State private var editingQuickWorkout: PhaseDay?

    @State private var newWeightText = ""
    @State private var selectedWeightDate = Formatters.nearestPastMonday()
    @FocusState private var weightFieldFocused: Bool

    private var existingWeightEntryThisWeek: BodyWeightEntry? {
        bodyWeightsForQuickAdd.first { Calendar.current.isDate($0.date, inSameDayAs: selectedWeightDate) }
    }

    private var activePhase: Phase? { phases.first(where: \.isActive) }
    private var settings: AppSettings? { settingsList.first }

    var body: some View {
        NavigationStack {
            List {
                if let phase = activePhase {
                    if phase.displayIsComplete {
                        phaseCompleteSection(phase)
                    } else {
                        activePhaseSections(phase)
                    }
                } else {
                    noPhaseSection
                }

                bodyWeightQuickAddSection
                quickWorkoutsSection
            }
            .navigationTitle("Train")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    OverflowMenuButton(overflowTab: $overflowTab)
                }
            }
            .sheet(isPresented: $showingPhaseSetup) {
                PhaseBuilderView(previousPhase: nil)
            }
            .sheet(isPresented: $showingNextPhasePlanner) {
                if let phase = activePhase {
                    NextPhasePlannerView(previousPhase: phase)
                }
            }
            .sheet(isPresented: $showingNewQuickWorkout) {
                QuickWorkoutBuilderView()
            }
            .sheet(item: $editingQuickWorkout) { day in
                QuickWorkoutBuilderView(existingDay: day)
            }
            .navigationDestination(item: $quickJumpDay) { day in
                if let phase = activePhase {
                    if day.isRest {
                        RestDayLogView(phase: phase, day: day)
                    } else {
                        WorkoutLogView(phase: phase, day: day)
                    }
                }
            }
            .navigationDestination(item: $startingQuickWorkout) { day in
                WorkoutLogView(phase: nil, day: day)
            }
            .navigationDestination(item: $statsPhase) { phase in
                PhaseStatsView(phase: phase)
            }
            .navigationDestination(item: $editingTodaySession) { session in
                SessionDetailView(session: session)
            }
        }
    }

    /// Quick body-weight logging right from Train — saves straight into the
    /// same BodyWeightEntry store the Weight tab reads from (no separate
    /// copy), just a faster path than switching tabs.
    private var bodyWeightQuickAddSection: some View {
        Section("Body Weight") {
            // Weight is tracked weekly, not daily — whatever day is tapped
            // snaps to that week's Monday, so only a Monday is ever
            // actually selectable.
            DatePicker("Week Starting Monday", selection: Binding(
                get: { selectedWeightDate },
                set: { selectedWeightDate = Formatters.nearestPastMonday(from: $0) }
            ), in: ...Date(), displayedComponents: .date)
            if existingWeightEntryThisWeek != nil {
                Text("Already logged this week — logging again updates it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                TextField("Weight (lbs)", text: $newWeightText)
                    .keyboardType(.decimalPad)
                    .focused($weightFieldFocused)
                    .onSubmit { logWeight() }
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Button {
                                weightFieldFocused = false
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            Spacer()
                            Button("Log") { logWeight() }
                                .disabled(Double(newWeightText) == nil)
                        }
                    }
                Button("Log") {
                    logWeight()
                }
                .buttonStyle(.borderedProminent)
                .disabled(Double(newWeightText) == nil)
            }
        }
    }

    private func logWeight() {
        guard let w = Double(newWeightText) else { return }
        if let existing = existingWeightEntryThisWeek {
            existing.weight = w
        } else {
            context.insert(BodyWeightEntry(date: selectedWeightDate, weight: w))
        }
        try? context.save()
        newWeightText = ""
        selectedWeightDate = Formatters.nearestPastMonday()
        weightFieldFocused = false
    }

    /// Standalone "Upper Day"-style workouts you can start or reuse without
    /// an active Phase — start any time, edit, or delete.
    @ViewBuilder
    private var quickWorkoutsSection: some View {
        Section("Quick Workouts") {
            ForEach(quickWorkoutDays, id: \.persistentModelID) { day in
                Button {
                    startingQuickWorkout = day
                } label: {
                    Text(day.name).foregroundStyle(.primary)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        context.delete(day)
                        try? context.save()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        editingQuickWorkout = day
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(.blue)
                }
            }
            Button {
                showingNewQuickWorkout = true
            } label: {
                Label("New Workout…", systemImage: "plus.circle")
            }
        }
    }

    @ViewBuilder
    private var noPhaseSection: some View {
        Section {
            ContentUnavailableView {
                Label("No Active Phase", systemImage: "calendar.badge.plus")
            } description: {
                Text("Build your split day by day (e.g. Pull A, Push A, Legs A, Rest), pick your exercises, and choose how many cycles the phase runs.")
            } actions: {
                Button("Set Up Phase 1") { showingPhaseSetup = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    /// One checkmark/circle + short name per slot (training AND Rest) in
    /// the cycle currently in progress, in template order — replaces the
    /// raw "N sessions logged" count so it's clear exactly which days are
    /// done vs. still open this cycle. Rest slots come straight from
    /// Phase.isSlotFilled now, same as training slots — a Rest day only
    /// counts once explicitly logged (Log Rest Day / a rest-day activity),
    /// never from the passive "nothing logged" backfill credit.
    private func cycleSlotChecklist(_ phase: Phase) -> some View {
        let days = phase.orderedDays
        // Always wraps to exactly 2 rows, however many days are in the
        // template — e.g. a 6-day LURLUR pattern becomes LUR / LUR — so
        // everything's visible at once instead of scrolling left/right.
        let columnsPerRow = max(1, Int(ceil(Double(days.count) / 2.0)))
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: columnsPerRow)
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(days, id: \.persistentModelID) { day in
                let done = phase.isSlotFilledForDisplay(day)
                VStack(spacing: 2) {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(done ? .green : .secondary)
                    Text(day.name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private func activePhaseSections(_ phase: Phase) -> some View {
        Section {
            Button {
                statsPhase = phase
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Phase \(phase.number)").font(.title2.bold())
                        Spacer()
                    }
                    ProgressView(value: Double(phase.displayFilledSlotCount),
                                 total: Double(phase.orderedDays.count * phase.totalCycles))
                    HStack {
                        Text("Cycle \(phase.displayCurrentCycle) of \(phase.totalCycles)")
                        if settings?.deloadWeeksEnabled == true, phase.deloadCycle == phase.displayCurrentCycle {
                            Label("Deload", systemImage: "arrow.down.heart")
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    cycleSlotChecklist(phase)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }

        Section("Your Cycle") {
            if let nextDay = templateNextDay(phase) {
                featuredDayRow(phase, nextDay)
                ForEach(upcomingDays(phase, after: nextDay), id: \.persistentModelID) { day in
                    collapsibleDayRow(phase, day)
                }
            } else {
                ForEach(phase.orderedDays, id: \.persistentModelID) { day in
                    collapsibleDayRow(phase, day)
                }
            }
        }
    }

    /// What's up next in the actual template rotation (Rest included in its
    /// real position) — the day right after whichever day was logged most
    /// recently, wrapping around the cycle. Purely for display: distinct
    /// from Phase.nextDay (the next unfilled TRAINING slot, which
    /// deliberately ignores Rest and drives real cycle-completion/
    /// progression math) — you can still train out of order or skip a Rest
    /// day entirely and slot-filling behaves exactly as it always has; this
    /// only decides what's featured as "next" here.
    ///
    /// Deliberately excludes anything logged TODAY from "last logged" — the
    /// featured slot stays put all day (however it's completed, it just
    /// shows as done — see featuredDayRow) and only actually rotates at the
    /// next real midnight, once today's own log is no longer "today."
    private func templateNextDay(_ phase: Phase) -> PhaseDay? {
        let ordered = phase.orderedDays
        guard !ordered.isEmpty else { return nil }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let lastLoggedDay = phase.sessions
            .filter { $0.day != nil && cal.startOfDay(for: $0.date) < today }
            .sorted { $0.date < $1.date }
            .last?.day
        guard let lastDay = lastLoggedDay,
              let idx = ordered.firstIndex(where: { $0.persistentModelID == lastDay.persistentModelID })
        else {
            return phase.nextDay ?? ordered.first
        }
        return ordered[(idx + 1) % ordered.count]
    }

    /// The rest of the cycle in actual upcoming order (including Rest days
    /// interspersed where they really fall), starting right after `nextDay`
    /// and wrapping back around to it — not just "every other day in
    /// template order," which could show a day that's really 3 slots away
    /// right after one that's next up in 1.
    private func upcomingDays(_ phase: Phase, after nextDay: PhaseDay) -> [PhaseDay] {
        let ordered = phase.orderedDays
        guard let idx = ordered.firstIndex(where: { $0.persistentModelID == nextDay.persistentModelID }) else {
            return ordered.filter { $0.persistentModelID != nextDay.persistentModelID }
        }
        let rotated = Array(ordered[(idx + 1)...] + ordered[..<idx])
        return rotated
    }

    /// True once today's featured day has something logged for it — a real
    /// session tied to this exact PhaseDay, or (for a Rest day) any plain
    /// rest credit today. The row stays featured regardless (see
    /// templateNextDay) until the actual midnight rollover; this only
    /// controls whether it's shown as already-done in the meantime.
    private func isFeaturedDayDoneToday(_ day: PhaseDay) -> Bool {
        let cal = Calendar.current
        let hasSessionForDay = allSessionsForToday.contains {
            cal.isDateInToday($0.date) && $0.day?.persistentModelID == day.persistentModelID
        }
        guard day.isRest else { return hasSessionForDay }
        return hasSessionForDay || activeRecoveriesForToday.contains { cal.isDateInToday($0.date) }
    }

    /// The day up next in the cycle: a play button to jump straight into it,
    /// with its planned exercises previewed underneath (smaller than the
    /// name, since this row already stands out by being first + having the
    /// play button). Fades and strikes through once it's done for today —
    /// still the featured row until midnight, just visibly complete.
    /// Today's own session for this day, if it's already been logged —
    /// tapping the featured row once it's done reopens this for editing
    /// instead of starting a brand new workout on top of it.
    private func todaySession(for day: PhaseDay) -> WorkoutSession? {
        let cal = Calendar.current
        return allSessionsForToday.first {
            cal.isDateInToday($0.date) && $0.day?.persistentModelID == day.persistentModelID
        }
    }

    /// Reopens today's already-logged session for editing if this day is
    /// done, otherwise jumps into starting it fresh.
    private func tapFeaturedDay(_ day: PhaseDay, isDone: Bool) {
        if isDone, let session = todaySession(for: day) {
            editingTodaySession = session
        } else {
            quickJumpDay = day
        }
    }

    @ViewBuilder
    private func featuredDayRow(_ phase: Phase, _ day: PhaseDay) -> some View {
        let isDone = isFeaturedDayDoneToday(day)
        HStack(alignment: .top, spacing: 12) {
            Button {
                tapFeaturedDay(day, isDone: isDone)
            } label: {
                Image(systemName: isDone ? "checkmark.circle.fill" : "play.circle.fill")
                    .font(.system(size: 30))
            }
            .buttonStyle(.plain)

            if day.isRest {
                VStack(alignment: .leading, spacing: 3) {
                    Text(day.name).font(.headline).strikethrough(isDone)
                    Text("Log a rest-day activity, or just take it easy.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                let plan = phase.plan(for: day)
                VStack(alignment: .leading, spacing: 3) {
                    Text(day.name).font(.headline).strikethrough(isDone)
                    if plan.isEmpty {
                        Text("No exercises planned — edit the phase to add some.")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        ForEach(plan, id: \.persistentModelID) { pe in
                            HStack {
                                Text(pe.exerciseName)
                                Spacer()
                                Text(pe.setsSummaryText)
                                    .font(.system(.caption2, design: .monospaced))
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(isDone ? 0.5 : 1)
        .contentShape(Rectangle())
        .onTapGesture { tapFeaturedDay(day, isDone: isDone) }
    }

    /// Any other day in the cycle: just its name, with a disclosure to
    /// expand/collapse a preview of its exercises and a way to start it. A
    /// Rest day has no exercise list to preview, so it just shows its name
    /// and the log button on one line instead of needing to expand.
    @ViewBuilder
    private func collapsibleDayRow(_ phase: Phase, _ day: PhaseDay) -> some View {
        if day.isRest {
            HStack {
                Label(day.name, systemImage: "moon.zzz").foregroundStyle(.secondary)
                Spacer()
                Button {
                    quickJumpDay = day
                } label: {
                    Label("Log Rest Day Activity", systemImage: "figure.walk")
                        .font(.subheadline)
                }
            }
            .padding(.vertical, 2)
        } else {
            let isExpanded = expandedDayIDs.contains(day.persistentModelID)
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation {
                        if isExpanded { expandedDayIDs.remove(day.persistentModelID) }
                        else { expandedDayIDs.insert(day.persistentModelID) }
                    }
                } label: {
                    HStack {
                        Text(day.name)
                        Spacer()
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isExpanded {
                    let plan = phase.plan(for: day)
                    if plan.isEmpty {
                        Text("No exercises planned for \(day.name).")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        ForEach(plan, id: \.persistentModelID) { pe in
                            HStack {
                                Text(pe.exerciseName)
                                Spacer()
                                Text(pe.setsSummaryText)
                                    .font(.system(.caption2, design: .monospaced))
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                    }
                    Button {
                        quickJumpDay = day
                    } label: {
                        Label("Start \(day.name) Workout", systemImage: "play.fill")
                            .font(.subheadline)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func phaseCompleteSection(_ phase: Phase) -> some View {
        Section {
            ContentUnavailableView {
                Label("Phase \(phase.number) Complete 🎉", systemImage: "trophy.fill")
            } description: {
                Text("All \(phase.totalCycles) cycles done. Time to plan Phase \(phase.number + 1).")
            } actions: {
                if settings?.aiAssistantEnabled == true {
                    Button("Plan Phase \(phase.number + 1) with AI") { showingNextPhasePlanner = true }
                        .buttonStyle(.borderedProminent)
                }
                Button("Build Phase \(phase.number + 1) Manually") {
                    phase.isActive = false
                    showingPhaseSetup = true
                }
            }
        }
    }

}

/// Log a specific scheduled Rest day: an ad hoc exercise (any name/sets, not
/// tied to a plan), and/or a cardio activity with an optional distance. Each
/// session is tied to both this PhaseDay and `phase` — the same day/phase
/// pairing a real training session gets — so it fills this cycle's Rest
/// slot (Phase.isSlotFilled/cycleWalk) exactly like Log Rest Day or a
/// rest-day activity are supposed to. It still can't shift which TRAINING
/// day is next (Phase.nextDay only ever looks at trainingDays), so logging
/// here is safe to do out of order without disturbing that.
struct RestDayLogView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ExerciseDef.name) private var exerciseDefs: [ExerciseDef]
    @Query(sort: \RestDayActivity.date, order: .reverse) private var allActivities: [RestDayActivity]
    @Query(sort: \ActiveRecovery.date, order: .reverse) private var allActiveRecoveries: [ActiveRecovery]
    @Query(sort: \WorkoutSession.date, order: .reverse) private var allSessions: [WorkoutSession]

    let phase: Phase
    let day: PhaseDay

    struct SetDraft: Identifiable { let id = UUID(); var weightText = ""; var repsText = "" }
    struct ExDraft: Identifiable { let id = UUID(); var name = ""; var sets: [SetDraft] = [SetDraft()] }

    /// Defaults to today; the DatePicker lets you back-date a missed Rest
    /// day, same as AddHistoricalWorkoutView does for a missed workout.
    @State private var selectedDate = Date()
    @State private var exercises: [ExDraft] = [ExDraft()]
    @State private var activityName = ""
    @State private var distanceText = ""
    @State private var distanceUnit = "mi"
    private enum Field { case activityName, distance }
    @FocusState private var focusedField: Field?

    private var todaysActivities: [RestDayActivity] {
        allActivities.filter { Calendar.current.isDate($0.date, inSameDayAs: selectedDate) }
    }

    /// The selected date's plain "I rested today" credit, if logged via the
    /// one-tap button below — nil once it's been superseded by an activity,
    /// or if nothing's been logged yet.
    private var todaysActiveRecovery: ActiveRecovery? {
        allActiveRecoveries.first { Calendar.current.isDate($0.date, inSameDayAs: selectedDate) }
    }

    /// The no-activity History entry the plain button creates alongside the
    /// ActiveRecovery credit — identified by the selected date + this exact
    /// PhaseDay + no exercise logs (an activity/exercise session always has
    /// at least one), so it's found and removed as a pair.
    private var todaysPlainRestSession: WorkoutSession? {
        allSessions.first {
            Calendar.current.isDate($0.date, inSameDayAs: selectedDate)
                && $0.day?.persistentModelID == day.persistentModelID
                && $0.exerciseLogs.isEmpty
        }
    }

    /// True once the selected date's already been credited as a plain rest
    /// day (either via the one-tap button below, or an activity/exercise
    /// logged here — no need to double-credit the streak for the same day).
    private var restDayAlreadyCredited: Bool {
        todaysActiveRecovery != nil || !todaysActivities.isEmpty
    }

    /// Every distinct activity name ever logged — live or via a CSV/Excel
    /// import, both land in the same RestDayActivity table — case-
    /// insensitively deduped and alphabetized, so a name used once can be
    /// quickly reselected instead of retyped.
    private var knownActivityNames: [String] {
        var seen = Set<String>()
        var names: [String] = []
        for activity in allActivities.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
            let key = activity.name.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            names.append(activity.name)
        }
        return names
    }

    private var canSaveExercises: Bool {
        exercises.contains { ex in
            !ex.name.trimmingCharacters(in: .whitespaces).isEmpty &&
            ex.sets.contains { Double($0.weightText) != nil && Int($0.repsText) != nil }
        }
    }

    var body: some View {
        Form {
            Section {
                DatePicker("Date", selection: $selectedDate, in: ...Date(), displayedComponents: .date)
            }

            Section {
                Button {
                    if todaysActiveRecovery != nil {
                        unlogPlainRestDay()
                    } else {
                        logPlainRestDay()
                    }
                } label: {
                    Label(todaysActiveRecovery != nil ? "Rest Day Logged (tap to undo)"
                          : (restDayAlreadyCredited ? "Activity Logged" : "Log Rest Day"),
                          systemImage: todaysActiveRecovery != nil ? "checkmark.circle.fill" : "moon.zzz.fill")
                }
                .disabled(restDayAlreadyCredited && todaysActiveRecovery == nil)
            } footer: {
                Text("One tap to credit the date above toward your rest-bank streak and log it in History — no need to log a specific activity. Tap again to undo, or log an activity below, which automatically replaces this credit.")
            }

            Section("Cardio / Activity") {
                HStack {
                    TextField("e.g. Walk, Bike Ride, Yoga", text: $activityName)
                        .focused($focusedField, equals: .activityName)
                    if !knownActivityNames.isEmpty {
                        Menu {
                            ForEach(knownActivityNames, id: \.self) { name in
                                Button(name) { activityName = name }
                            }
                        } label: {
                            Image(systemName: "chevron.down.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    TextField("Distance (optional)", text: $distanceText)
                        .keyboardType(.decimalPad)
                        .focused($focusedField, equals: .distance)
                    Picker("Unit", selection: $distanceUnit) {
                        Text("mi").tag("mi")
                        Text("km").tag("km")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                }
                Button("Log Activity") { logActivity() }
                    .disabled(activityName.trimmingCharacters(in: .whitespaces).isEmpty)

                ForEach(todaysActivities, id: \.persistentModelID) { activity in
                    HStack {
                        Text(activity.name)
                        Spacer()
                        if let d = activity.distance, d > 0 {
                            Text("\(Formatters.trim(d)) \(activity.distanceUnit)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { idx in
                    for i in idx { context.delete(todaysActivities[i]) }
                    try? context.save()
                }
            }

            ForEach(exercises.indices, id: \.self) { i in
                Section {
                    TextField("Exercise name", text: $exercises[i].name)
                        .font(.headline)
                    ForEach($exercises[i].sets) { $set in
                        HStack(spacing: 10) {
                            TextField("lbs", text: $set.weightText)
                                .keyboardType(.decimalPad)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                            Text("×")
                            TextField("reps", text: $set.repsText)
                                .keyboardType(.numberPad)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                        }
                    }
                    .onDelete { idx in exercises[i].sets.remove(atOffsets: idx) }
                    Button("Add Set") { exercises[i].sets.append(SetDraft()) }
                } header: {
                    HStack {
                        Text(exercises.count > 1 ? "Exercise \(i + 1)" : "Exercise")
                        Spacer()
                        if exercises.count > 1 {
                            Button(role: .destructive) {
                                exercises.remove(at: i)
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                    }
                }
            }

            Section {
                Button("Add Exercise") { exercises.append(ExDraft()) }
                Button("Save Exercises") { saveExercises() }
                    .disabled(!canSaveExercises)
            }
        }
        .navigationTitle(day.name)
    }

    /// One-tap "I rested [on the selected date]" credit — an ActiveRecovery
    /// entry (same mechanism the rest-bank engine already reads,
    /// StatsEngine.compute's activeRecoveryDates) plus a no-activity
    /// WorkoutSession so it shows up in History and Stats immediately, same
    /// as any other logged day.
    private func logPlainRestDay() {
        WorkoutSession.removeBackfilledRestPlaceholder(on: selectedDate, context: context)
        context.insert(ActiveRecovery(date: selectedDate, type: .rest))
        let session = WorkoutSession(date: selectedDate, day: day, dayLabel: day.name, cycleNumber: 0)
        session.phase = phase
        context.insert(session)
        try? context.save()
    }

    /// Undoes logPlainRestDay() for the selected date — a no-op if nothing's
    /// credited there. Called either directly (tapping the button again) or
    /// automatically when a real activity supersedes the plain credit.
    private func unlogPlainRestDay() {
        if let recovery = todaysActiveRecovery { context.delete(recovery) }
        if let session = todaysPlainRestSession { context.delete(session) }
        try? context.save()
    }

    private func logActivity() {
        focusedField = nil
        let trimmed = activityName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // A specific activity supersedes the generic "I rested today"
        // credit — remove it (and its no-activity session) so today doesn't
        // end up double-counted.
        unlogPlainRestDay()
        let distance = Double(distanceText)
        context.insert(RestDayActivity(date: selectedDate, name: trimmed, distance: distance, distanceUnit: distanceUnit))

        // Also show up in History — folds the distance into the exercise
        // name since ExerciseLog/SetLog don't have a distance field of
        // their own. Same "no Phase" pattern as ad hoc exercises: this
        // shouldn't shift where the training cycle thinks you are.
        let displayName = distance.map { "\(trimmed) (\(Formatters.trim($0)) \(distanceUnit))" } ?? trimmed
        WorkoutSession.removeBackfilledRestPlaceholder(on: selectedDate, context: context)
        let session = WorkoutSession(date: selectedDate, day: day, dayLabel: day.name, cycleNumber: 0)
        session.phase = phase
        context.insert(session)
        let log = ExerciseLog(exerciseName: displayName, targetReps: [], order: 0)
        log.session = session
        context.insert(log)
        let set = SetLog(index: 0, weight: 0, reps: 1)
        set.exerciseLog = log
        context.insert(set)
        var knownDefs = Dictionary(uniqueKeysWithValues: exerciseDefs.map { ($0.name, $0) })
        ExerciseDef.ensureAnyVariantExists(name: displayName, knownDefs: &knownDefs, context: context)

        try? context.save()
        activityName = ""
        distanceText = ""
    }

    private func saveExercises() {
        var entries: [(name: String, sets: [SetDraft])] = []
        for ex in exercises {
            let name = ex.name.trimmingCharacters(in: .whitespaces)
            let validSets = ex.sets.filter { Double($0.weightText) != nil && Int($0.repsText) != nil }
            guard !name.isEmpty, !validSets.isEmpty else { continue }
            entries.append((name, validSets))
        }
        guard !entries.isEmpty else { return }

        WorkoutSession.removeBackfilledRestPlaceholder(on: selectedDate, context: context)
        let session = WorkoutSession(date: selectedDate, day: day, dayLabel: day.name, cycleNumber: 0)
        session.phase = phase
        context.insert(session)

        var knownDefs = Dictionary(uniqueKeysWithValues: exerciseDefs.map { ($0.name, $0) })
        for (order, entry) in entries.enumerated() {
            let log = ExerciseLog(exerciseName: entry.name, targetReps: [], order: order)
            log.session = session
            context.insert(log)
            for (i, s) in entry.sets.enumerated() {
                let set = SetLog(index: i, weight: Double(s.weightText) ?? 0, reps: Int(s.repsText) ?? 0)
                set.exerciseLog = log
                context.insert(set)
            }
            ExerciseDef.ensureAnyVariantExists(name: entry.name, knownDefs: &knownDefs, context: context)
        }
        try? context.save()
        exercises = [ExDraft()]
    }
}

// MARK: - Per-Phase stats screen

/// Stats scoped to one specific Phase: when it started, its best
/// consistency streak while it was (or has been) running, cycle progress,
/// and each exercise's top set logged during it.
struct PhaseStatsView: View {
    let phase: Phase
    @Query(sort: \ActiveRecovery.date) private var activeRecoveries: [ActiveRecovery]

    private struct TopSet: Identifiable {
        let id = UUID()
        let exerciseName: String
        let summary: String
        let date: Date?
    }

    /// Real, exercise-bearing sessions logged under this specific phase.
    private var phaseSessions: [WorkoutSession] {
        phase.sessions.filter { !$0.exerciseLogs.isEmpty }
    }

    private var completedCycles: Int {
        phase.filledSlotCount / max(phase.orderedDays.count, 1)
    }

    /// Best rest-bank streak achieved during this phase's own timeframe,
    /// using the phase's own split-derived earn rate throughout — an
    /// inactive/completed phase is bounded at its last logged session
    /// rather than walking all the way to today.
    private var bestStreak: Int {
        let trainingDates = phaseSessions.map(\.date)
        let restDates = activeRecoveries.filter { $0.date >= phase.startDate }.map(\.date)
        guard !(trainingDates + restDates).isEmpty else { return 0 }
        let end = phase.isActive ? Date() : ((trainingDates + restDates).max() ?? phase.startDate)
        let ratePeriods = [StatsEngine.RatePeriod(start: phase.startDate, earnRate: phase.restBankEarnRate)]
        return StatsEngine.computeRestBank(trainingCreditedDates: trainingDates, restCreditedDates: restDates,
                                           ratePeriods: ratePeriods, now: end).maxStreak
    }

    /// One entry per exercise logged in this phase — its best session, by
    /// total weight moved (fixedSets) or fewest sets to reach the target
    /// (repTotal, falling back to total weight moved if never reached).
    private var topSets: [TopSet] {
        let logs = phaseSessions.flatMap(\.exerciseLogs).filter { !$0.sets.isEmpty }
        let grouped = Dictionary(grouping: logs, by: \.exerciseName)
        return grouped.keys.sorted().compactMap { name -> TopSet? in
            guard let group = grouped[name], let first = group.first else { return nil }
            switch first.goalType {
            case .fixedSets:
                guard let best = group.max(by: { $0.totalWeightMoved < $1.totalWeightMoved }) else { return nil }
                return TopSet(exerciseName: name, summary: PaceEngine.weightsSummaryString(for: best),
                              date: best.session?.date)
            case .repTotal(let target):
                guard let best = PaceEngine.bestRepTotalLog(among: group) else { return nil }
                let summary = best.repTotalReached
                    ? "\(best.sortedSets.count) set\(best.sortedSets.count == 1 ? "" : "s") to \(target) reps"
                    : "\(best.repTotalSoFar)/\(target) reps (unfinished)"
                return TopSet(exerciseName: name, summary: summary, date: best.session?.date)
            }
        }
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Started", value: Formatters.date.string(from: phase.startDate))
                LabeledContent("Status", value: phase.isActive ? "Active" : (phase.isComplete ? "Complete" : "Inactive"))
                LabeledContent("Cycles Completed", value: "\(completedCycles) of \(phase.totalCycles)")
                LabeledContent("Best Streak", value: "\(bestStreak) day\(bestStreak == 1 ? "" : "s")")
                LabeledContent("Workouts Logged", value: "\(phaseSessions.count)")
            } header: {
                Text("Phase \(phase.number)")
            } footer: {
                Text(phase.summary)
            }

            Section("Top Sets") {
                if topSets.isEmpty {
                    Text("Nothing logged in this phase yet.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(topSets) { top in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(top.exerciseName).font(.headline)
                            Text(top.summary)
                                .font(.system(.subheadline, design: .monospaced))
                                .foregroundStyle(.secondary)
                            if let date = top.date {
                                Text(Formatters.date.string(from: date))
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle("Phase \(phase.number) Stats")
        .navigationBarTitleDisplayMode(.inline)
    }
}
