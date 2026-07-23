//
//  AddHistoricalWorkoutView.swift
//  TheJym
//
//  Manually back-fill a past workout — any date, any exercises/sets — not
//  tied to the active Phase's split or cycle count.
//

import SwiftUI
import SwiftData

struct AddHistoricalWorkoutView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var date = Date()
    @State private var exercises: [ExerciseDraft] = [ExerciseDraft()]

    struct SetDraft: Identifiable {
        let id = UUID()
        var weightText = ""
        var repsText = ""
    }

    struct ExerciseDraft: Identifiable {
        let id = UUID()
        var name = ""
        var sets: [SetDraft] = [SetDraft()]
    }

    private var canSave: Bool {
        exercises.contains { ex in
            !ex.name.trimmingCharacters(in: .whitespaces).isEmpty &&
            ex.sets.contains { Double($0.weightText) != nil && Int($0.repsText) != nil }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Date") {
                    DatePicker("Date", selection: $date, in: ...Date(), displayedComponents: .date)
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
                    Button("Add Exercise") { exercises.append(ExerciseDraft()) }
                }
            }
            .navigationTitle("Add Past Workout")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
        }
    }

    private func save() {
        var entries: [(name: String, sets: [SetDraft])] = []
        for ex in exercises {
            let name = ex.name.trimmingCharacters(in: .whitespaces)
            let validSets = ex.sets.filter { Double($0.weightText) != nil && Int($0.repsText) != nil }
            guard !name.isEmpty, !validSets.isEmpty else { continue }
            entries.append((name, validSets))
        }
        guard !entries.isEmpty else { return }

        let session = WorkoutSession(date: date, dayLetter: "Manual", cycleNumber: 0)
        context.insert(session)

        for (order, entry) in entries.enumerated() {
            let log = ExerciseLog(exerciseName: entry.name, targetReps: [], order: order)
            log.session = session
            context.insert(log)
            for (i, s) in entry.sets.enumerated() {
                let set = SetLog(index: i, weight: Double(s.weightText) ?? 0, reps: Int(s.repsText) ?? 0)
                set.exerciseLog = log
                context.insert(set)
            }
        }
        try? context.save()
        dismiss()
    }
}
