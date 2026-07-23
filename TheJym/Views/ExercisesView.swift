//
//  ExercisesView.swift
//  TheJym
//
//  A persistent, user-managed exercise library, one row per exercise name.
//  Tapping an exercise shows its equipment and notes (which apply regardless
//  of rep scheme) plus its list of saved sets below; tapping a set shows the
//  logged history for that exact exercise/set combo.
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
                        HStack {
                            Text(def.name).font(.headline)
                            Spacer()
                            if let eq = def.equipment {
                                Text(eq.name).font(.caption).foregroundStyle(.secondary)
                            }
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

/// Add a brand-new exercise (name + starting set + equipment/notes), or edit
/// an existing one's name/equipment/notes in place. Editing never touches
/// saved sets — those are managed from ExerciseDetailView.
struct ExerciseEditView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ExerciseDef.name) private var allDefs: [ExerciseDef]

    /// nil = creating a new exercise; otherwise editing this one in place.
    let def: ExerciseDef?
    let bars: [Bar]
    /// Called with the created/edited definition right before dismissing.
    var onSave: ((ExerciseDef) -> Void)? = nil

    @State private var name = ""
    @State private var repsText = "8/8/8"
    @State private var isLowerBody = false
    @State private var notes = ""
    @State private var equipmentID: PersistentIdentifier?

    private var reps: [Int] {
        repsText.split(separator: "/").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Only relevant when creating new — editing in place can't collide with itself.
    private var isDuplicateName: Bool {
        guard def == nil else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return allDefs.contains { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Exercise name", text: $name)
                    if def == nil {
                        TextField("Starting set (reps) e.g. 5/5/5/3/3/3", text: $repsText)
                            .keyboardType(.numbersAndPunctuation)
                            .font(.system(.body, design: .monospaced))
                    }
                    Toggle("Lower Body", isOn: $isLowerBody)
                    if isDuplicateName {
                        Label("An exercise with this name already exists.", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
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
            .navigationTitle(def == nil ? "New Exercise" : "Edit Exercise")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                                  || (def == nil && reps.isEmpty) || isDuplicateName)
                }
            }
            .onAppear {
                guard let def else { return }
                name = def.name
                isLowerBody = def.isLowerBody
                notes = def.notes
                equipmentID = def.equipment?.persistentModelID
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty, !isDuplicateName else { return }
        let equipment = bars.first { $0.persistentModelID == equipmentID }
        let saved: ExerciseDef
        if let def {
            def.name = trimmedName
            def.isLowerBody = isLowerBody
            def.notes = notes
            def.equipment = equipment
            saved = def
        } else {
            guard !reps.isEmpty else { return }
            let newDef = ExerciseDef(name: trimmedName, isLowerBody: isLowerBody,
                                     notes: notes, equipment: equipment, repSchemes: [reps])
            context.insert(newDef)
            saved = newDef
        }
        try? context.save()
        onSave?(saved)
        dismiss()
    }
}

struct ExerciseDetailView: View {
    @Environment(\.modelContext) private var context
    let def: ExerciseDef
    let bars: [Bar]
    let allLogs: [ExerciseLog]

    @State private var showingEdit = false
    @State private var showingAddSet = false
    @State private var newSetReps = ""

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

            Section("Saved Sets") {
                if def.repSchemes.isEmpty {
                    Text("No sets saved yet.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(def.repSchemes, id: \.self) { reps in
                        NavigationLink {
                            ExerciseSetHistoryView(def: def, reps: reps, allLogs: allLogs)
                        } label: {
                            Text(reps.map(String.init).joined(separator: "/"))
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                    .onDelete { idx in
                        def.repSchemes.remove(atOffsets: idx)
                        try? context.save()
                    }
                }
                Button("Add Set…") { showingAddSet = true }
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
        .alert("Add a Set", isPresented: $showingAddSet) {
            TextField("e.g. 5/5/5/3/3/3", text: $newSetReps)
            Button("Add") {
                let reps = newSetReps.split(separator: "/").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                newSetReps = ""
                def.addRepScheme(reps)
                try? context.save()
            }
            Button("Cancel", role: .cancel) { newSetReps = "" }
        }
    }
}

/// History for one exact exercise/set combo, most recent first.
struct ExerciseSetHistoryView: View {
    let def: ExerciseDef
    let reps: [Int]
    let allLogs: [ExerciseLog]

    private var history: [ExerciseLog] {
        allLogs
            .filter { $0.exerciseName == def.name && $0.targetReps == reps && !$0.sets.isEmpty }
            .sorted { ($0.session?.date ?? .distantPast) > ($1.session?.date ?? .distantPast) }
    }

    var body: some View {
        List {
            if history.isEmpty {
                ContentUnavailableView("No History Yet", systemImage: "clock",
                                       description: Text("Log this set in a workout and it'll show up here."))
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
        .navigationTitle(reps.map(String.init).joined(separator: "/"))
    }
}
