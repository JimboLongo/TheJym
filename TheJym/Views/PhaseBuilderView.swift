//
//  PhaseBuilderView.swift
//  TheJym
//
//  Build a Phase's one-cycle day template from scratch: add training days
//  (any name — "Pull A", "Upper 1", ...) and fixed "Rest" days in whatever
//  order and however many you want (no fixed cycle length), then add
//  exercises to each training day independently — two days never
//  automatically share an exercise list, even if similarly named.
//

import SwiftUI
import SwiftData

struct PhaseBuilderView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Phase.number, order: .reverse) private var phases: [Phase]
    @Query private var settingsList: [AppSettings]
    @Query(sort: \ExerciseDef.name) private var exerciseDefs: [ExerciseDef]
    @Query(sort: \Bar.name) private var bars: [Bar]

    /// If non-nil, seed the day structure + plan from an AI-planned or previous phase.
    var previousPhase: Phase?
    var seededPlan: [String: [ProgressionEngine.PlannedSlot]]? = nil

    @State private var cycles = 8
    @State private var dayDrafts: [DayDraft] = []
    @State private var newDayName = ""
    @State private var showingNewDayAlert = false
    @State private var pendingPreset: SplitPreset?

    struct SplitPreset {
        let name: String
        let days: [(name: String, isRest: Bool)]
    }

    static let presets: [SplitPreset] = [
        SplitPreset(name: "Push / Pull / Legs", days: [
            ("Push", false), ("Pull", false), ("Legs", false), ("Rest", true),
        ]),
        SplitPreset(name: "Push / Pull / Legs (6-Day)", days: [
            ("Push A", false), ("Pull A", false), ("Legs A", false),
            ("Push B", false), ("Pull B", false), ("Legs B", false), ("Rest", true),
        ]),
        SplitPreset(name: "Upper / Lower", days: [
            ("Upper", false), ("Lower", false), ("Rest", true),
        ]),
        SplitPreset(name: "Full Body", days: [
            ("Full Body", false), ("Rest", true),
        ]),
        SplitPreset(name: "Bro Split", days: [
            ("Chest", false), ("Back", false), ("Legs", false),
            ("Shoulders", false), ("Arms", false), ("Rest", true),
        ]),
    ]

    struct DraftExercise: Identifiable {
        let id = UUID()
        var name: String
        var repsText: String        // "5/5/5/3/3/3"
        var weightsText: String     // optional "135/135/135/145/145/145"
        var isLowerBody: Bool
    }

    struct DayDraft: Identifiable {
        let id = UUID()
        var name: String
        var isRest: Bool
        var exercises: [DraftExercise] = []
    }

    private var canSave: Bool {
        !dayDrafts.isEmpty && dayDrafts.contains { !$0.isRest && !$0.exercises.isEmpty }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper("Cycles: \(cycles)", value: $cycles, in: 1...20)
                    if settingsList.first?.deloadWeeksEnabled == true {
                        let dc = ProgressionEngine.deloadCycle(totalCycles: cycles)
                        if dc > 0 {
                            Label("AI will make cycle \(dc) a deload cycle (~60% loads) so you start the next phase recovered.",
                                  systemImage: "arrow.down.heart")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                } footer: {
                    Text("How many times the day list below repeats.")
                }

                Section {
                    Menu("Start from a Preset") {
                        ForEach(Self.presets, id: \.name) { preset in
                            Button(preset.name) { choosePreset(preset) }
                        }
                    }
                } footer: {
                    Text("Fills in the day list below — you can still add, rename, reorder, or delete days after.")
                }

                Section {
                    ForEach($dayDrafts) { $day in
                        if day.isRest {
                            Text("Rest").foregroundStyle(.secondary)
                        } else {
                            NavigationLink {
                                DayEditorView(day: $day, exerciseDefs: exerciseDefs, bars: bars)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(day.name).font(.headline)
                                    Text("\(day.exercises.count) exercise\(day.exercises.count == 1 ? "" : "s")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .onDelete { idx in dayDrafts.remove(atOffsets: idx) }
                    .onMove { from, to in dayDrafts.move(fromOffsets: from, toOffset: to) }

                    Button("Add Training Day…") { showingNewDayAlert = true }
                    Button("Add Rest Day") { dayDrafts.append(DayDraft(name: "Rest", isRest: true)) }
                } header: {
                    Text("One Cycle")
                } footer: {
                    Text("Add days in order until one cycle is complete — it doesn't need to be 7 days. \"Pull A\" and \"Pull B\" (for example) are independent; they don't have to share the same exercises.")
                }
            }
            .navigationTitle(previousPhase == nil && phases.isEmpty ? "Phase 1 Setup" : "New Phase")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .navigation) { EditButton() }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start Phase") { save() }
                        .disabled(!canSave)
                }
            }
            .alert("New Training Day", isPresented: $showingNewDayAlert) {
                TextField("e.g. Pull A, Upper 1", text: $newDayName)
                Button("Add") {
                    let trimmed = newDayName.trimmingCharacters(in: .whitespaces)
                    newDayName = ""
                    guard !trimmed.isEmpty, trimmed.localizedCaseInsensitiveCompare("Rest") != .orderedSame else { return }
                    dayDrafts.append(DayDraft(name: trimmed, isRest: false))
                }
                Button("Cancel", role: .cancel) { newDayName = "" }
            }
            .confirmationDialog(
                "Replace your current days with \(pendingPreset?.name ?? "")?",
                isPresented: Binding(get: { pendingPreset != nil }, set: { if !$0 { pendingPreset = nil } }),
                titleVisibility: .visible
            ) {
                Button("Replace", role: .destructive) {
                    if let preset = pendingPreset { applyPreset(preset) }
                    pendingPreset = nil
                }
                Button("Cancel", role: .cancel) { pendingPreset = nil }
            }
            .onAppear(perform: seed)
        }
    }

    private func choosePreset(_ preset: SplitPreset) {
        if dayDrafts.isEmpty {
            applyPreset(preset)
        } else {
            pendingPreset = preset
        }
    }

    private func applyPreset(_ preset: SplitPreset) {
        dayDrafts = preset.days.map { DayDraft(name: $0.name, isRest: $0.isRest) }
    }

    private func seed() {
        guard dayDrafts.isEmpty, let prev = previousPhase else { return }
        cycles = prev.totalCycles
        for day in prev.orderedDays {
            if day.isRest {
                dayDrafts.append(DayDraft(name: "Rest", isRest: true))
            } else {
                let slots = seededPlan?[day.name] ?? []
                let exercises = slots.map {
                    DraftExercise(name: $0.exerciseName,
                                  repsText: $0.targetReps.map(String.init).joined(separator: "/"),
                                  weightsText: $0.startingWeights.map { Formatters.trim($0) }.joined(separator: "/"),
                                  isLowerBody: $0.isLowerBody)
                }
                dayDrafts.append(DayDraft(name: day.name, isRest: false, exercises: exercises))
            }
        }
    }

    private func save() {
        let nextNumber = (phases.map(\.number).max() ?? 0) + 1
        // Deactivate old phases
        for p in phases { p.isActive = false }

        let deload = (settingsList.first?.deloadWeeksEnabled == true)
            ? ProgressionEngine.deloadCycle(totalCycles: cycles) : 0

        let phase = Phase(number: nextNumber, totalCycles: cycles, deloadCycle: deload)
        context.insert(phase)

        var knownVariantKeys = Set(exerciseDefs.map(\.variantKey))
        for (dayOrder, dayDraft) in dayDrafts.enumerated() {
            let day = PhaseDay(order: dayOrder, name: dayDraft.name, isRest: dayDraft.isRest)
            day.phase = phase
            context.insert(day)

            guard !dayDraft.isRest else { continue }
            for (i, d) in dayDraft.exercises.enumerated() {
                let reps = d.repsText.split(separator: "/").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                let weights = d.weightsText.split(separator: "/").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                guard !reps.isEmpty else { continue }
                let pe = PlannedExercise(order: i, exerciseName: d.name, targetReps: reps,
                                         suggestedWeights: weights, isLowerBody: d.isLowerBody)
                pe.day = day
                context.insert(pe)

                ExerciseDef.ensureVariantExists(name: d.name, targetReps: reps, isLowerBody: d.isLowerBody,
                                                knownVariantKeys: &knownVariantKeys, context: context)
            }
        }
        try? context.save()
        dismiss()
    }
}

/// Add/edit exercises for one training day. Reuses ExerciseEditView to create
/// or extend the shared Exercises library, so anything added here shows up
/// there too.
struct DayEditorView: View {
    @Binding var day: PhaseBuilderView.DayDraft
    let exerciseDefs: [ExerciseDef]
    let bars: [Bar]

    @State private var showingNewExerciseSheet = false
    @State private var prefilledName: String?

    private var groupedExerciseDefs: [(name: String, variants: [ExerciseDef])] {
        ExerciseDef.grouped(exerciseDefs)
    }

    var body: some View {
        List {
            ForEach($day.exercises) { $item in
                DraftExerciseRow(item: $item)
            }
            .onDelete { idx in day.exercises.remove(atOffsets: idx) }

            Menu("Add Exercise") {
                ForEach(groupedExerciseDefs, id: \.name) { group in
                    Menu(group.name) {
                        ForEach(group.variants, id: \.persistentModelID) { def in
                            Button(def.targetReps.map(String.init).joined(separator: "/")) {
                                addToDay(def)
                            }
                        }
                        Divider()
                        Button("Add New Set…") {
                            prefilledName = group.name
                            showingNewExerciseSheet = true
                        }
                    }
                }
                Divider()
                Button("New Exercise…") {
                    prefilledName = nil
                    showingNewExerciseSheet = true
                }
            }
        }
        .navigationTitle(day.name)
        .sheet(isPresented: $showingNewExerciseSheet) {
            ExerciseEditView(def: nil, bars: bars, prefilledName: prefilledName) { newDef in
                addToDay(newDef)
            }
        }
    }

    private func addToDay(_ def: ExerciseDef) {
        day.exercises.append(
            PhaseBuilderView.DraftExercise(name: def.name,
                                           repsText: def.targetReps.map(String.init).joined(separator: "/"),
                                           weightsText: "",
                                           isLowerBody: def.isLowerBody))
    }
}

struct DraftExerciseRow: View {
    @Binding var item: PhaseBuilderView.DraftExercise

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Exercise name", text: $item.name)
                .font(.headline)
            HStack {
                TextField("Reps e.g. 5/5/5/3/3/3", text: $item.repsText)
                    .font(.system(.caption, design: .monospaced))
                    .keyboardType(.numbersAndPunctuation)
                Toggle("Lower", isOn: $item.isLowerBody)
                    .toggleStyle(.button)
                    .font(.caption2)
            }
            TextField("Start weights (optional) e.g. 135/135/135/145/145/145", text: $item.weightsText)
                .font(.system(.caption, design: .monospaced))
                .keyboardType(.numbersAndPunctuation)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Built-in exercise library (used to seed the Exercises tab on first launch)

enum ExerciseLibrary {
    struct Entry { let name: String; let defaultReps: String; let lower: Bool }
    struct Group { let group: String; let exercises: [Entry] }

    static let grouped: [Group] = [
        Group(group: "Chest / Push", exercises: [
            Entry(name: "Bench Press", defaultReps: "5/5/5/3/3/3", lower: false),
            Entry(name: "Incline DB Press", defaultReps: "8/8/8/8", lower: false),
            Entry(name: "Overhead Press", defaultReps: "5/5/5/5", lower: false),
            Entry(name: "Dips", defaultReps: "10/10/10", lower: false),
            Entry(name: "Cable Fly", defaultReps: "12/12/12", lower: false),
            Entry(name: "Lateral Raise", defaultReps: "15/15/15", lower: false),
            Entry(name: "Triceps Pushdown", defaultReps: "12/12/12", lower: false),
            Entry(name: "Skullcrusher (EZ Bar)", defaultReps: "10/10/10", lower: false),
        ]),
        Group(group: "Back / Pull", exercises: [
            Entry(name: "Deadlift", defaultReps: "5/5/3/3", lower: true),
            Entry(name: "Barbell Row", defaultReps: "8/8/8/8", lower: false),
            Entry(name: "Seal Row", defaultReps: "8/8/8/8", lower: false),
            Entry(name: "Pull-Up", defaultReps: "8/8/8", lower: false),
            Entry(name: "Lat Pulldown", defaultReps: "10/10/10", lower: false),
            Entry(name: "Face Pull", defaultReps: "15/15/15", lower: false),
            Entry(name: "Band Pull-Apart", defaultReps: "20/20/20", lower: false),
            Entry(name: "EZ Bar Curl", defaultReps: "10/10/10", lower: false),
            Entry(name: "Hammer Curl", defaultReps: "12/12/12", lower: false),
        ]),
        Group(group: "Legs", exercises: [
            Entry(name: "Back Squat", defaultReps: "5/5/5/3/3", lower: true),
            Entry(name: "Front Squat", defaultReps: "6/6/6", lower: true),
            Entry(name: "Romanian Deadlift", defaultReps: "8/8/8", lower: true),
            Entry(name: "Leg Press", defaultReps: "10/10/10/10", lower: true),
            Entry(name: "Bulgarian Split Squat", defaultReps: "10/10/10", lower: true),
            Entry(name: "Leg Curl", defaultReps: "12/12/12", lower: true),
            Entry(name: "Leg Extension", defaultReps: "12/12/12", lower: true),
            Entry(name: "Calf Raise", defaultReps: "15/15/15/15", lower: true),
        ]),
    ]
}
