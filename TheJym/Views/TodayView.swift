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
    @Environment(\.modelContext) private var context
    @Query(sort: \Phase.number, order: .reverse) private var phases: [Phase]
    @Query private var settingsList: [AppSettings]
    /// Standalone workout templates not tied to any Phase — "Upper Day"
    /// style quick workouts you can start anytime or reuse.
    @Query(filter: #Predicate<PhaseDay> { $0.phase == nil }, sort: \PhaseDay.name)
    private var quickWorkoutDays: [PhaseDay]

    @State private var showingPhaseSetup = false
    @State private var showingNextPhasePlanner = false
    @State private var quickJumpDay: PhaseDay?
    @State private var expandedDayIDs: Set<PersistentIdentifier> = []
    @State private var startingQuickWorkout: PhaseDay?
    @State private var showingNewQuickWorkout = false
    @State private var editingQuickWorkout: PhaseDay?

    private var activePhase: Phase? { phases.first(where: \.isActive) }
    private var settings: AppSettings? { settingsList.first }

    var body: some View {
        NavigationStack {
            List {
                if let phase = activePhase {
                    if phase.isComplete {
                        phaseCompleteSection(phase)
                    } else {
                        activePhaseSections(phase)
                    }
                } else {
                    noPhaseSection
                }

                quickWorkoutsSection
            }
            .navigationTitle("Train")
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
        }
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

    @ViewBuilder
    private func activePhaseSections(_ phase: Phase) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Phase \(phase.number)").font(.title2.bold())
                    Spacer()
                    Text(phase.summary)
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.thinMaterial, in: Capsule())
                }
                ProgressView(value: Double(phase.completedSessionCount),
                             total: Double(phase.trainingDaysPerCycle * phase.totalCycles))
                HStack {
                    Text("Cycle \(phase.currentCycle) of \(phase.totalCycles)")
                    if settings?.deloadWeeksEnabled == true, phase.deloadCycle == phase.currentCycle {
                        Label("Deload", systemImage: "arrow.down.heart")
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Text("\(phase.completedSessionCount) sessions logged")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            .padding(.vertical, 4)
        }

        Section("Your Cycle") {
            if let nextDay = phase.nextDay {
                featuredDayRow(phase, nextDay)
                ForEach(phase.orderedDays.filter { $0.persistentModelID != nextDay.persistentModelID },
                        id: \.persistentModelID) { day in
                    collapsibleDayRow(phase, day)
                }
            } else {
                ForEach(phase.orderedDays, id: \.persistentModelID) { day in
                    collapsibleDayRow(phase, day)
                }
            }
        }
    }

    /// The day up next in the cycle: a play button to jump straight into it,
    /// with its planned exercises previewed underneath (smaller than the
    /// name, since this row already stands out by being first + having the
    /// play button).
    @ViewBuilder
    private func featuredDayRow(_ phase: Phase, _ day: PhaseDay) -> some View {
        let plan = phase.plan(for: day)
        HStack(alignment: .top, spacing: 12) {
            Button {
                quickJumpDay = day
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 30))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text(day.name).font(.headline)
                if plan.isEmpty {
                    Text("No exercises planned — edit the phase to add some.")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    ForEach(plan, id: \.persistentModelID) { pe in
                        HStack {
                            Text(pe.exerciseName)
                            Spacer()
                            Text(pe.targetReps.map(String.init).joined(separator: "/"))
                                .font(.system(.caption2, design: .monospaced))
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
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
                                Text(pe.targetReps.map(String.init).joined(separator: "/"))
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
/// tied to a plan), and/or a cardio activity with an optional distance.
/// Exercises are tied to this PhaseDay for reference, but never to
/// Phase.sessions — a Rest day logging something shouldn't shift where the
/// cycle thinks you are.
struct RestDayLogView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ExerciseDef.name) private var exerciseDefs: [ExerciseDef]
    @Query(sort: \RestDayActivity.date, order: .reverse) private var allActivities: [RestDayActivity]

    let phase: Phase
    let day: PhaseDay

    struct SetDraft: Identifiable { let id = UUID(); var weightText = ""; var repsText = "" }
    struct ExDraft: Identifiable { let id = UUID(); var name = ""; var sets: [SetDraft] = [SetDraft()] }

    @State private var exercises: [ExDraft] = [ExDraft()]
    @State private var activityName = ""
    @State private var distanceText = ""
    @State private var distanceUnit = "mi"
    private enum Field { case activityName, distance }
    @FocusState private var focusedField: Field?

    private var todaysActivities: [RestDayActivity] {
        allActivities.filter { Calendar.current.isDateInToday($0.date) }
    }

    private var canSaveExercises: Bool {
        exercises.contains { ex in
            !ex.name.trimmingCharacters(in: .whitespaces).isEmpty &&
            ex.sets.contains { Double($0.weightText) != nil && Int($0.repsText) != nil }
        }
    }

    var body: some View {
        Form {
            Section("Cardio / Activity") {
                TextField("e.g. Walk, Bike Ride, Yoga", text: $activityName)
                    .focused($focusedField, equals: .activityName)
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

    private func logActivity() {
        focusedField = nil
        let trimmed = activityName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let distance = Double(distanceText)
        context.insert(RestDayActivity(name: trimmed, distance: distance, distanceUnit: distanceUnit))

        // Also show up in History — folds the distance into the exercise
        // name since ExerciseLog/SetLog don't have a distance field of
        // their own. Same "no Phase" pattern as ad hoc exercises: this
        // shouldn't shift where the training cycle thinks you are.
        let displayName = distance.map { "\(trimmed) (\(Formatters.trim($0)) \(distanceUnit))" } ?? trimmed
        let session = WorkoutSession(day: day, dayLabel: day.name, cycleNumber: 0)
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

        let session = WorkoutSession(day: day, dayLabel: day.name, cycleNumber: 0)
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
