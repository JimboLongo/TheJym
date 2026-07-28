//
//  QuickWorkoutBuilderView.swift
//  TheJym
//
//  Create or edit a standalone, reusable workout template ("Upper Day",
//  "Full Body", ...) that lives outside any Phase — a PhaseDay with no
//  parent Phase. Reuses the same exercise-adding flow as Phase Builder
//  (AddExerciseToDayView, DraftExercise, DraftExerciseRow).
//

import SwiftUI
import SwiftData

struct QuickWorkoutBuilderView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ExerciseDef.name) private var exerciseDefs: [ExerciseDef]
    @Query(sort: \Bar.name) private var bars: [Bar]

    /// Non-nil when editing an existing standalone workout.
    var existingDay: PhaseDay?

    @State private var name: String
    @State private var exercises: [PhaseBuilderView.DraftExercise]
    @State private var showingAddExercise = false

    init(existingDay: PhaseDay? = nil) {
        self.existingDay = existingDay
        _name = State(initialValue: existingDay?.name ?? "")
        let sortedExisting = existingDay?.plannedExercises.sorted { $0.order < $1.order } ?? []
        _exercises = State(initialValue: sortedExisting.map { pe in
            PhaseBuilderView.DraftExercise(
                name: pe.exerciseName,
                repsText: pe.targetReps.map(String.init).joined(separator: "/"),
                weightsText: pe.suggestedWeights.map { Formatters.trim($0) }.joined(separator: "/"))
        })
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !exercises.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Workout name e.g. Upper Day", text: $name)
                }
                Section("Exercises") {
                    ForEach($exercises) { $item in
                        DraftExerciseRow(item: $item)
                    }
                    .onDelete { idx in exercises.remove(atOffsets: idx) }
                    Button {
                        showingAddExercise = true
                    } label: {
                        Text("Add Exercise").frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
            .navigationTitle(existingDay == nil ? "New Workout" : "Edit Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
            .sheet(isPresented: $showingAddExercise) {
                AddExerciseToDayView(exerciseDefs: exerciseDefs, bars: bars) { def, reps in
                    exercises.append(PhaseBuilderView.DraftExercise(
                        name: def.name,
                        repsText: reps.map(String.init).joined(separator: "/"),
                        weightsText: ""))
                }
            }
        }
    }

    private func save() {
        let day = existingDay ?? PhaseDay(order: 0, name: name, isRest: false)
        day.name = name
        if existingDay == nil {
            context.insert(day)
        } else {
            for pe in day.plannedExercises { context.delete(pe) }
        }

        var knownDefs = Dictionary(uniqueKeysWithValues: exerciseDefs.map { ($0.name, $0) })
        for (i, d) in exercises.enumerated() {
            let reps = d.repsText.split(separator: "/").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            let weights = d.weightsText.split(separator: "/").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard !reps.isEmpty else { continue }
            let pe = PlannedExercise(order: i, exerciseName: d.name, targetReps: reps, suggestedWeights: weights)
            pe.day = day
            context.insert(pe)
            ExerciseDef.ensureVariantExists(name: d.name, targetReps: reps, knownDefs: &knownDefs, context: context)
        }
        try? context.save()
        dismiss()
    }
}
