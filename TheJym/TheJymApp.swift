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
            Phase.self, PlannedExercise.self,
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

    var body: some View {
        TabView {
            TodayView()
                .tabItem { Label("Train", systemImage: "dumbbell.fill") }
            HistoryView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            StatsView()
                .tabItem { Label("Stats", systemImage: "chart.bar.fill") }
            ExercisesView()
                .tabItem { Label("Exercises", systemImage: "figure.strengthtraining.traditional") }
            EquipmentView()
                .tabItem { Label("Equipment", systemImage: "circle.circle") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .onAppear { bootstrap() }
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
                    context.insert(ExerciseDef(name: e.name, targetReps: reps, isLowerBody: e.lower))
                }
            }
        }
        try? context.save()
    }
}
