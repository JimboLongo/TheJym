//
//  PhaseEditView.swift
//  TheJym
//
//  Edit an existing Phase in place: rename/add/remove/reorder days, and
//  add/remove/edit exercises per day. Operates directly on the live
//  Phase/PhaseDay/PlannedExercise objects (not drafts), so days you don't
//  touch keep their identity — already-logged workouts stay correctly
//  attributed to them. Deleting a day or exercise never deletes logged
//  history; it just detaches from it (nullify, not cascade).
//

import SwiftUI
import SwiftData

struct PhaseEditView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var phase: Phase
    @Query(sort: \ExerciseDef.name) private var exerciseDefs: [ExerciseDef]
    @Query(sort: \Bar.name) private var bars: [Bar]

    @State private var newDayName = ""
    @State private var showingNewDayAlert = false
    @State private var editingDayID: PersistentIdentifier?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper("Cycles: \(phase.totalCycles)", value: $phase.totalCycles, in: 1...20)
                }

                Section {
                    ForEach(phase.orderedDays, id: \.persistentModelID) { day in
                        HStack(spacing: 10) {
                            if day.isRest {
                                Text("Rest").foregroundStyle(.secondary)
                            } else {
                                HStack {
                                    TextField("Day name", text: Binding(
                                        get: { day.name },
                                        set: { day.name = $0 }))
                                        .font(.headline)
                                        .fixedSize()
                                    Spacer()
                                    Button {
                                        editingDayID = day.persistentModelID
                                    } label: {
                                        Text("\(day.basePlannedExercises.count) exercise\(day.basePlannedExercises.count == 1 ? "" : "s")")
                                            .font(.subheadline.weight(.semibold))
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                context.delete(day)
                                renumber()
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .onMove(perform: moveDays)

                    Button("Add Training Day…") { showingNewDayAlert = true }
                    Button("Add Rest Day") { addDay(name: "Rest", isRest: true) }
                } header: {
                    Text("One Cycle")
                } footer: {
                    Text("Drag \(Image(systemName: "line.3.horizontal")) to reorder days, or swipe to delete one. Deleting a day doesn't delete workouts you've already logged for it, they stay in History without a day attached.")
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Edit Phase \(phase.number)")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { try? context.save(); dismiss() }
                }
            }
            .alert("New Training Day", isPresented: $showingNewDayAlert) {
                TextField("e.g. Pull A, Upper 1", text: $newDayName)
                Button("Add") {
                    let trimmed = newDayName.trimmingCharacters(in: .whitespaces)
                    newDayName = ""
                    guard !trimmed.isEmpty, trimmed.localizedCaseInsensitiveCompare("Rest") != .orderedSame else { return }
                    addDay(name: trimmed, isRest: false)
                }
                Button("Cancel", role: .cancel) { newDayName = "" }
            }
            .navigationDestination(item: $editingDayID) { id in
                if let day = phase.orderedDays.first(where: { $0.persistentModelID == id }) {
                    PhaseDayEditView(day: day, exerciseDefs: exerciseDefs, bars: bars)
                }
            }
        }
    }

    private func addDay(name: String, isRest: Bool) {
        let day = PhaseDay(order: phase.days.count, name: name, isRest: isRest)
        day.phase = phase
        context.insert(day)
    }

    private func moveDays(from source: IndexSet, to destination: Int) {
        var ordered = phase.orderedDays
        ordered.move(fromOffsets: source, toOffset: destination)
        for (i, d) in ordered.enumerated() { d.order = i }
    }

    private func renumber() {
        for (i, d) in phase.orderedDays.enumerated() { d.order = i }
    }
}

/// Edit one day's name and exercise list in place. Reuses ExerciseEditView so
/// anything added here syncs to the Exercises tab, same as the Phase Builder.
struct PhaseDayEditView: View {
    @Environment(\.modelContext) private var context
    @Bindable var day: PhaseDay
    let exerciseDefs: [ExerciseDef]
    let bars: [Bar]

    @State private var showingAddExercise = false

    private var sortedExercises: [PlannedExercise] {
        day.basePlannedExercises
    }

    var body: some View {
        Form {
            Section("Exercises") {
                ForEach(sortedExercises, id: \.persistentModelID) { pe in
                    PlannedExerciseRow(pe: pe, exerciseDefs: exerciseDefs)
                }
                .onDelete { idx in
                    let sorted = sortedExercises
                    for i in idx {
                        let slot = sorted[i]
                        // A deleted base slot leaves its own per-cycle
                        // overrides (see PlannedExercise.overriddenSlotID)
                        // with nothing left to override — drop them too
                        // rather than leaving orphaned rows behind.
                        for override in day.plannedExercises where override.overriddenSlotID == slot.slotID {
                            context.delete(override)
                        }
                        context.delete(slot)
                    }
                }
                Button {
                    showingAddExercise = true
                } label: {
                    Text("Add Exercise")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .navigationTitle(day.name)
        .sheet(isPresented: $showingAddExercise) {
            AddExerciseToDayView(exerciseDefs: exerciseDefs, bars: bars) { def, reps, goalType in
                addExercise(def, reps: reps, goalType: goalType)
            }
        }
    }

    private func addExercise(_ def: ExerciseDef, reps: [Int], goalType: GoalType) {
        let pe: PlannedExercise
        switch goalType {
        case .fixedSets:
            pe = PlannedExercise(order: day.basePlannedExercises.count, exerciseName: def.name,
                                 targetReps: reps, isBodyweight: def.isBodyweight)
        case .repTotal(let target):
            pe = PlannedExercise(order: day.basePlannedExercises.count, exerciseName: def.name,
                                 targetReps: [], isBodyweight: def.isBodyweight,
                                 goalType: .repTotal(target: target))
        }
        pe.day = day
        context.insert(pe)
    }
}

struct PlannedExerciseRow: View {
    @Environment(\.modelContext) private var context
    @Bindable var pe: PlannedExercise
    let exerciseDefs: [ExerciseDef]

    @State private var showingSetPicker = false
    @State private var showingAddSet = false

    private var def: ExerciseDef? {
        exerciseDefs.first { $0.name == pe.exerciseName }
    }

    private var isRepTotal: Bool {
        if case .repTotal = pe.goalType { return true }
        return false
    }

    /// What's currently planned — a rep scheme or a rep-total target,
    /// formatted the same as the sets picker's own options.
    private var planSummary: String {
        switch pe.goalType {
        case .fixedSets:
            return pe.targetReps.isEmpty ? "Choose a set…" : pe.targetReps.map(String.init).joined(separator: "/")
        case .repTotal(let target):
            return "\(target) total reps"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Exercise name", text: $pe.exerciseName)
                .font(.headline)

            // Tap to switch between this exercise's saved sets/rep-totals,
            // or add a new one — handled exactly like a normal set, just
            // based on a running total instead of a fixed scheme.
            Button {
                showingSetPicker = true
            } label: {
                HStack {
                    Text(planSummary)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            if isRepTotal {
                Toggle("AI progresses rep total instead of weight", isOn: $pe.repTotalProgressesReps)
                    .font(.caption)
            }
        }
        .padding(.vertical, 2)
        .confirmationDialog(pe.exerciseName, isPresented: $showingSetPicker, titleVisibility: .visible) {
            if let def {
                ForEach(def.repSchemes, id: \.self) { reps in
                    Button(reps.map(String.init).joined(separator: "/")) {
                        pe.targetReps = reps
                        pe.goalType = .fixedSets
                    }
                }
                ForEach(def.repTotalTargets, id: \.self) { target in
                    Button("\(target) total reps") {
                        pe.targetReps = []
                        pe.goalType = .repTotal(target: target)
                    }
                }
            }
            Button("Add New Set…") { showingAddSet = true }
            Button("Cancel", role: .cancel) { }
        }
        .sheet(isPresented: $showingAddSet) {
            AddSetSheet(exerciseName: pe.exerciseName) { goalType, reps in
                let targetDef: ExerciseDef
                if let def {
                    targetDef = def
                } else {
                    targetDef = ExerciseDef(name: pe.exerciseName, isBodyweight: pe.isBodyweight)
                    context.insert(targetDef)
                }
                switch goalType {
                case .fixedSets:
                    targetDef.addRepScheme(reps)
                    pe.targetReps = reps
                    pe.goalType = .fixedSets
                case .repTotal(let target):
                    targetDef.addRepTotalTarget(target)
                    pe.targetReps = []
                    pe.goalType = .repTotal(target: target)
                }
                try? context.save()
                showingAddSet = false
            }
        }
    }
}
