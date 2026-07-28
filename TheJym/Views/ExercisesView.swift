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
    @Environment(\.editMode) private var editMode
    @Query(sort: \ExerciseDef.name) private var exerciseDefs: [ExerciseDef]
    @Query(sort: \Bar.name) private var bars: [Bar]
    @Query private var allLogs: [ExerciseLog]

    @State private var showingAdd = false
    @State private var selectedDef: ExerciseDef?
    @State private var editTarget: ExerciseDef?
    @State private var addSetTarget: ExerciseDef?
    @State private var newSetReps = ""
    @State private var historyTarget: SetHistoryTarget?
    @State private var selectedIDs: Set<PersistentIdentifier> = []
    @State private var showingBulkDeleteConfirm = false
    @State private var showingLibraryPicker = false
    @State private var searchText = ""

    private var isEditing: Bool { editMode?.wrappedValue == .active }

    private var filteredDefs: [ExerciseDef] {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return exerciseDefs }
        return exerciseDefs.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

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
                        Button("Browse Exercise Library…") { showingLibraryPicker = true }
                    }
                } else if filteredDefs.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
                ForEach(filteredDefs, id: \.persistentModelID) { def in
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
                    for i in idx { context.delete(filteredDefs[i]) }
                    try? context.save()
                }
            }
            .navigationTitle("Exercises")
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search exercises")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarLeading) {
                    if !exerciseDefs.isEmpty { EditButton() }
                    if isEditing {
                        Button(selectedIDs.count == exerciseDefs.count ? "Deselect All" : "Select All") {
                            if selectedIDs.count == exerciseDefs.count {
                                selectedIDs = []
                            } else {
                                selectedIDs = Set(exerciseDefs.map(\.persistentModelID))
                            }
                        }
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if isEditing {
                        Button("Delete (\(selectedIDs.count))", role: .destructive) {
                            showingBulkDeleteConfirm = true
                        }
                        .disabled(selectedIDs.isEmpty)
                    }
                    Menu {
                        Button("New Exercise…", systemImage: "plus") { showingAdd = true }
                        Button("Browse Exercise Library…", systemImage: "books.vertical") { showingLibraryPicker = true }
                    } label: {
                        Image(systemName: "plus")
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
            .sheet(isPresented: $showingLibraryPicker) {
                ExerciseLibraryPickerView()
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
        editMode?.wrappedValue = .inactive
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
    @State private var isBodyweight = false
    @State private var isRepTotal = false
    @State private var repTotalTargetText = ""

    private var reps: [Int] {
        repsText.split(separator: "/").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }
    private var repTotalTarget: Int? { Int(repTotalTargetText) }

    /// Only relevant when creating new — editing in place can't collide with itself.
    private var isDuplicateName: Bool {
        guard def == nil else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return allDefs.contains { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }
    }

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, !isDuplicateName else { return false }
        guard def == nil else { return true }
        return isRepTotal ? (repTotalTarget ?? 0) > 0 : !reps.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Exercise name", text: $name)
                    Picker("Goal", selection: $isRepTotal) {
                        Text("Fixed Sets").tag(false)
                        Text("Rep Total").tag(true)
                    }
                    .pickerStyle(.segmented)

                    if isRepTotal {
                        TextField("Target reps e.g. 40", text: $repTotalTargetText)
                            .keyboardType(.numberPad)
                    } else if def == nil {
                        TextField("Starting set (reps) e.g. 5/5/5/3/3/3", text: $repsText)
                            .keyboardType(.numbersAndPunctuation)
                            .font(.system(.body, design: .monospaced))
                    }
                    if isDuplicateName {
                        Label("An exercise with this name already exists.", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Toggle("Bodyweight Exercise", isOn: $isBodyweight)
                } footer: {
                    if isRepTotal {
                        Text("This exercise is programmed as a running rep total (e.g. \"23/40\") wherever it's added to a Phase day, instead of a fixed number of sets.")
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
                        .disabled(!canSave)
                }
            }
            .onAppear {
                guard let def else { return }
                name = def.name
                notes = def.notes
                equipmentID = def.equipment?.persistentModelID
                isBodyweight = def.isBodyweight
                isRepTotal = def.isRepTotal
                if def.defaultRepTotalTarget > 0 { repTotalTargetText = String(def.defaultRepTotalTarget) }
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
            def.isBodyweight = isBodyweight
            def.isRepTotal = isRepTotal
            if let repTotalTarget, repTotalTarget > 0 { def.defaultRepTotalTarget = repTotalTarget }
            saved = def
            syncPlannedExercises(for: def)
        } else if isRepTotal {
            guard let repTotalTarget, repTotalTarget > 0 else { return }
            let newDef = ExerciseDef(name: trimmedName, notes: notes, equipment: equipment,
                                     isBodyweight: isBodyweight, isRepTotal: true,
                                     defaultRepTotalTarget: repTotalTarget)
            context.insert(newDef)
            saved = newDef
        } else {
            guard !reps.isEmpty else { return }
            let newDef = ExerciseDef(name: trimmedName, notes: notes, equipment: equipment,
                                     repSchemes: [reps], isBodyweight: isBodyweight)
            context.insert(newDef)
            saved = newDef
        }
        try? context.save()
        onSave?(saved)
        dismiss()
    }

    /// The Exercise page is the single source of truth for an exercise's
    /// goal kind and bodyweight-ness — changing either here should take
    /// effect wherever it's already planned into a Phase day, not just for
    /// future additions. Logged history is left untouched; it's a record of
    /// what actually happened, not a plan.
    private func syncPlannedExercises(for def: ExerciseDef) {
        let name = def.name
        guard let planned = try? context.fetch(FetchDescriptor<PlannedExercise>(
            predicate: #Predicate<PlannedExercise> { $0.exerciseName == name })) else { return }
        for pe in planned {
            pe.isBodyweight = def.isBodyweight
            if def.isRepTotal {
                pe.goalType = .repTotal(target: def.defaultRepTotalTarget > 0 ? def.defaultRepTotalTarget : 1)
                pe.targetReps = []
            } else if case .repTotal = pe.goalType {
                pe.goalType = .fixedSets
                if pe.targetReps.isEmpty { pe.targetReps = [8, 8, 8] }
            }
        }
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

/// Browse the built-in exercise catalog (the same one used to seed the
/// library on first launch) and add any you don't already have — handy for
/// starting fresh or finding a new exercise to try.
struct ExerciseLibraryPickerView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ExerciseDef.name) private var exerciseDefs: [ExerciseDef]

    private var existingNames: Set<String> { Set(exerciseDefs.map(\.name)) }

    var body: some View {
        NavigationStack {
            List {
                ForEach(ExerciseLibrary.grouped, id: \.group) { group in
                    Section(group.group) {
                        ForEach(group.exercises, id: \.name) { entry in
                            let alreadyAdded = existingNames.contains(entry.name)
                            Button {
                                addEntry(entry)
                            } label: {
                                HStack {
                                    Text(entry.name).foregroundStyle(.primary)
                                    Spacer()
                                    if alreadyAdded {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                    } else {
                                        Text(entry.defaultReps)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .disabled(alreadyAdded)
                        }
                    }
                }
            }
            .navigationTitle("Exercise Library")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func addEntry(_ entry: ExerciseLibrary.Entry) {
        guard !existingNames.contains(entry.name) else { return }
        let reps = entry.defaultReps.split(separator: "/").compactMap { Int($0) }
        context.insert(ExerciseDef(name: entry.name, repSchemes: reps.isEmpty ? [] : [reps]))
        try? context.save()
    }
}
