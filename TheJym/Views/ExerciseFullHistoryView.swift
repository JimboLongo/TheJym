//
//  ExerciseFullHistoryView.swift
//  TheJym
//
//  Tapping a set number on the exercise page opens this: every past log of
//  that exercise, styled like the History tab (weights over reps, aligned
//  by /). All-Time Best and Heaviest Single Rep are called out up top, then
//  the full history follows in descending date order.
//

import SwiftUI
import SwiftData

struct ExerciseFullHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    let exerciseName: String
    let allLogs: [ExerciseLog]

    private var sortedLogs: [ExerciseLog] {
        allLogs
            .filter { $0.exerciseName == exerciseName && !$0.sets.isEmpty }
            .sorted { ($0.session?.date ?? .distantPast) > ($1.session?.date ?? .distantPast) }
    }

    private var allTimeBest: ExerciseLog? {
        sortedLogs.max { $0.totalWeightMoved < $1.totalWeightMoved }
    }

    /// The workout containing the single heaviest weight ever lifted for a
    /// rep of this exercise — not the highest total, just the biggest
    /// per-rep load, regardless of which set it was.
    private var heaviestSingleRep: ExerciseLog? {
        sortedLogs.max { ($0.sortedSets.map(\.weight).max() ?? 0) < ($1.sortedSets.map(\.weight).max() ?? 0) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let best = allTimeBest {
                    Section("All-Time Best") {
                        row(for: best)
                    }
                }
                if let heaviest = heaviestSingleRep, heaviest.persistentModelID != allTimeBest?.persistentModelID {
                    Section("Heaviest Single Rep") {
                        row(for: heaviest)
                    }
                }
                Section("History") {
                    if sortedLogs.isEmpty {
                        Text("No logs yet.").font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(sortedLogs, id: \.persistentModelID) { log in
                        row(for: log)
                    }
                }
            }
            .navigationTitle(exerciseName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(for log: ExerciseLog) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let date = log.session?.date {
                    Text(Formatters.date.string(from: date)).font(.subheadline.bold())
                }
                Spacer()
                Text("\(Formatters.trim(log.totalWeightMoved)) lbs total")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            SetsGrid(weightLabels: PaceEngine.weightLabels(for: log),
                    repLabels: log.sortedSets.map { String($0.reps) })
        }
        .padding(.vertical, 2)
    }
}
