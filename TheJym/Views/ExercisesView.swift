//
//  ExercisesView.swift
//  TheJym
//
//  A persistent, user-managed exercise library, one row per exercise name.
//  Tapping an exercise pops up its saved sets (tap one to see logged history
//  for that exact exercise/set combo), plus options to add a new set or edit
//  its equipment/notes — no separate detail page to drill into first.
//

import SwiftUI
import SwiftData

struct ExercisesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ExerciseDef.name) private var exerciseDefs: [ExerciseDef]
    @Query(sort: \Bar.name) private var bars: [Bar]
    @Query private var allLogs: [ExerciseLog]

    @State private var showingAdd = false
    @State private var selectedDef: ExerciseDef?
    @State private var editTarget: ExerciseDef?
    @State private var addSetTarget: ExerciseDef?
    @State private var newSetReps = ""
    @State private var historyTarget: SetHistoryTarget?
    @State private var editMode: EditMode = .inactive
    @State private var selectedIDs: Set<PersistentIdentifier> = []
    @State private var showingBulkDeleteConfirm = false

    struct SetHistoryTarget: Hashable {
        let defID: PersistentIdentifier
        let reps: [Int]
    }

    var body: some View {
        NavigationStack {
            List(selection: $selectedIDs) {
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
                    Button {
                        selectedDef = def
                    } label: {
                        HStack {
                            Text(def.name).font(.headline)
                            Spacer()
                            if let eq = def.equipment {
                                Text(eq.name).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                }
                .onDelete { idx in
                    for i in idx { context.delete(exerciseDefs[i]) }
                    try? context.save()
                }
            }
            .environment(\.editMode, $editMode)
            .navigationTitle("Exercises")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if !exerciseDefs.isEmpty { EditButton() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if editMode == .active {
                        Button(selectedIDs.count == exerciseDefs.count ? "Deselect All" : "Select All") {
                            if selectedIDs.count == exerciseDefs.count {
                                selectedIDs = []
                            } else {
                                selectedIDs = Set(exerciseDefs.map(\.persistentModelID))
                            }
                        }
                    } else {
                        Button { showingAdd = true } label: { Image(systemName: "plus") }
                    }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    if editMode == .active {
                        Spacer()
                        Button("Delete (\(selectedIDs.count))", role: .destructive) {
                            showingBulkDeleteConfirm = true
                        }
                        .disabled(selectedIDs.isEmpty)
                    }
                }
            }
            .confirmationDialog("Delete \(selectedIDs.count) exercise\(selectedIDs.count == 1 ? "" : "s")? This also deletes their saved sets. Logged history stays intact.",
                                isPresented: $showingBulkDeleteConfirm, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { deleteSelected() }
                Button("Cancel", role: .cancel) { }
            }
            .sheet(isPresented: $showingAdd) {
                ExerciseEditView(def: nil, bars: bars)
            }
            .sheet(item: $editTarget) { def in
                ExerciseEditView(def: def, bars: bars)
            }
            .confirmationDialog(selectedDef?.name ?? "", isPresented: Binding(
                get: { selectedDef != nil },
                set: { if !$0 { selectedDef = nil } }), titleVisibility: .visible) {
                if let def = selectedDef {
                    ForEach(def.repSchemes, id: \.self) { reps in
                        Button(reps.map(String.init).joined(separator: "/")) {
                            historyTarget = SetHistoryTarget(defID: def.persistentModelID, reps: reps)
                            selectedDef = nil
                        }
                    }
                    Button("Add Set…") {
                        addSetTarget = def
                        selectedDef = nil
                    }
                    Button("Edit Equipment & Notes…") {
                        editTarget = def
                        selectedDef = nil
                    }
                    Button("Cancel", role: .cancel) { selectedDef = nil }
                }
            }
            .alert("Add a Set to \(addSetTarget?.name ?? "")",
                   isPresented: Binding(get: { addSetTarget != nil }, set: { if !$0 { addSetTarget = nil } })) {
                TextField("e.g. 5/5/5/3/3/3", text: $newSetReps)
                Button("Add") {
                    let reps = newSetReps.split(separator: "/").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                    newSetReps = ""
                    guard !reps.isEmpty, let def = addSetTarget else { addSetTarget = nil; return }
                    def.addRepScheme(reps)
                    try? context.save()
                    addSetTarget = nil
                }
                Button("Cancel", role: .cancel) { newSetReps = ""; addSetTarget = nil }
            }
            .navigationDestination(item: $historyTarget) { target in
                if let def = exerciseDefs.first(where: { $0.persistentModelID == target.defID }) {
                    ExerciseSetHistoryView(def: def, reps: target.reps, allLogs: allLogs)
                }
            }
        }
    }

    private func deleteSelected() {
        for def in exerciseDefs where selectedIDs.contains(def.persistentModelID) {
            context.delete(def)
        }
        try? context.save()
        selectedIDs = []
        editMode = .inactive
    }
}

/// Add a brand-new exercise (name + starting set + equipment/notes), or edit
/// an existing one's name/equipment/notes in place. Editing never touches
/// saved sets — those are managed from the sets popup on the Exercises list.
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
            def.notes = notes
            def.equipment = equipment
            saved = def
        } else {
            guard !reps.isEmpty else { return }
            let newDef = ExerciseDef(name: trimmedName,
                                     notes: notes, equipment: equipment, repSchemes: [reps])
            context.insert(newDef)
            saved = newDef
        }
        try? context.save()
        onSave?(saved)
        dismiss()
    }
}

/// History for one exact exercise/set combo, most recent first.
struct ExerciseSetHistoryView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) {
                    if let idx = def.repSchemes.firstIndex(of: reps) {
                        def.repSchemes.remove(at: idx)
                        try? context.save()
                    }
                    dismiss()
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
    }
}
