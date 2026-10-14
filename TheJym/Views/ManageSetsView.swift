//
//  ManageSetsView.swift
//  TheJym
//
//  One screen for editing an exercise's saved sets and their rep ceilings,
//  reached as "Manage Sets…" from every set picker.
//
//  Why a screen rather than a long-press on the picker rows: those pickers
//  are .confirmationDialog, whose buttons the system renders natively, so a
//  .contextMenu cannot attach to them — delivering long-press would have
//  meant converting three working action sheets into sheets. A visible row
//  also has an affordance a long-press doesn't, and setting a ceiling is a
//  deliberate, occasional act rather than something done mid-flow.
//
//  Laid out for the state this app is actually in: 193 saved sets across
//  100 exercises and ZERO ceilings configured. The common path is therefore
//  "configure several in a row", not "fix one", so every row states its
//  ceiling without being opened and the header counts how many are still
//  unset. Tapping a row goes straight to the ceiling editor, which is the
//  thing being done repeatedly; changing the reps themselves is the rarer,
//  more destructive act and sits behind the menu.
//

import SwiftUI
import SwiftData

struct ManageSetsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let def: ExerciseDef

    @Query private var allPlannedExercises: [PlannedExercise]
    @Query private var allLogs: [ExerciseLog]

    @State private var ceilingTarget: [Int]?
    @State private var editTarget: [Int]?
    @State private var addingSet = false
    @State private var pendingConfirmation: PendingConfirmation?

    /// An action held back until confirmed, carrying the text that explains
    /// its scope. `apply` is the committed change, so the confirmation and
    /// the thing it describes can't drift apart.
    private struct PendingConfirmation: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let actionLabel: String
        let isDestructive: Bool
        let apply: () -> Void
    }

    private var ceilingCount: Int {
        def.repSchemes.filter { def.ceiling(for: $0) != nil }.count
    }

    private func impact(_ reps: [Int]) -> RepSchemeImpact {
        RepSchemeImpact.compute(def: def, reps: reps,
                                plannedExercises: allPlannedExercises, logs: allLogs)
    }

    var body: some View {
        NavigationStack {
            List {
                if def.repSchemes.isEmpty {
                    ContentUnavailableView("No Saved Sets", systemImage: "list.number",
                                           description: Text("Add one below."))
                } else {
                    Section {
                        ForEach(def.repSchemes, id: \.self) { reps in
                            row(reps)
                        }
                    } header: {
                        Text(headerText)
                    } footer: {
                        Text("Tap a set to set or change its rep ceiling. Once every set meets or beats its ceiling, that weight bump replaces the usual AI suggestion — in every phase the set is used.")
                    }
                }
                Section {
                    Button {
                        addingSet = true
                    } label: {
                        Label("Add a Set", systemImage: "plus")
                    }
                }
            }
            .navigationTitle(def.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $addingSet) { addSheet }
            .sheet(item: Binding(get: { ceilingTarget.map(RepsBox.init) },
                                 set: { ceilingTarget = $0?.reps })) { box in
                ceilingSheet(for: box.reps)
            }
            .sheet(item: Binding(get: { editTarget.map(RepsBox.init) },
                                 set: { editTarget = $0?.reps })) { box in
                editSheet(for: box.reps)
            }
            .confirmationDialog(pendingConfirmation?.title ?? "",
                                isPresented: Binding(get: { pendingConfirmation != nil },
                                                     set: { if !$0 { pendingConfirmation = nil } }),
                                titleVisibility: .visible,
                                presenting: pendingConfirmation) { pending in
                Button(pending.actionLabel,
                       role: pending.isDestructive ? .destructive : nil) {
                    pending.apply()
                    pendingConfirmation = nil
                }
                Button("Cancel", role: .cancel) { pendingConfirmation = nil }
            } message: { pending in
                Text(pending.message)
            }
        }
    }

    /// "6 sets · 2 with a ceiling" — the whole point of the header is that
    /// what's left to configure is visible without opening anything.
    private var headerText: String {
        let total = def.repSchemes.count
        let unset = total - ceilingCount
        guard unset > 0 else {
            return "\(total) set\(total == 1 ? "" : "s") · all have a ceiling"
        }
        return "\(total) set\(total == 1 ? "" : "s") · \(unset) without a ceiling"
    }

    private func row(_ reps: [Int]) -> some View {
        let ceiling = def.ceiling(for: reps)
        return Button {
            ceilingTarget = reps
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(reps.map(String.init).joined(separator: "/"))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.primary)
                    // Stated on the row, not behind a tap — scanning for
                    // what's unconfigured is the job this screen exists for.
                    if let ceiling {
                        Text("→ \(ceiling.upperTargetReps.map(String.init).joined(separator: "/"))  +\(Formatters.trim(ceiling.weightIncreaseAmount)) lb")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No ceiling")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit Ceiling…", systemImage: "arrow.up.to.line") { ceilingTarget = reps }
            Button("Edit Set…", systemImage: "pencil") { editTarget = reps }
            Button("Delete Set", systemImage: "trash", role: .destructive) { requestDelete(reps) }
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", role: .destructive) { requestDelete(reps) }
            Button("Edit") { editTarget = reps }.tint(.blue)
        }
    }

    // MARK: - Sheets

    private var addSheet: some View {
        AddSetSheet(exerciseName: def.name) { goalType, reps, ceiling, amount in
            switch goalType {
            case .fixedSets:
                def.addRepScheme(reps)
                if let ceiling, let amount {
                    def.setCeiling(for: reps, upperTargetReps: ceiling, weightIncreaseAmount: amount)
                }
            case .repTotal(let target):
                if !def.repTotalTargets.contains(target) { def.repTotalTargets.append(target) }
            }
            try? context.save()
            addingSet = false
        }
    }

    private func ceilingSheet(for reps: [Int]) -> some View {
        UpperTargetPickerSheet(exerciseName: def.name, setCount: reps.count,
                               initialUpperTargetReps: def.ceiling(for: reps)?.upperTargetReps,
                               initialWeightIncreaseAmount: def.ceiling(for: reps)?.weightIncreaseAmount) { newReps, newAmount in
            // Changing only the ceiling never touches the scheme, so there
            // is nothing for an impact check to warn about: no plan is
            // orphaned and no logged history moves.
            if let newReps, let newAmount {
                def.setCeiling(for: reps, upperTargetReps: newReps, weightIncreaseAmount: newAmount)
            } else {
                def.clearCeiling(for: reps)
            }
            try? context.save()
            ceilingTarget = nil
        }
    }

    private func editSheet(for reps: [Int]) -> some View {
        AddSetSheet(exerciseName: def.name, editingReps: reps,
                    ceiling: def.ceiling(for: reps)) { _, newReps, newCeilingReps, newAmount in
            editTarget = nil
            requestEdit(from: reps, to: newReps,
                        newCeilingReps: newCeilingReps, newAmount: newAmount)
        }
    }

    // MARK: - Applying, with confirmation only where it's earned

    private func requestEdit(from old: [Int], to new: [Int],
                             newCeilingReps: [Int]?, newAmount: Double?) {
        // Whatever the sheet came back with wins — it was seeded with the
        // existing ceiling, so an unchanged field means "keep it" and a
        // cleared one means "drop it". A ceiling whose set count no longer
        // matches is refused by the sheet itself (canAdd), so anything
        // arriving here is already well-formed.
        let resolved: RepSchemeCeiling? = {
            guard let newCeilingReps, let newAmount, newCeilingReps.count == new.count else { return nil }
            return RepSchemeCeiling(reps: new, upperTargetReps: newCeilingReps,
                                    weightIncreaseAmount: newAmount)
        }()
        let apply = {
            def.updateRepScheme(from: old, to: new, newCeiling: resolved)
            try? context.save()
        }
        guard let message = impact(old).editConfirmation(newReps: new) else { return apply() }
        pendingConfirmation = PendingConfirmation(
            title: "Change \(old.map(String.init).joined(separator: "/")) to \(new.map(String.init).joined(separator: "/"))?",
            message: message, actionLabel: "Change Set",
            isDestructive: false, apply: apply)
    }

    private func requestDelete(_ reps: [Int]) {
        let apply = {
            def.removeRepScheme(reps)
            try? context.save()
        }
        guard let message = impact(reps).deleteConfirmation else { return apply() }
        pendingConfirmation = PendingConfirmation(
            title: "Delete \(reps.map(String.init).joined(separator: "/"))?",
            message: message, actionLabel: "Delete Set",
            isDestructive: true, apply: apply)
    }
}

/// `[Int]` isn't Identifiable, and `.sheet(item:)` needs it to be.
private struct RepsBox: Identifiable {
    let reps: [Int]
    var id: String { reps.map(String.init).joined(separator: "/") }
    init(_ reps: [Int]) { self.reps = reps }
}
