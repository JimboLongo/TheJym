//
//  PhaseSetupView.swift
//  TheJym
//
//  Create a Phase: split pattern (PPLRPPLR), number of cycles, and the
//  exercise plan (with target sets/reps) for each training day letter.
//

import SwiftUI
import SwiftData

struct PhaseSetupView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Phase.number, order: .reverse) private var phases: [Phase]
    @Query private var settingsList: [AppSettings]
    @Query(sort: \ExerciseDef.name) private var exerciseDefs: [ExerciseDef]

    /// If non-nil, seed the plan from an AI-planned or previous phase.
    var previousPhase: Phase?
    var seededPlan: [String: [ProgressionEngine.PlannedSlot]]? = nil

    @State private var pattern = "PPLRPPLR"
    @State private var cycles = 8
    @State private var draftPlan: [String: [DraftExercise]] = [:]

    struct DraftExercise: Identifiable {
        let id = UUID()
        var name: String
        var repsText: String        // "5/5/5/3/3/3"
        var weightsText: String     // optional "135/135/135/145/145/145"
        var isLowerBody: Bool
    }

    private var trainingLetters: [String] {
        Phase.distinctTrainingLetters(for: pattern.uppercased())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Split & Length") {
                    TextField("Pattern (R = rest)", text: $pattern)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                    Stepper("Cycles: \(cycles)", value: $cycles, in: 1...20)
                    if settingsList.first?.deloadWeeksEnabled == true {
                        let dc = ProgressionEngine.deloadCycle(totalCycles: cycles)
                        if dc > 0 {
                            Label("AI will make cycle \(dc) a deload cycle (~60% loads) so you start the next phase recovered.",
                                  systemImage: "arrow.down.heart")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }

                ForEach(trainingLetters, id: \.self) { letter in
                    Section("Day \(letter) Exercises") {
                        let items = draftPlan[letter] ?? []
                        ForEach(items) { ex in
                            DraftExerciseRow(letter: letter, item: binding(for: letter, id: ex.id))
                        }
                        .onDelete { idx in
                            draftPlan[letter]?.remove(atOffsets: idx)
                        }
                        Menu("Add Exercise") {
                            ForEach(exerciseDefs, id: \.persistentModelID) { def in
                                Button(def.name) {
                                    draftPlan[letter, default: []].append(
                                        DraftExercise(name: def.name,
                                                      repsText: def.targetReps.map(String.init).joined(separator: "/"),
                                                      weightsText: "",
                                                      isLowerBody: def.isLowerBody))
                                }
                            }
                            Button("Custom…") {
                                draftPlan[letter, default: []].append(
                                    DraftExercise(name: "New Exercise", repsText: "8/8/8",
                                                  weightsText: "", isLowerBody: false))
                            }
                        }
                    }
                }
            }
            .navigationTitle(previousPhase == nil && phases.isEmpty ? "Phase 1 Setup" : "New Phase")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start Phase") { save() }
                        .disabled(trainingLetters.isEmpty || draftPlan.values.allSatisfy(\.isEmpty))
                }
            }
            .onAppear(perform: seed)
        }
    }

    private func binding(for letter: String, id: UUID) -> Binding<DraftExercise> {
        Binding(
            get: { draftPlan[letter]?.first(where: { $0.id == id })
                   ?? DraftExercise(name: "", repsText: "", weightsText: "", isLowerBody: false) },
            set: { newValue in
                if let i = draftPlan[letter]?.firstIndex(where: { $0.id == id }) {
                    draftPlan[letter]?[i] = newValue
                }
            })
    }

    private func seed() {
        guard draftPlan.isEmpty else { return }
        if let seeded = seededPlan {
            for (letter, slots) in seeded {
                draftPlan[letter] = slots.map {
                    DraftExercise(name: $0.exerciseName,
                                  repsText: $0.targetReps.map(String.init).joined(separator: "/"),
                                  weightsText: $0.startingWeights.map { Formatters.trim($0) }.joined(separator: "/"),
                                  isLowerBody: $0.isLowerBody)
                }
            }
            if let prev = previousPhase {
                pattern = prev.splitPattern
                cycles = prev.totalCycles
            }
        }
    }

    private func save() {
        let nextNumber = (phases.map(\.number).max() ?? 0) + 1
        // Deactivate old phases
        for p in phases { p.isActive = false }

        let deload = (settingsList.first?.deloadWeeksEnabled == true)
            ? ProgressionEngine.deloadCycle(totalCycles: cycles) : 0

        let phase = Phase(number: nextNumber, splitPattern: pattern,
                          totalCycles: cycles, deloadCycle: deload)
        context.insert(phase)

        var knownNames = Set(exerciseDefs.map(\.name))
        for letter in trainingLetters {
            for (i, d) in (draftPlan[letter] ?? []).enumerated() {
                let reps = d.repsText.split(separator: "/").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                let weights = d.weightsText.split(separator: "/").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                guard !reps.isEmpty else { continue }
                let pe = PlannedExercise(dayLetter: letter, order: i,
                                         exerciseName: d.name,
                                         targetReps: reps,
                                         suggestedWeights: weights,
                                         isLowerBody: d.isLowerBody)
                pe.phase = phase
                context.insert(pe)

                // Keep the Exercises library in sync with anything typed here for the first time.
                if !knownNames.contains(d.name) {
                    context.insert(ExerciseDef(name: d.name, targetReps: reps, isLowerBody: d.isLowerBody))
                    knownNames.insert(d.name)
                }
            }
        }
        try? context.save()
        dismiss()
    }
}

struct DraftExerciseRow: View {
    let letter: String
    @Binding var item: PhaseSetupView.DraftExercise

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

// MARK: - Built-in exercise library (edit freely)

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
