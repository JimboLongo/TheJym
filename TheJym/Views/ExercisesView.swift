//
//  ExercisesView.swift
//  TheJym
//
//  A persistent, user-managed exercise library: add exercises, tag their
//  equipment, jot notes, and pull up each one's full logged history
//  (most recent first) — independent of any Phase.
//

import SwiftUI
import SwiftData

struct ExercisesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ExerciseDef.name) private var exerciseDefs: [ExerciseDef]
    @Query(sort: \Bar.name) private var bars: [Bar]
    @Query private var allLogs: [ExerciseLog]

    @State private var showingAdd = false

    var body: some View {
        NavigationStack {
            List {
                if exerciseDefs.isEmpty {
                    ContentUnavailableView {
                        Label("No Exercises Yet", systemImage: "figure.strengthtraining.traditional")
                    } description: {
                        Text("Add exercises here, tag their equipment, and jot notes. They'll show up when building a Phase.")
                    } actions: {
                        Button("Add Exercise") { showingAdd = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
                ForEach(exerciseDefs, id: \.persistentModelID) { def in
                    NavigationLink {
                        ExerciseDetailView(def: def, bars: bars, allLogs: allLogs)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(def.name).font(.headline)
                                Spacer()
                                if let eq = def.equipment {
                                    Text(eq.name).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Text(def.targetReps.map(String.init).joined(separator: "/"))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { idx in
                    for i in idx { context.delete(exerciseDefs[i]) }
                    try? context.save()
                }
            }
            .navigationTitle("Exercises")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingAdd = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showingAdd) {
                ExerciseEditView(def: nil, bars: bars)
            }
        }
    }
}

struct ExerciseEditView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    /// nil = creating a new exercise; otherwise editing this one in place.
    let def: ExerciseDef?
    let bars: [Bar]

    @State private var name = ""
    @State private var repsText = "8/8/8"
    @State private var isLowerBody = false
    @State private var notes = ""
    @State private var equipmentID: PersistentIdentifier?

    private var reps: [Int] {
        repsText.split(separator: "/").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Exercise name", text: $name)
                    TextField("Reps e.g. 5/5/5/3/3/3", text: $repsText)
                        .keyboardType(.numbersAndPunctuation)
                        .font(.system(.body, design: .monospaced))
                    Toggle("Lower Body", isOn: $isLowerBody)
                }
                Section("Equipment") {
                    Picker("Equipment", selection: $equipmentID) {
                        Text("None").tag(Optional<PersistentIdentifier>.none)
                        ForEach(bars, id: \.persistentModelID) { bar in
                            Text(bar.isDumbbell ? bar.name : "\(bar.name) (\(Formatters.trim(bar.weight)) lbs)")
                                .tag(Optional(bar.persistentModelID))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.inline)
                }
                Section("Notes") {
                    TextField("Form cues, setup tips, etc.", text: $notes, axis: .vertical)
                        .lineLimit(1...4)
                }
            }
            .navigationTitle(def == nil ? "Add Exercise" : "Edit Exercise")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || reps.isEmpty)
                }
            }
            .onAppear {
                guard let def else { return }
                name = def.name
                repsText = def.targetReps.map(String.init).joined(separator: "/")
                isLowerBody = def.isLowerBody
                notes = def.notes
                equipmentID = def.equipment?.persistentModelID
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty, !reps.isEmpty else { return }
        let equipment = bars.first { $0.persistentModelID == equipmentID }
        if let def {
            def.name = trimmedName
            def.targetReps = reps
            def.isLowerBody = isLowerBody
            def.notes = notes
            def.equipment = equipment
        } else {
            context.insert(ExerciseDef(name: trimmedName, targetReps: reps, isLowerBody: isLowerBody,
                                       notes: notes, equipment: equipment))
        }
        try? context.save()
        dismiss()
    }
}

struct ExerciseDetailView: View {
    let def: ExerciseDef
    let bars: [Bar]
    let allLogs: [ExerciseLog]

    @State private var showingEdit = false

    private var history: [ExerciseLog] {
        allLogs
            .filter { $0.exerciseName == def.name && !$0.sets.isEmpty }
            .sorted { ($0.session?.date ?? .distantPast) > ($1.session?.date ?? .distantPast) }
    }

    var body: some View {
        List {
            if !def.notes.isEmpty || def.equipment != nil {
                Section("Details") {
                    if let eq = def.equipment {
                        LabeledContent("Equipment", value: eq.name)
                    }
                    if !def.notes.isEmpty {
                        Text(def.notes).font(.subheadline)
                    }
                }
            }

            if history.isEmpty {
                ContentUnavailableView("No History Yet", systemImage: "clock",
                                       description: Text("Log this exercise in a workout and it'll show up here."))
            } else {
                ForEach(history, id: \.persistentModelID) { log in
                    Section(Formatters.date.string(from: log.session?.date ?? .distantPast)) {
                        ForEach(log.sortedSets, id: \.persistentModelID) { s in
                            LabeledContent("Set \(s.index + 1)",
                                           value: "\(Formatters.trim(s.weight)) lbs × \(s.reps) reps")
                                .font(.system(.subheadline, design: .monospaced))
                        }
                        LabeledContent("Total") {
                            Text("\(Formatters.trim(log.totalWeightMoved)) lbs").bold()
                        }
                    }
                }
            }
        }
        .navigationTitle(def.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { showingEdit = true }
            }
        }
        .sheet(isPresented: $showingEdit) {
            ExerciseEditView(def: def, bars: bars)
        }
    }
}
