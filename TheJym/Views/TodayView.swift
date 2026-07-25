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
    @Query(sort: \RestDayActivity.date, order: .reverse) private var restActivities: [RestDayActivity]

    @State private var showingPhaseSetup = false
    @State private var showingNextPhasePlanner = false
    @State private var newActivityText = ""
    @State private var newActivityDistanceText = ""
    @State private var newActivityDistanceUnit = "mi"
    @State private var quickJumpDay: PhaseDay?
    @State private var expandedDayIDs: Set<PersistentIdentifier> = []

    private var activePhase: Phase? { phases.first(where: \.isActive) }
    private var settings: AppSettings? { settingsList.first }

    private var todaysActivities: [RestDayActivity] {
        restActivities.filter { Calendar.current.isDateInToday($0.date) }
    }

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

                restDayActivitySection
            }
            .navigationTitle("Train")
            .toolbar {
                if let phase = activePhase, !phase.orderedDays.isEmpty {
                    ToolbarItem(placement: .principal) {
                        Menu {
                            ForEach(phase.orderedDays, id: \.persistentModelID) { day in
                                Button(day.isRest ? "\(day.name) (Rest)" : day.name) { quickJumpDay = day }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text("Train")
                                Image(systemName: "chevron.down")
                                    .font(.caption)
                            }
                        }
                    }
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
            .navigationDestination(item: $quickJumpDay) { day in
                if let phase = activePhase {
                    if day.isRest {
                        RestDayLogView(phase: phase, day: day)
                    } else {
                        WorkoutLogView(phase: phase, day: day)
                    }
                }
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
    /// expand/collapse a preview of its exercises and a way to start it.
    @ViewBuilder
    private func collapsibleDayRow(_ phase: Phase, _ day: PhaseDay) -> some View {
        let isExpanded = expandedDayIDs.contains(day.persistentModelID)
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation {
                    if isExpanded { expandedDayIDs.remove(day.persistentModelID) }
                    else { expandedDayIDs.insert(day.persistentModelID) }
                }
            } label: {
                HStack {
                    if day.isRest {
                        Label(day.name, systemImage: "moon.zzz").foregroundStyle(.secondary)
                    } else {
                        Text(day.name)
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                if !day.isRest {
                    let plan = phase.plan(for: day)
                    if plan.isEmpty {
                        Text("No exercises planned for \(day.name).")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(plan, id: \.persistentModelID) { pe in
                            HStack {
                                Text(pe.exerciseName)
                                Spacer()
                                Text(pe.targetReps.map(String.init).joined(separator: "/"))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Button {
                    quickJumpDay = day
                } label: {
                    Label(day.isRest ? "Log \(day.name)" : "Start \(day.name) Workout",
                          systemImage: day.isRest ? "figure.walk" : "play.fill")
                        .font(.subheadline)
                }
            }
        }
        .padding(.vertical, 2)
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

    @ViewBuilder
    private var restDayActivitySection: some View {
        Section("Rest Day Activity Quick Add") {
            Text("Log a walk or something light on an off day — it counts toward your streak, but skipping it on an actual rest day won't break one.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("e.g. Walk, Yoga, Bike Ride", text: $newActivityText)
            HStack {
                TextField("Distance (optional)", text: $newActivityDistanceText)
                    .keyboardType(.decimalPad)
                Picker("Unit", selection: $newActivityDistanceUnit) {
                    Text("mi").tag("mi")
                    Text("km").tag("km")
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
                Button("Log") { logActivity() }
                    .buttonStyle(.borderedProminent)
                    .disabled(newActivityText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
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
    }

    private func logActivity() {
        let trimmed = newActivityText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        context.insert(RestDayActivity(name: trimmed,
                                       distance: Double(newActivityDistanceText),
                                       distanceUnit: newActivityDistanceUnit))
        try? context.save()
        newActivityText = ""
        newActivityDistanceText = ""
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
                HStack {
                    TextField("Distance (optional)", text: $distanceText)
                        .keyboardType(.decimalPad)
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
        let trimmed = activityName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        context.insert(RestDayActivity(name: trimmed,
                                       distance: Double(distanceText),
                                       distanceUnit: distanceUnit))
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
