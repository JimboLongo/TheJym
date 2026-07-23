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
    @Query(sort: \Phase.number, order: .reverse) private var phases: [Phase]

    var body: some View {
        NavigationStack {
            List {
                if phases.isEmpty {
                    ContentUnavailableView("No Phases Yet", systemImage: "calendar.badge.clock",
                                           description: Text("Set up a Phase from the Train tab to see it here."))
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
                                Text(phase.splitPattern)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Text("Cycle \(phase.currentCycle) of \(phase.totalCycles) · \(phase.completedSessionCount) sessions logged")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Phases")
        }
    }
}

struct PhaseDetailView: View {
    let phase: Phase

    var body: some View {
        List {
            ForEach(1...max(phase.totalCycles, 1), id: \.self) { cycle in
                ForEach(phase.distinctTrainingLetters, id: \.self) { letter in
                    Section("\(letter) \(cycle)") {
                        let plan = phase.plan(for: letter)
                        if plan.isEmpty {
                            Text("No exercises planned for \(letter).")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            ForEach(plan, id: \.persistentModelID) { pe in
                                PhaseExerciseRow(phase: phase, dayLetter: letter, plannedExercise: pe)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Phase \(phase.number)")
    }
}

/// One exercise under a "Pull 1"-style cycle/day section. Tapping it expands
/// to show every cycle it's actually been logged, most recent last, with dates —
/// the same expanded content regardless of which cycle you tapped from, since
/// the plan (exercise + reps) is the same every cycle.
struct PhaseExerciseRow: View {
    let phase: Phase
    let dayLetter: String
    let plannedExercise: PlannedExercise

    @State private var expanded = false

    private var history: [(cycle: Int, date: Date, log: ExerciseLog)] {
        phase.sessions
            .filter { $0.dayLetter == dayLetter }
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
                        Text(plannedExercise.targetReps.map(String.init).joined(separator: "/"))
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
