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
                        if day.isRest {
                            Text("Rest").foregroundStyle(.secondary)
                        } else {
                            NavigationLink {
                                PhaseDayEditView(day: day, exerciseDefs: exerciseDefs, bars: bars)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(day.name).font(.headline)
                                    Text("\(day.plannedExercises.count) exercise\(day.plannedExercises.count == 1 ? "" : "s")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .onDelete(perform: deleteDays)
                    .onMove(perform: moveDays)

                    Button("Add Training Day…") { showingNewDayAlert = true }
                    Button("Add Rest Day") { addDay(name: "Rest", isRest: true) }
                } header: {
                    Text("One Cycle")
                } footer: {
                    Text("Deleting a day here doesn't delete workouts you've already logged for it — they stay in History without a day attached.")
                }
            }
            .navigationTitle("Edit Phase \(phase.number)")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { try? context.save(); dismiss() }
                }
                ToolbarItem(placement: .navigation) { EditButton() }
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

    private func deleteDays(at offsets: IndexSet) {
        let ordered = phase.orderedDays
        for i in offsets { context.delete(ordered[i]) }
        renumber()
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

    @State private var showingNewExerciseSheet = false
    @State private var prefilledName: String?

    private var groupedExerciseDefs: [(name: String, variants: [ExerciseDef])] {
        ExerciseDef.grouped(exerciseDefs)
    }
    private var sortedExercises: [PlannedExercise] {
        day.plannedExercises.sorted { $0.order < $1.order }
    }

    var body: some View {
        Form {
            Section("Day Name") {
                TextField("Day name", text: $day.name)
            }
            Section("Exercises") {
                ForEach(sortedExercises, id: \.persistentModelID) { pe in
                    PlannedExerciseRow(pe: pe)
                }
                .onDelete { idx in
                    let sorted = sortedExercises
                    for i in idx { context.delete(sorted[i]) }
                }
                Menu("Add Exercise") {
                    ForEach(groupedExerciseDefs, id: \.name) { group in
                        Menu(group.name) {
                            ForEach(group.variants, id: \.persistentModelID) { def in
                                Button(def.targetReps.map(String.init).joined(separator: "/")) {
                                    addExercise(def)
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
        }
        .navigationTitle(day.name)
        .sheet(isPresented: $showingNewExerciseSheet) {
            ExerciseEditView(def: nil, bars: bars, prefilledName: prefilledName) { newDef in
                addExercise(newDef)
            }
        }
    }

    private func addExercise(_ def: ExerciseDef) {
        let pe = PlannedExercise(order: day.plannedExercises.count, exerciseName: def.name,
                                 targetReps: def.targetReps, isLowerBody: def.isLowerBody)
        pe.day = day
        context.insert(pe)
    }
}

struct PlannedExerciseRow: View {
    @Bindable var pe: PlannedExercise

    @State private var repsText = ""
    @State private var weightsText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Exercise name", text: $pe.exerciseName)
                .font(.headline)
            HStack {
                TextField("Reps e.g. 5/5/5/3/3/3", text: $repsText)
                    .font(.system(.caption, design: .monospaced))
                    .keyboardType(.numbersAndPunctuation)
                    .onChange(of: repsText) { _, new in
                        pe.targetReps = new.split(separator: "/").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                    }
                Toggle("Lower", isOn: $pe.isLowerBody)
                    .toggleStyle(.button)
                    .font(.caption2)
            }
            TextField("Start weights (optional) e.g. 135/135/135/145/145/145", text: $weightsText)
                .font(.system(.caption, design: .monospaced))
                .keyboardType(.numbersAndPunctuation)
                .onChange(of: weightsText) { _, new in
                    pe.suggestedWeights = new.split(separator: "/").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                }
        }
        .padding(.vertical, 2)
        .onAppear {
            repsText = pe.targetReps.map(String.init).joined(separator: "/")
            weightsText = pe.suggestedWeights.map { Formatters.trim($0) }.joined(separator: "/")
        }
    }
}
