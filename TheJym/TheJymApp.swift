//
//  TheJymApp.swift
//  TheJym
//

import SwiftUI
import SwiftData

@main
struct TheJymApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [
            AppSettings.self, Bar.self, ExerciseDef.self,
            Phase.self, PhaseDay.self, PlannedExercise.self,
            WorkoutSession.self, ExerciseLog.self, SetLog.self,
            BodyWeightEntry.self, RestDayActivity.self
        ])
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Query private var settingsList: [AppSettings]
    @Query private var bars: [Bar]
    @Query private var exerciseDefs: [ExerciseDef]
    @Query(sort: \WorkoutSession.date) private var allSessions: [WorkoutSession]

    var body: some View {
        TabView {
            TodayView()
                .tabItem { Label("Train", systemImage: "dumbbell.fill") }
            StatsView()
                .tabItem { Label("Stats", systemImage: "chart.bar.fill") }
            PhasesView()
                .tabItem { Label("Phases", systemImage: "calendar") }
            HistoryView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            ExercisesView()
                .tabItem { Label("Exercises", systemImage: "figure.strengthtraining.traditional") }
            EquipmentView()
                .tabItem { Label("Equipment", systemImage: "circle.circle") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .onAppear {
            bootstrap()
            backfillRestDays()
        }
    }

    /// Any past calendar day (from your earliest logged session through
    /// yesterday) with no session at all gets a no-activity Rest Day entry,
    /// so history never has an unexplained gap. Safe to re-run every launch —
    /// only fills days that are still missing.
    private func backfillRestDays() {
        guard let earliest = allSessions.first?.date else { return }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var existingDays = Set(allSessions.map { calendar.startOfDay(for: $0.date) })

        var day = calendar.startOfDay(for: earliest)
        while day < today {
            if !existingDays.contains(day) {
                let session = WorkoutSession(date: day, dayLabel: "Rest Day", cycleNumber: 0)
                context.insert(session)
                existingDays.insert(day)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        try? context.save()
    }

    /// Create default settings, bars, dumbbells, and exercise library on first launch.
    private func bootstrap() {
        if settingsList.isEmpty {
            context.insert(AppSettings())
        }
        if bars.isEmpty {
            context.insert(Bar(name: "Barbell", weight: 45))
            context.insert(Bar(name: "EZ Bar", weight: 15))
            context.insert(Bar(name: "Trap Bar", weight: 60))
            context.insert(Bar(name: "Dumbbells", weight: 0, isDumbbell: true,
                               dumbbellWeights: [5, 10, 15, 20, 25, 30, 35, 40, 45, 50]))
        }
        if exerciseDefs.isEmpty {
            for group in ExerciseLibrary.grouped {
                for e in group.exercises {
                    let reps = e.defaultReps.split(separator: "/").compactMap { Int($0) }
                    context.insert(ExerciseDef(name: e.name, repSchemes: [reps]))
                }
            }
        }
        try? context.save()
    }
}
