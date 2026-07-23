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
                                    Spacer()
                                    NavigationLink {
                                        PhaseDayEditView(day: day, exerciseDefs: exerciseDefs, bars: bars)
                                    } label: {
                                        Text("\(day.plannedExercises.count) exercise\(day.plannedExercises.count == 1 ? "" : "s")")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    .fixedSize()
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
        day.plannedExercises.sorted { $0.order < $1.order }
    }

    var body: some View {
        Form {
            Section("Exercises") {
                ForEach(sortedExercises, id: \.persistentModelID) { pe in
                    PlannedExerciseRow(pe: pe)
                }
                .onDelete { idx in
                    let sorted = sortedExercises
                    for i in idx { context.delete(sorted[i]) }
                }
                Button("Add Exercise") { showingAddExercise = true }
            }
        }
        .navigationTitle(day.name)
        .sheet(isPresented: $showingAddExercise) {
            AddExerciseToDayView(exerciseDefs: exerciseDefs, bars: bars) { def, reps in
                addExercise(def, reps: reps)
            }
        }
    }

    private func addExercise(_ def: ExerciseDef, reps: [Int]) {
        let pe = PlannedExercise(order: day.plannedExercises.count, exerciseName: def.name,
                                 targetReps: reps, isLowerBody: def.isLowerBody)
        pe.day = day
        context.insert(pe)
    }
}

struct PlannedExerciseRow: View {
    @Bindable var pe: PlannedExercise

    @State private var repsText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Exercise name", text: $pe.exerciseName)
                .font(.headline)
            TextField("Reps e.g. 5/5/5/3/3/3", text: $repsText)
                .font(.system(.caption, design: .monospaced))
                .keyboardType(.numbersAndPunctuation)
                .onChange(of: repsText) { _, new in
                    pe.targetReps = new.split(separator: "/").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                }
        }
        .padding(.vertical, 2)
        .onAppear {
            repsText = pe.targetReps.map(String.init).joined(separator: "/")
        }
    }
}
