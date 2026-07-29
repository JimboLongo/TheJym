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

struct PhaseDetailView: View {
    let phase: Phase

    @State private var showingEdit = false

    var body: some View {
        List {
            ForEach(1...max(phase.totalCycles, 1), id: \.self) { cycle in
                ForEach(phase.trainingDays, id: \.persistentModelID) { day in
                    Section("\(day.name) \(cycle)") {
                        let plan = phase.plan(for: day)
                        if plan.isEmpty {
                            Text("No exercises planned for \(day.name).")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            ForEach(plan, id: \.persistentModelID) { pe in
                                PhaseExerciseRow(day: day, plannedExercise: pe)
                            }
                        }
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
    }
}

/// One exercise under a "Pull 1"-style cycle/day section. Tapping it expands
/// to show every cycle it's actually been logged, most recent last, with dates —
/// the same expanded content regardless of which cycle you tapped from, since
/// the plan (exercise + reps) is the same every cycle. History is matched by
/// the specific PhaseDay object, not its name, so "Pull A" and "Pull B" never
/// bleed into each other even if they happened to share a name.
struct PhaseExerciseRow: View {
    let day: PhaseDay
    let plannedExercise: PlannedExercise

    @State private var expanded = false

    private var history: [(cycle: Int, date: Date, log: ExerciseLog)] {
        (day.phase?.sessions ?? [])
            .filter { $0.day?.persistentModelID == day.persistentModelID }
            .compactMap { session in
                guard let log = session.exerciseLogs.first(where: { $0.exerciseName == plannedExercise.exerciseName }),
                      !log.sets.isEmpty else { return nil }
                return (session.cycleNumber, session.date, log)
            }
            .sorted { $0.cycle < $1.cycle }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation { expanded.toggle() }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(plannedExercise.exerciseName).font(.subheadline.bold())
                        Text(plannedExercise.setsSummaryText)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                if history.isEmpty {
                    Text("Not logged yet.")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.leading, 8)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(history, id: \.log.persistentModelID) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text("Cycle \(entry.cycle)").font(.caption.bold())
                                    Spacer()
                                    Text(Formatters.date.string(from: entry.date))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                ForEach(entry.log.sortedSets, id: \.persistentModelID) { s in
                                    Text("\(Formatters.trim(s.weight)) lbs × \(s.reps) reps")
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.leading, 8)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
