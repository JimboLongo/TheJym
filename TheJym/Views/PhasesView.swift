//
//  PhasesView.swift
//  TheJym
//
//  Browse every Phase cycle-by-cycle: "Pull 1", "Push 1", "Legs 1", "Pull 2",
//  ... — each with its planned exercises. Tapping an exercise expands it to
//  show every cycle it's been logged, with dates.
//

import SwiftUI
import SwiftData

struct PhasesView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \Phase.number, order: .reverse) private var phases: [Phase]

    @State private var showingAdd = false
    @State private var phasePendingDelete: Phase?

    var body: some View {
        NavigationStack {
            List {
                if phases.isEmpty {
                    ContentUnavailableView("No Phases Yet", systemImage: "calendar.badge.clock",
                                           description: Text("Add a Phase to see it here."))
                }
                ForEach(phases, id: \.persistentModelID) { phase in
                    NavigationLink {
                        PhaseDetailView(phase: phase)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("Phase \(phase.number)").font(.headline)
                                if phase.isActive {
                                    Text("ACTIVE").font(.caption2.bold())
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(.green.opacity(0.2), in: Capsule())
                                }
                                Spacer()
                                Text(phase.summary)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Text("Cycle \(phase.currentCycle) of \(phase.totalCycles) · \(phase.filledSlotCount) sessions logged")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) { phasePendingDelete = phase } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle("Phases")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showingAdd = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showingAdd) {
                PhaseBuilderView(previousPhase: nil)
            }
            .confirmationDialog(
                "Delete Phase \(phasePendingDelete?.number ?? 0)?",
                isPresented: Binding(get: { phasePendingDelete != nil }, set: { if !$0 { phasePendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete Phase", role: .destructive) {
                    if let phase = phasePendingDelete { context.delete(phase) }
                    try? context.save()
                    phasePendingDelete = nil
                }
                Button("Cancel", role: .cancel) { phasePendingDelete = nil }
            } message: {
                Text("Its workout history stays in History and Exercises — just without a phase attached. This can't be undone.")
            }
        }
    }
}

/// Identifies one day's occurrence within one specific cycle — used to key
/// per-(cycle, day) collapse state, since the same PhaseDay is rendered
/// once per cycle and each occurrence collapses independently.
private struct DayCycleKey: Hashable {
    let cycle: Int
    let dayID: PersistentIdentifier
}

/// One (day, cycle, base slot) an override action targets — identifies
/// which base slot to override/revert and which cycle to do it for.
/// `effective` is what this cycle is currently actually planned to train
/// (the base slot itself, or its existing override) — "Change Set…" reads
/// its exercise name from here, not `baseSlot`, so changing the set again
/// after already swapping the exercise stays on the swapped-to exercise.
private struct OverrideTarget: Identifiable {
    let id = UUID()
    let day: PhaseDay
    let cycle: Int
    let baseSlot: PlannedExercise
    let effective: PlannedExercise
    let isOverridden: Bool
}

struct PhaseDetailView: View {
    let phase: Phase
    @Environment(\.modelContext) private var context
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Query(sort: \ExerciseDef.name) private var exerciseDefs: [ExerciseDef]
    @Query(sort: \Bar.name) private var bars: [Bar]
    @Query private var settingsList: [AppSettings]
    private var aiDeloadEnabled: Bool { settingsList.first?.deloadWeeksEnabled == true }

    @State private var showingEdit = false
    /// Which cycles are expanded — starts with only the current one open
    /// (displayCurrentCycle, same frozen-for-today value the Train tab
    /// itself shows) so a long phase doesn't dump every cycle's exercises
    /// on screen at once; any cycle can still be opened to browse its
    /// history.
    @State private var expandedCycles: Set<Int>
    /// Days collapsed within an expanded cycle — absence means expanded, so
    /// every day starts open without needing to pre-populate this set.
    @State private var collapsedDays: Set<DayCycleKey> = []
    /// The exact (day, cycle) session being edited — reuses History's own
    /// session editor (SetEditRow etc.) rather than a second copy of it, so
    /// changing a set's weight/reps here goes through the exact same code
    /// path/validation as editing it from History.
    @State private var editingSession: WorkoutSession?
    /// Showing the "Change Exercise… / Change Set… / Revert to Default"
    /// menu for this not-yet-logged slot.
    @State private var overrideTarget: OverrideTarget?
    /// Picking a whole replacement exercise (+ its set) for this slot's
    /// cycle.
    @State private var pickingReplacementFor: OverrideTarget?
    /// Picking a different set for this slot's cycle, same exercise.
    @State private var pickingSetFor: OverrideTarget?
    /// Adding a brand new set (for `pickingSetFor`'s exercise) not already
    /// saved on it.
    @State private var addingNewSetFor: OverrideTarget?
    /// Picking a rest-time-only override for this slot's cycle — exercise
    /// and set stay whatever's currently effective.
    @State private var pickingRestTimeFor: OverrideTarget?

    init(phase: Phase) {
        self.phase = phase
        _expandedCycles = State(initialValue: [phase.displayCurrentCycle])
    }

    private func isCycleExpanded(_ cycle: Int) -> Binding<Bool> {
        Binding(
            get: { expandedCycles.contains(cycle) },
            set: { expanded in
                if expanded { expandedCycles.insert(cycle) } else { expandedCycles.remove(cycle) }
            })
    }

    private func isDayExpanded(cycle: Int, day: PhaseDay) -> Binding<Bool> {
        let key = DayCycleKey(cycle: cycle, dayID: day.persistentModelID)
        return Binding(
            get: { !collapsedDays.contains(key) },
            set: { expanded in
                if expanded { collapsedDays.remove(key) } else { collapsedDays.insert(key) }
            })
    }

    private func isCycleDeload(_ cycle: Int) -> Binding<Bool> {
        Binding(
            get: { phase.isDeloadCycle(cycle, aiDeloadEnabled: aiDeloadEnabled) },
            set: { isDeload in
                phase.setDeload(isDeload, forCycle: cycle)
                try? context.save()
            })
    }

    /// The "Cycle N" bar itself — its own function (not inlined into the
    /// DisclosureGroup's label closure) to keep `body` simple enough for
    /// the type-checker now that it also holds the Deload toggle.
    /// Stacks vertically at an accessibility Dynamic Type size instead of
    /// staying in one HStack — switching the toggle to `.switch` style
    /// (a wider control than the old compact `.button` chip) made an
    /// already-cramped row measurably worse at AX5, taking "Deload" from a
    /// 2-line wrap to a 3-line one; confirmed by rendering both ways rather
    /// than assumed.
    @ViewBuilder
    private func cycleLabel(_ cycle: Int) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                Text("Cycle \(cycle)").font(.headline)
                deloadToggle(cycle)
            }
        } else {
            HStack {
                Text("Cycle \(cycle)").font(.headline)
                Spacer()
                deloadToggle(cycle)
            }
        }
    }

    /// `.switch` style's default view spreads its label and the switch
    /// apart to fill whatever width it's given (the same way a List row's
    /// Toggle does) — `.fixedSize()` collapses it back to its own natural
    /// width instead, so "Deload" sits directly against the switch rather
    /// than pinned to the leading edge with a gap before it. Scaled down
    /// 10% as a whole (text included, not just the switch) — "the toggle"
    /// here means this one control, matching how it's referred to
    /// everywhere else in this view. Trailing padding shifts the whole
    /// group further left, off the DisclosureGroup's own chevron — the
    /// chevron isn't part of this view (DisclosureGroup appends it itself
    /// outside whatever's returned here), so padding is the only lever
    /// available to create clearance from it.
    private func deloadToggle(_ cycle: Int) -> some View {
        Toggle("Deload", isOn: isCycleDeload(cycle))
            .toggleStyle(.switch)
            .font(.caption)
            .tint(.green)
            .fixedSize()
            .scaleEffect(0.9)
            .padding(.trailing, 25)
    }

    /// This exact cycle's session for `day`, if logged — what actually
    /// happened that occurrence, distinct from every other cycle's own
    /// session for the same day.
    private func session(cycle: Int, day: PhaseDay) -> WorkoutSession? {
        (day.phase?.sessions ?? []).first {
            $0.day?.persistentModelID == day.persistentModelID && $0.cycleNumber == cycle
        }
    }

    /// True if any exercise actually planned for `day` in `cycle` (base or
    /// overridden) no longer has a matching exercise/set in the Exercises
    /// library — see PlannedExercise.hasLibraryMatch's own doc.
    private func dayHasLibraryMismatch(_ day: PhaseDay, cycle: Int) -> Bool {
        phase.plan(for: day, cycle: cycle).contains { !$0.hasLibraryMatch(in: exerciseDefs) }
    }

    var body: some View {
        List {
            ForEach(1...max(phase.totalCycles, 1), id: \.self) { cycle in
                Section {
                    DisclosureGroup(isExpanded: isCycleExpanded(cycle)) {
                        ForEach(phase.trainingDays, id: \.persistentModelID) { day in
                            let cycleSession = session(cycle: cycle, day: day)
                            DisclosureGroup(isExpanded: isDayExpanded(cycle: cycle, day: day)) {
                                let base = phase.plan(for: day)
                                if base.isEmpty {
                                    Text("No exercises planned for \(day.name).")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else {
                                    let effective = phase.plan(for: day, cycle: cycle)
                                    ForEach(Array(zip(base, effective)), id: \.0.persistentModelID) { baseSlot, effectiveSlot in
                                        let log = cycleSession?.exerciseLogs.first { $0.exerciseName == effectiveSlot.exerciseName }
                                        let isOverridden = effectiveSlot.persistentModelID != baseSlot.persistentModelID
                                        CyclePlannedExerciseRow(plannedExercise: effectiveSlot, isOverridden: isOverridden,
                                                               hasLibraryMismatch: !effectiveSlot.hasLibraryMatch(in: exerciseDefs), log: log) {
                                            if let log, !log.sets.isEmpty {
                                                editingSession = cycleSession
                                            } else {
                                                overrideTarget = OverrideTarget(day: day, cycle: cycle, baseSlot: baseSlot,
                                                                               effective: effectiveSlot, isOverridden: isOverridden)
                                            }
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(day.name).font(.subheadline.bold())
                                    if dayHasLibraryMismatch(day, cycle: cycle) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    }
                                }
                            }
                            .padding(.top, 2)
                        }
                    } label: {
                        cycleLabel(cycle)
                    }
                }
            }
        }
        .navigationTitle("Phase \(phase.number)")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { showingEdit = true }
            }
        }
        .sheet(isPresented: $showingEdit) {
            PhaseEditView(phase: phase)
        }
        .navigationDestination(item: $editingSession) { session in
            SessionDetailView(session: session)
        }
        .confirmationDialog(
            overrideTarget.map { "Cycle \($0.cycle) — \($0.effective.exerciseName)" } ?? "",
            isPresented: Binding(get: { overrideTarget != nil }, set: { if !$0 { overrideTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Change Exercise…") {
                pickingReplacementFor = overrideTarget
                overrideTarget = nil
            }
            Button("Change Set…") {
                pickingSetFor = overrideTarget
                overrideTarget = nil
            }
            Button("Change Rest Time…") {
                pickingRestTimeFor = overrideTarget
                overrideTarget = nil
            }
            if overrideTarget?.isOverridden == true {
                Button("Revert to Default", role: .destructive) {
                    if let target = overrideTarget {
                        target.day.removeCycleOverride(for: target.baseSlot, cycle: target.cycle, context: context)
                    }
                    overrideTarget = nil
                }
            }
            Button("Cancel", role: .cancel) { overrideTarget = nil }
        } message: {
            Text("Not logged yet — change what this one cycle trains, or edit every cycle's plan instead.")
        }
        .sheet(item: $pickingReplacementFor) { target in
            AddExerciseToDayView(exerciseDefs: exerciseDefs, bars: bars) { def, reps, goalType in
                target.day.setCycleOverride(for: target.baseSlot, cycle: target.cycle, exerciseName: def.name,
                                            targetReps: reps, goalType: goalType, isBodyweight: def.isBodyweight,
                                            restTimeSeconds: target.effective.restTimeSeconds, context: context)
                try? context.save()
            }
        }
        .sheet(item: $pickingRestTimeFor) { target in
            RestTimePickerSheet(exerciseName: target.effective.exerciseName,
                                initialSeconds: target.effective.restTimeSeconds) { newValue in
                target.day.setCycleOverride(for: target.baseSlot, cycle: target.cycle,
                                            exerciseName: target.effective.exerciseName,
                                            targetReps: target.effective.targetReps,
                                            goalType: target.effective.goalType,
                                            isBodyweight: target.effective.isBodyweight,
                                            restTimeSeconds: newValue, context: context)
                try? context.save()
            }
        }
        .confirmationDialog(
            pickingSetFor?.effective.exerciseName ?? "",
            isPresented: Binding(get: { pickingSetFor != nil }, set: { if !$0 { pickingSetFor = nil } }),
            titleVisibility: .visible
        ) {
            if let target = pickingSetFor,
               let def = exerciseDefs.first(where: { $0.name == target.effective.exerciseName }) {
                ForEach(def.repSchemes, id: \.self) { reps in
                    Button(reps.map(String.init).joined(separator: "/")) {
                        target.day.setCycleOverride(for: target.baseSlot, cycle: target.cycle, exerciseName: def.name,
                                                    targetReps: reps, goalType: .fixedSets, isBodyweight: def.isBodyweight,
                                                    restTimeSeconds: target.effective.restTimeSeconds, context: context)
                        try? context.save()
                        pickingSetFor = nil
                    }
                }
                ForEach(def.repTotalTargets, id: \.self) { total in
                    Button("\(total) total reps") {
                        target.day.setCycleOverride(for: target.baseSlot, cycle: target.cycle, exerciseName: def.name,
                                                    targetReps: [], goalType: .repTotal(target: total), isBodyweight: def.isBodyweight,
                                                    restTimeSeconds: target.effective.restTimeSeconds, context: context)
                        try? context.save()
                        pickingSetFor = nil
                    }
                }
            }
            Button("Add New Set…") {
                addingNewSetFor = pickingSetFor
                pickingSetFor = nil
            }
            Button("Cancel", role: .cancel) { pickingSetFor = nil }
        }
        .sheet(item: $addingNewSetFor) { target in
            AddSetSheet(exerciseName: target.effective.exerciseName) { goalType, reps in
                let def = exerciseDefs.first { $0.name == target.effective.exerciseName }
                    ?? { let new = ExerciseDef(name: target.effective.exerciseName, isBodyweight: target.effective.isBodyweight)
                         context.insert(new); return new }()
                switch goalType {
                case .fixedSets: def.addRepScheme(reps)
                case .repTotal(let total): def.addRepTotalTarget(total)
                }
                target.day.setCycleOverride(for: target.baseSlot, cycle: target.cycle, exerciseName: def.name,
                                            targetReps: reps, goalType: goalType, isBodyweight: def.isBodyweight,
                                            restTimeSeconds: target.effective.restTimeSeconds, context: context)
                try? context.save()
                addingNewSetFor = nil
            }
        }
    }
}

/// One exercise's plan for one specific cycle occurrence of a day — shows
/// what was actually logged that cycle (not history across every cycle,
/// since the enclosing Cycle N group already scopes this to just one), and
/// flags when a per-cycle override (see PlannedExercise.cycleOverride)
/// makes this cycle differ from the base template. Tapping it either opens
/// that exact session for editing (once something's logged) or the
/// change/revert menu for this cycle's plan (before it's logged).
private struct CyclePlannedExerciseRow: View {
    let plannedExercise: PlannedExercise
    let isOverridden: Bool
    let hasLibraryMismatch: Bool
    let log: ExerciseLog?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(plannedExercise.exerciseName).font(.subheadline.bold())
                        if isOverridden {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        if hasLibraryMismatch {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    Text("\(plannedExercise.setsSummaryText) · Rest \(plannedExercise.restTimeSeconds.map { Formatters.duration(Double($0)) } ?? "–")")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if hasLibraryMismatch {
                        Text("No match in Exercises")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                if let log, !log.sets.isEmpty {
                    VStack(alignment: .trailing, spacing: 1) {
                        ForEach(log.sortedSets, id: \.persistentModelID) { s in
                            Text("\(Formatters.trim(s.weight)) × \(s.reps)")
                        }
                    }
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                } else {
                    Text("Not logged")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.vertical, 2)
    }
}
