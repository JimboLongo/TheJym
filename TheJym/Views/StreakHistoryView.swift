//
//  StreakHistoryView.swift
//  TheJym
//
//  Reached by tapping "Max streak" on the Stats page — shows exactly the
//  days a given rest-bank streak covered, plus the day right before it
//  (that closed the previous streak, starting this one fresh) and the day
//  right after it (that broke this one), one row per calendar day so a
//  genuinely blank day shows up too, not just the ones with a session.
//

import SwiftUI
import SwiftData

struct StreakHistoryView: View {
    @Query(sort: \WorkoutSession.date) private var allSessions: [WorkoutSession]

    let range: MaxStreakDateRange
    @State private var editingSessionID: PersistentIdentifier?

    private var cal: Calendar { Calendar.current }

    private var streakStart: Date { cal.startOfDay(for: range.start) }
    private var streakEnd: Date { cal.startOfDay(for: range.end) }
    private var windowStart: Date { cal.startOfDay(for: range.precedingBreakDate ?? range.start) }
    private var windowEnd: Date { cal.startOfDay(for: range.followingBreakDate ?? range.end) }

    /// Every calendar day in the window, oldest first — walked day by day
    /// (not just the days with a session) so a genuinely blank day still
    /// gets its own row instead of silently vanishing.
    private var daysInWindow: [Date] {
        var days: [Date] = []
        var d = windowStart
        var iterations = 0
        while d <= windowEnd, iterations < 400 {
            days.append(d)
            iterations += 1
            guard let next = cal.date(byAdding: .day, value: 1, to: d) else { break }
            d = next
        }
        return days
    }

    private func session(on day: Date) -> WorkoutSession? {
        allSessions.first { cal.isDate($0.date, inSameDayAs: day) }
    }

    private func isWithinStreak(_ day: Date) -> Bool {
        day >= streakStart && day <= streakEnd
    }

    var body: some View {
        List {
            ForEach(daysInWindow, id: \.self) { day in
                Section {
                    if let session = session(on: day) {
                        let logs = session.exerciseLogs.sorted { $0.order < $1.order }
                        if logs.isEmpty {
                            Text("Rest").font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            ForEach(logs, id: \.persistentModelID) { log in
                                exerciseRow(log)
                            }
                        }
                    } else {
                        Text("Nothing logged").font(.subheadline).foregroundStyle(.secondary)
                    }
                } header: {
                    dayHeader(day, session: session(on: day))
                }
            }
        }
        .listStyle(.plain)
        .headerProminence(.increased)
        .navigationTitle("Streak History")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $editingSessionID) { id in
            if let session = allSessions.first(where: { $0.persistentModelID == id }) {
                SessionDetailView(session: session)
            }
        }
    }

    private func dayHeader(_ day: Date, session: WorkoutSession?) -> some View {
        HStack(spacing: 8) {
            if let session {
                Button {
                    editingSessionID = session.persistentModelID
                } label: {
                    Image(systemName: "pencil").foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }
            Text(Formatters.shortDate.string(from: day)).font(.subheadline.bold())
            if let session {
                Text(session.dayLabel).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if !isWithinStreak(day) {
                Text(day < streakStart ? "Started Fresh" : "Broke Streak")
                    .font(.caption2.bold())
                    .foregroundStyle(.orange)
            }
        }
        .textCase(nil)
    }

    private func exerciseRow(_ log: ExerciseLog) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(log.exerciseName).font(.subheadline.weight(.semibold))
            SetsGrid(weightLabels: PaceEngine.weightLabels(for: log),
                    repLabels: log.sortedSets.map { String($0.reps) })
        }
        .padding(.vertical, 2)
    }
}
