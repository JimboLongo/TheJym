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
    @State private var editingDayID: UUID?
    @State private var showingPresetPicker = false

    struct SplitPreset {
        let name: String
        let days: [(name: String, isRest: Bool)]
    }

    static let presets: [SplitPreset] = [
        SplitPreset(name: "Push / Pull / Legs / Rest", days: [
            ("Push", false), ("Pull", false), ("Legs", false), ("Rest", true),
        ]),
        SplitPreset(name: "Push / Pull / Legs / Rest (2x)", days: [
            ("Push A", false), ("Pull A", false), ("Legs A", false), ("Rest", true),
            ("Push B", false), ("Pull B", false), ("Legs B", false), ("Rest", true),
        ]),
        SplitPreset(name: "Upper / Lower / Rest", days: [
            ("Upper", false), ("Lower", false), ("Rest", true),
        ]),
        SplitPreset(name: "Upper / Lower / Rest (2x)", days: [
            ("Upper A", false), ("Lower A", false), ("Rest", true),
            ("Upper B", false), ("Lower B", false), ("Rest", true),
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
        var repsText: String        // "5/5/5/3/3/3" — fixedSets only
        var weightsText: String     // optional "135/135/135/145/145/145"
        var goalType: GoalType = .fixedSets
        var repTotalTargetText: String = ""   // repTotal only, e.g. "40"
        var repTotalProgressesReps: Bool = false
    }

    struct DayDraft: Identifiable {
        let id = UUID()
        var name: String
        var isRest: Bool
        var exercises: [DraftExercise] = []
        /// Set while this day's list is a straight copy of another day's —
        /// drives the "Copy from X" checkbox's checked state.
        var copiedFromID: UUID?
    }

    private var canSave: Bool {
        !dayDrafts.isEmpty && dayDrafts.contains { !$0.isRest && !$0.exercises.isEmpty }
    }

    /// If `name` looks like the second half of an A/B or 1/2 pair (e.g. "Legs
    /// B", "Push 2"), the counterpart name to offer a "copy from" shortcut for.
    private static func copyCounterpartName(for name: String) -> String? {
        let parts = name.trimmingCharacters(in: .whitespaces).split(separator: " ")
        guard parts.count >= 2, let last = parts.last else { return nil }
        let base = parts.dropLast().joined(separator: " ")

        if last.count == 1, let ch = last.first, ch.isLetter, ch.isUppercase, ch != "A" {
            return "\(base) A"
        }
        if let n = Int(last), n >= 2 {
            return "\(base) 1"
        }
        return nil
    }

    /// The day to offer copying from, if `day`'s name has a counterpart that
    /// already exists and has exercises to copy.
    private func copySource(for day: DayDraft) -> DayDraft? {
        guard let counterpart = Self.copyCounterpartName(for: day.name) else { return nil }
        return dayDrafts.first {
            !$0.isRest && !$0.exercises.isEmpty && $0.id != day.id &&
            $0.name.localizedCaseInsensitiveCompare(counterpart) == .orderedSame
        }
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
                    Button {
                        showingPresetPicker = true
                    } label: {
                        HStack {
                            Text("Start from a Preset")
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } footer: {
                    Text("Fills in the day list below — you can still add, rename, reorder, or delete days after.")
                }

                Section {
                    ForEach($dayDrafts) { $day in
                        HStack(spacing: 10) {
                            if day.isRest {
                                Text("Rest").foregroundStyle(.secondary)
                            } else {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 8) {
                                        TextField("Day name", text: $day.name)
                                            .font(.subheadline.weight(.semibold))
                                            .fixedSize()
                                        Button {
                                            editingDayID = day.id
                                        } label: {
                                            Text("\(day.exercises.count) exercise\(day.exercises.count == 1 ? "" : "s")")
                                                .font(.subheadline.weight(.semibold))
                                                .frame(maxWidth: .infinity)
                                                .padding(.vertical, 6)
                                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    if let source = copySource(for: day) {
                                        Toggle("Copy from \(source.name)", isOn: Binding(
                                            get: { day.copiedFromID == source.id },
                                            set: { checked in
                                                if checked {
                                                    day.exercises = source.exercises.map {
                                                        DraftExercise(name: $0.name, repsText: $0.repsText,
                                                                      weightsText: $0.weightsText)
                                                    }
                                                    day.copiedFromID = source.id
                                                } else {
                                                    day.exercises = []
                                                    day.copiedFromID = nil
                                                }
                                            }))
                                            .font(.caption)
                                    }
                                }
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                if let idx = dayDrafts.firstIndex(where: { $0.id == day.id }) {
                                    dayDrafts.remove(at: idx)
                                }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .onMove { from, to in dayDrafts.move(fromOffsets: from, toOffset: to) }

                    Button("Add Training Day…") { showingNewDayAlert = true }
                    Button("Add Rest Day") { dayDrafts.append(DayDraft(name: "Rest", isRest: true)) }
                } header: {
                    Text("One Cycle")
                } footer: {
                    Text("Drag \(Image(systemName: "line.3.horizontal")) to reorder days, or swipe to delete one. Add days in order until one cycle is complete — it doesn't need to be 7 days. \"Pull A\" and \"Pull B\" (for example) are independent; they don't have to share the same exercises.")
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle(previousPhase == nil && phases.isEmpty ? "Phase 1 Setup" : "New Phase")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
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
            .confirmationDialog("Start from a Preset", isPresented: $showingPresetPicker, titleVisibility: .visible) {
                ForEach(Self.presets, id: \.name) { preset in
                    Button(preset.name) { choosePreset(preset) }
                }
                Button("Cancel", role: .cancel) { }
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
            .navigationDestination(item: $editingDayID) { id in
                DayEditorView(day: bindingForDay(id: id), exerciseDefs: exerciseDefs, bars: bars)
            }
        }
    }

    /// Looked up by id (not a fixed index) so it stays valid across
    /// reordering/deleting other days while this one's editor is open.
    private func bindingForDay(id: UUID) -> Binding<DayDraft> {
        Binding(
            get: { dayDrafts.first { $0.id == id } ?? DayDraft(name: "", isRest: false) },
            set: { newValue in
                if let idx = dayDrafts.firstIndex(where: { $0.id == id }) {
                    dayDrafts[idx] = newValue
                }
            })
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
                                  weightsText: $0.startingWeights.map { Formatters.trim($0) }.joined(separator: "/"))
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

        var knownDefs = Dictionary(uniqueKeysWithValues: exerciseDefs.map { ($0.name, $0) })
        for (dayOrder, dayDraft) in dayDrafts.enumerated() {
            let day = PhaseDay(order: dayOrder, name: dayDraft.name, isRest: dayDraft.isRest)
            day.phase = phase
            context.insert(day)

            guard !dayDraft.isRest else { continue }
            for (i, d) in dayDraft.exercises.enumerated() {
                let weights = d.weightsText.split(separator: "/").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                let isBW = knownDefs[d.name]?.isBodyweight ?? false

                switch d.goalType {
                case .fixedSets:
                    let reps = d.repsText.split(separator: "/").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                    guard !reps.isEmpty else { continue }
                    let pe = PlannedExercise(order: i, exerciseName: d.name, targetReps: reps,
                                             suggestedWeights: weights, isBodyweight: isBW, goalType: .fixedSets)
                    pe.day = day
                    context.insert(pe)
                    ExerciseDef.ensureVariantExists(name: d.name, targetReps: reps,
                                                    knownDefs: &knownDefs, context: context)

                case .repTotal(let target):
                    guard target > 0 else { continue }
                    let pe = PlannedExercise(order: i, exerciseName: d.name, targetReps: [],
                                             suggestedWeights: weights, isBodyweight: isBW,
                                             goalType: .repTotal(target: target),
                                             repTotalProgressesReps: d.repTotalProgressesReps)
                    pe.day = day
                    context.insert(pe)
                    ExerciseDef.ensureAnyVariantExists(name: d.name, knownDefs: &knownDefs, context: context)
                }
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

    @State private var showingAddExercise = false

    var body: some View {
        List {
            ForEach($day.exercises) { $item in
                DraftExerciseRow(item: $item)
            }
            .onDelete { idx in day.exercises.remove(atOffsets: idx) }

            Button {
                showingAddExercise = true
            } label: {
                Text("Add Exercise")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .navigationTitle(day.name)
        .sheet(isPresented: $showingAddExercise) {
            AddExerciseToDayView(exerciseDefs: exerciseDefs, bars: bars) { def, reps, goalType in
                addToDay(def, reps: reps, goalType: goalType)
            }
        }
    }

    private func addToDay(_ def: ExerciseDef, reps: [Int], goalType: GoalType) {
        var draft = PhaseBuilderView.DraftExercise(name: def.name, repsText: "", weightsText: "")
        switch goalType {
        case .fixedSets:
            draft.repsText = reps.map(String.init).joined(separator: "/")
        case .repTotal(let target):
            draft.goalType = .repTotal(target: target)
            draft.repTotalTargetText = String(target)
        }
        day.exercises.append(draft)
    }
}

/// Pick an exercise's already-saved set, add a new set to an existing
/// exercise, or create a whole new exercise — used wherever a day needs a
/// new exercise slot (Phase Builder and Phase Edit alike).
struct AddExerciseToDayView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let exerciseDefs: [ExerciseDef]
    let bars: [Bar]
    /// `GoalType` reflects the choice made in the Add Set sheet — reps only
    /// carries values for `.fixedSets` (empty for `.repTotal`, whose target
    /// is already inside the GoalType itself).
    var onPick: (ExerciseDef, [Int], GoalType) -> Void

    @State private var showingNewExerciseSheet = false
    @State private var addSetTarget: ExerciseDef?
    @State private var searchText = ""
    @State private var selectedDef: ExerciseDef?

    private var filteredDefs: [ExerciseDef] {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return exerciseDefs }
        return exerciseDefs.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        NavigationStack {
            List {
                if exerciseDefs.isEmpty {
                    Text("No exercises yet — create one below.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if filteredDefs.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    ForEach(filteredDefs, id: \.persistentModelID) { def in
                        Button {
                            selectedDef = def
                        } label: {
                            Text(def.name)
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }
            .navigationTitle("Add Exercise")
            .searchable(text: $searchText, prompt: "Filter exercises")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("New Exercise…") { showingNewExerciseSheet = true }
                }
            }
            .sheet(isPresented: $showingNewExerciseSheet) {
                ExerciseEditView(def: nil, bars: bars) { newDef in
                    onPick(newDef, newDef.repSchemes.first ?? [8, 8, 8], .fixedSets)
                    dismiss()
                }
            }
            .confirmationDialog(selectedDef?.name ?? "", isPresented: Binding(
                get: { selectedDef != nil },
                set: { if !$0 { selectedDef = nil } }), titleVisibility: .visible) {
                if let def = selectedDef {
                    ForEach(def.repSchemes, id: \.self) { reps in
                        Button(reps.map(String.init).joined(separator: "/")) {
                            onPick(def, reps, .fixedSets)
                            dismiss()
                        }
                    }
                    Button("Add New Set…") {
                        addSetTarget = def
                        selectedDef = nil
                    }
                    Button("Cancel", role: .cancel) { selectedDef = nil }
                }
            }
            .sheet(isPresented: Binding(get: { addSetTarget != nil }, set: { if !$0 { addSetTarget = nil } })) {
                if let def = addSetTarget {
                    AddSetSheet(exerciseName: def.name) { goalType, reps in
                        if case .fixedSets = goalType {
                            def.addRepScheme(reps)
                            try? context.save()
                        }
                        onPick(def, reps, goalType)
                        addSetTarget = nil
                        dismiss()
                    }
                }
            }
        }
    }
}

/// Add a new set to an exercise — either a fixed rep scheme (e.g.
/// "5/5/5/3/3/3") or, toggled on, a single rep-total target (e.g. "40") for
/// exercises like Pull-Up where the goal is a running total, not fixed sets.
struct AddSetSheet: View {
    @Environment(\.dismiss) private var dismiss
    let exerciseName: String
    /// `reps` is only meaningful for `.fixedSets` — empty for `.repTotal`.
    var onAdd: (GoalType, [Int]) -> Void

    @State private var isRepTotal = false
    @State private var repsText = ""
    @State private var targetText = ""

    private var reps: [Int] {
        repsText.split(separator: "/").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }
    private var target: Int? { Int(targetText) }
    private var canAdd: Bool { isRepTotal ? (target ?? 0) > 0 : !reps.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Goal", selection: $isRepTotal) {
                        Text("Fixed Sets").tag(false)
                        Text("Rep Total").tag(true)
                    }
                    .pickerStyle(.segmented)

                    if isRepTotal {
                        TextField("Target reps e.g. 40", text: $targetText)
                            .keyboardType(.numberPad)
                    } else {
                        TextField("Reps e.g. 5/5/5/3/3/3", text: $repsText)
                            .keyboardType(.numbersAndPunctuation)
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }
            .navigationTitle("Add a Set to \(exerciseName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        if isRepTotal {
                            guard let target, target > 0 else { return }
                            onAdd(.repTotal(target: target), [])
                        } else {
                            guard !reps.isEmpty else { return }
                            onAdd(.fixedSets, reps)
                        }
                    }
                    .disabled(!canAdd)
                }
            }
        }
    }
}

struct DraftExerciseRow: View {
    @Binding var item: PhaseBuilderView.DraftExercise

    private var isRepTotal: Bool {
        if case .repTotal = item.goalType { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Exercise name", text: $item.name)
                .font(.headline)

            // Goal kind (Fixed Sets vs. Rep Total) is set once on the
            // exercise itself, in the Exercises tab — this row just shows
            // whichever field that kind needs.
            if isRepTotal {
                HStack {
                    Text("Target reps").font(.subheadline)
                    TextField("e.g. 40", text: $item.repTotalTargetText)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .onChange(of: item.repTotalTargetText) { _, new in
                            item.goalType = .repTotal(target: Int(new) ?? 0)
                        }
                }
                Toggle("AI progresses rep total instead of weight", isOn: $item.repTotalProgressesReps)
                    .font(.caption)
            } else {
                TextField("Reps e.g. 5/5/5/3/3/3", text: $item.repsText)
                    .font(.system(.caption, design: .monospaced))
                    .keyboardType(.numbersAndPunctuation)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Built-in exercise library (used to seed the Exercises tab on first launch)

enum ExerciseLibrary {
    struct Entry { let name: String; let defaultReps: String; var isBodyweight: Bool = false }
    struct Group { let group: String; let exercises: [Entry] }

    static let grouped: [Group] = [
        Group(group: "Chest / Push", exercises: [
            Entry(name: "Bench Press", defaultReps: "5/5/5/3/3/3"),
            Entry(name: "Incline DB Press", defaultReps: "8/8/8/8"),
            Entry(name: "Overhead Press", defaultReps: "5/5/5/5"),
            Entry(name: "Dips", defaultReps: "10/10/10", isBodyweight: true),
            Entry(name: "Cable Fly", defaultReps: "12/12/12"),
            Entry(name: "Lateral Raise", defaultReps: "15/15/15"),
            Entry(name: "Triceps Pushdown", defaultReps: "12/12/12"),
            Entry(name: "Skullcrusher (EZ Bar)", defaultReps: "10/10/10"),
        ]),
        Group(group: "Back / Pull", exercises: [
            Entry(name: "Deadlift", defaultReps: "5/5/3/3"),
            Entry(name: "Barbell Row", defaultReps: "8/8/8/8"),
            Entry(name: "Seal Row", defaultReps: "8/8/8/8"),
            Entry(name: "Pull-Up", defaultReps: "8/8/8", isBodyweight: true),
            Entry(name: "Lat Pulldown", defaultReps: "10/10/10"),
            Entry(name: "Face Pull", defaultReps: "15/15/15"),
            Entry(name: "Band Pull-Apart", defaultReps: "20/20/20"),
            Entry(name: "EZ Bar Curl", defaultReps: "10/10/10"),
            Entry(name: "Hammer Curl", defaultReps: "12/12/12"),
        ]),
        Group(group: "Legs", exercises: [
            Entry(name: "Back Squat", defaultReps: "5/5/5/3/3"),
            Entry(name: "Front Squat", defaultReps: "6/6/6"),
            Entry(name: "Romanian Deadlift", defaultReps: "8/8/8"),
            Entry(name: "Leg Press", defaultReps: "10/10/10/10"),
            Entry(name: "Bulgarian Split Squat", defaultReps: "10/10/10"),
            Entry(name: "Leg Curl", defaultReps: "12/12/12"),
            Entry(name: "Leg Extension", defaultReps: "12/12/12"),
            Entry(name: "Calf Raise", defaultReps: "15/15/15/15"),
        ]),
    ]
}
