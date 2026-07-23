//
//  HistoryView.swift
//  TheJym
//
//  Every past workout, with per-exercise total weight moved.
//

import SwiftUI
import SwiftData

struct HistoryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \WorkoutSession.date, order: .reverse) private var sessions: [WorkoutSession]

    var body: some View {
        NavigationStack {
            List {
                if sessions.isEmpty {
                    ContentUnavailableView("No workouts yet",
                                           systemImage: "clock.arrow.circlepath",
                                           description: Text("Your logged sessions will show up here."))
                }
                ForEach(sessions, id: \.persistentModelID) { session in
                    NavigationLink {
                        SessionDetailView(session: session)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("Day \(session.dayLetter) · Cycle \(session.cycleNumber)")
                                    .font(.headline)
                                if session.isDeload {
                                    Text("DELOAD").font(.caption2.bold())
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(.orange.opacity(0.2), in: Capsule())
                                }
                                Spacer()
                                Text(Formatters.date.string(from: session.date))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text("\(session.exerciseLogs.count) exercises · \(Formatters.trim(session.totalWeightMoved)) lbs moved")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { idx in
                    for i in idx { context.delete(sessions[i]) }
                    try? context.save()
                }
            }
            .navigationTitle("History")
        }
    }
}

struct SessionDetailView: View {
    let session: WorkoutSession

    var body: some View {
        List {
            ForEach(session.exerciseLogs.sorted { $0.order < $1.order }, id: \.persistentModelID) { log in
                Section(log.exerciseName) {
                    LabeledContent("Goal", value: log.targetReps.map(String.init).joined(separator: "/"))
                    ForEach(log.sortedSets, id: \.persistentModelID) { s in
                        LabeledContent("Set \(s.index + 1)",
                                       value: "\(Formatters.trim(s.weight)) × \(s.reps) = \(Formatters.trim(s.weight * Double(s.reps)))")
                            .font(.system(.subheadline, design: .monospaced))
                    }
                    LabeledContent("Total Weight Moved") {
                        Text("\(Formatters.trim(log.totalWeightMoved)) lbs").bold()
                    }
                }
            }
        }
        .navigationTitle(Formatters.date.string(from: session.date))
    }
}
