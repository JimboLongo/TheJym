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

    var body: some View {
        TabView {
            TodayView()
                .tabItem { Label("Train", systemImage: "dumbbell.fill") }
            HistoryView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            StatsView()
                .tabItem { Label("Stats", systemImage: "chart.bar.fill") }
            PlateCalcView()
                .tabItem { Label("Plates", systemImage: "circle.circle") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .onAppear { bootstrap() }
    }

    /// Create default settings + bars on first launch.
    private func bootstrap() {
        if settingsList.isEmpty {
            context.insert(AppSettings())
        }
        if bars.isEmpty {
            context.insert(Bar(name: "Barbell", weight: 45))
            context.insert(Bar(name: "EZ Bar", weight: 15))
            context.insert(Bar(name: "Trap Bar", weight: 60))
        }
        try? context.save()
    }
}
