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
            BodyWeightEntry.self, RestDayActivity.self,
            ActiveRecovery.self, TrainingDaysPerWeekChange.self
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
            backfillBodyweightFlags()
            syncPlannedExerciseBodyweightFlags()
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

    /// Pre-isBodyweight installs have ExerciseDef rows for library
    /// bodyweight movements (Pull-Up, Dips) created before the flag
    /// existed, so they're stuck at the `false` default even though the
    /// library itself tags them bodyweight — bootstrap() only seeds defs on
    /// a totally empty library, so it never revisits them. Bring the def in
    /// line by name; syncPlannedExerciseBodyweightFlags() below propagates
    /// it from there to any already-placed PlannedExercise. Deliberately
    /// leaves already-logged ExerciseLog/SetLog rows alone — they recorded
    /// the old-style full weight, and flipping isBodyweight on them now
    /// would misread that as added weight instead.
    private func backfillBodyweightFlags() {
        let bodyweightNames = Set(ExerciseLibrary.grouped.flatMap(\.exercises).filter(\.isBodyweight).map(\.name))
        guard !bodyweightNames.isEmpty else { return }

        for def in exerciseDefs where bodyweightNames.contains(def.name) && !def.isBodyweight {
            def.isBodyweight = true
        }
        try? context.save()
    }

    /// The Exercises tab is the source of truth for isBodyweight, but
    /// PlannedExercise keeps its own copy (set once when it was added to a
    /// day) so toggling the flag there only affects future placements
    /// unless something syncs existing ones back. Runs on every launch so
    /// flipping Bodyweight on an exercise already placed into a Phase day
    /// takes effect there too, without removing and re-adding it. Never
    /// touches ExerciseLog/SetLog history — same reasoning as above.
    private func syncPlannedExerciseBodyweightFlags() {
        let defsByName = Dictionary(uniqueKeysWithValues: exerciseDefs.map { ($0.name, $0) })
        guard let plannedExercises = try? context.fetch(FetchDescriptor<PlannedExercise>()) else { return }
        var changed = false
        for pe in plannedExercises {
            guard let def = defsByName[pe.exerciseName], def.isBodyweight != pe.isBodyweight else { continue }
            pe.isBodyweight = def.isBodyweight
            changed = true
        }
        if changed { try? context.save() }
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
                    context.insert(ExerciseDef(name: e.name, repSchemes: [reps], isBodyweight: e.isBodyweight))
                }
            }
        }
        try? context.save()
    }
}
