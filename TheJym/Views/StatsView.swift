//
//  StatsView.swift
//  TheJym
//
//  Consistency stats (days logged, streaks, % logged, days/week) and
//  body-weight tracking with a chart.
//

import SwiftUI
import SwiftData
import Charts

struct StatsView: View {
    @Environment(\.modelContext) private var context
    @Query private var settingsList: [AppSettings]
    @Query(sort: \WorkoutSession.date) private var sessions: [WorkoutSession]
    @Query(sort: \BodyWeightEntry.date) private var weights: [BodyWeightEntry]
    @Query private var restActivities: [RestDayActivity]
    @Query private var phases: [Phase]

    @State private var newWeightText = ""

    private var settings: AppSettings? { settingsList.first }

    private var stats: TrainingStats {
        StatsEngine.compute(startDate: settings?.trainingStartDate ?? .now,
                            sessionDates: sessions.map(\.date),
                            restActivityDates: restActivities.map(\.date),
                            phaseSchedules: phases.map {
                                StatsEngine.PhaseSchedule(startDate: $0.startDate, splitPattern: $0.splitPattern)
                            })
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Consistency") {
                    if let s = settings {
                        DatePicker("Training start date",
                                   selection: Binding(
                                       get: { s.trainingStartDate },
                                       set: { s.trainingStartDate = $0; try? context.save() }),
                                   displayedComponents: .date)
                    }
                    statRow("Days since start", "\(stats.daysSinceStart)")
                    statRow("Days logged", "\(stats.daysLogged)")
                    statRow("Current streak", "\(stats.currentStreak) 🔥")
                    statRow("Max streak", "\(stats.maxStreak)")
                    statRow("% of days logged", String(format: "%.1f%%", stats.percentLogged * 100))
                    statRow("Days per week", String(format: "%.2f", stats.daysPerWeek))
                }

                Section("Body Weight") {
                    HStack {
                        TextField("Today's weight (lbs)", text: $newWeightText)
                            .keyboardType(.decimalPad)
                        Button("Log") {
                            if let w = Double(newWeightText) {
                                context.insert(BodyWeightEntry(weight: w))
                                try? context.save()
                                newWeightText = ""
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(Double(newWeightText) == nil)
                    }
                    if weights.count >= 2 {
                        Chart(weights, id: \.persistentModelID) { entry in
                            LineMark(x: .value("Date", entry.date),
                                     y: .value("Weight", entry.weight))
                            PointMark(x: .value("Date", entry.date),
                                      y: .value("Weight", entry.weight))
                        }
                        .chartYScale(domain: .automatic(includesZero: false))
                        .frame(height: 180)
                        .padding(.vertical, 4)
                    }
                    ForEach(weights.reversed(), id: \.persistentModelID) { e in
                        LabeledContent(Formatters.date.string(from: e.date),
                                       value: "\(Formatters.trim(e.weight)) lbs")
                    }
                    .onDelete { idx in
                        let reversed = Array(weights.reversed())
                        for i in idx { context.delete(reversed[i]) }
                        try? context.save()
                    }
                }
            }
            .navigationTitle("Stats")
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value).font(.system(.body, design: .monospaced)).bold()
        }
    }
}
