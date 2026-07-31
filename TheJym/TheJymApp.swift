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

/// The tabs that don't get a permanent slot in the bottom bar — reached
/// instead through the hamburger menu in the top-right of every main tab.
/// Presented as a sheet, so each keeps its own NavigationStack/toolbar as-is,
/// just with a "Done" button added to close it.
enum OverflowTab: Int, Identifiable {
    case phases, equipment, settings
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .phases: return "Phases"
        case .equipment: return "Equipment"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .phases: return "calendar"
        case .equipment: return "circle.circle"
        case .settings: return "gearshape.fill"
        }
    }
}

/// Hamburger button added to every main tab's toolbar, giving access to the
/// three overflow tabs (Phases, Equipment, Settings) from anywhere in the app.
struct OverflowMenuButton: View {
    @Binding var overflowTab: OverflowTab?

    var body: some View {
        Menu {
            ForEach([OverflowTab.phases, .equipment, .settings]) { tab in
                Button(tab.title, systemImage: tab.icon) { overflowTab = tab }
            }
        } label: {
            Image(systemName: "line.3.horizontal")
        }
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Query private var settingsList: [AppSettings]
    @Query private var bars: [Bar]
    @Query private var exerciseDefs: [ExerciseDef]
    @Query private var phases: [Phase]

    @State private var overflowTab: OverflowTab?

    var body: some View {
        TabView {
            TodayView(overflowTab: $overflowTab)
                .tabItem { Label("Train", systemImage: "dumbbell.fill") }
            StatsView(overflowTab: $overflowTab)
                .tabItem { Label("Stats", systemImage: "chart.bar.fill") }
            HistoryView(overflowTab: $overflowTab)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            ExercisesView(overflowTab: $overflowTab)
                .tabItem { Label("Exercises", systemImage: "figure.strengthtraining.traditional") }
            BodyWeightView(overflowTab: $overflowTab)
                .tabItem { Label("Weight", systemImage: "scalemass.fill") }
        }
        .sheet(item: $overflowTab) { tab in
            switch tab {
            case .phases: PhasesView()
            case .equipment: EquipmentView()
            case .settings: SettingsView()
            }
        }
        // Applies to every List/Form/ScrollView in the app (and sheets
        // presented from within it, which inherit this environment value) —
        // swiping down on the content dismisses an open keyboard, tracking
        // the drag interactively rather than needing a hard flick.
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            bootstrap()
            WorkoutSession.backfillRestDays(context: context)
            WorkoutSession.creditYesterdayAsRestIfNothingLogged(context: context)
            backfillBodyweightFlags()
            syncPlannedExerciseBodyweightFlags()
            ensureBandsBarExists()
            repairDanglingEquipmentReferences()
            fixPhaseStartDatesFromHistory()
            refreshStreakNotification()
            refreshWeightNotification()
        }
        // Re-evaluated on every foreground/background transition — not just
        // launch — so the reminder reflects whatever was just logged (on
        // backgrounding) and picks up a day rollover or a settings change
        // (on foregrounding), without needing every individual logging
        // action to remember to call this itself. Re-running the
        // yesterday-credit check here too catches the overnight rollover
        // for someone who leaves the app backgrounded (not fully quit)
        // across midnight instead of relaunching it.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                WorkoutSession.backfillRestDays(context: context)
                WorkoutSession.creditYesterdayAsRestIfNothingLogged(context: context)
            }
            if newPhase == .active || newPhase == .background {
                refreshStreakNotification()
                refreshWeightNotification()
            }
        }
    }

    /// "Logged today" here mirrors the rest bank's own credited-day
    /// definition (StatsEngine.computeRestBank): a real, exercise-bearing
    /// WorkoutSession, or a plain ActiveRecovery rest-day credit.
    private func refreshStreakNotification() {
        guard let settings = settingsList.first, settings.streakRemindersEnabled else {
            StreakNotificationManager.cancel()
            return
        }
        let cal = Calendar.current
        let sessions = (try? context.fetch(FetchDescriptor<WorkoutSession>())) ?? []
        let activeRecoveries = (try? context.fetch(FetchDescriptor<ActiveRecovery>())) ?? []
        let loggedToday = sessions.contains { cal.isDateInToday($0.date) && !$0.exerciseLogs.isEmpty }
            || activeRecoveries.contains { cal.isDateInToday($0.date) }
        StreakNotificationManager.refresh(enabled: true, loggedToday: loggedToday,
                                          reminderHour: settings.streakReminderHour)
    }

    /// "Already logged this week" mirrors BodyWeightView/TodayView's own
    /// upsert check — an entry dated to this week's Monday
    /// (Formatters.nearestPastMonday) already exists.
    private func refreshWeightNotification() {
        guard let settings = settingsList.first, settings.weightRemindersEnabled else {
            WeightNotificationManager.cancel()
            return
        }
        let monday = Formatters.nearestPastMonday()
        let bodyWeights = (try? context.fetch(FetchDescriptor<BodyWeightEntry>())) ?? []
        let alreadyLoggedThisWeek = bodyWeights.contains { Calendar.current.isDate($0.date, inSameDayAs: monday) }
        WeightNotificationManager.refresh(enabled: true, alreadyLoggedThisWeek: alreadyLoggedThisWeek,
                                          reminderHour: settings.weightReminderHour)
    }

    /// cyclePaceDelta/adherencePercent both assume every one of a Phase's
    /// attributed sessions happened within daysElapsed of its startDate —
    /// but a Phase auto-drafted from an import (or otherwise given
    /// backdated history some other way) can end up with a startDate of
    /// "today" while its real history goes back months, producing wildly
    /// inflated readings (e.g. "14 days ahead" / "1400%" adherence).
    /// Corrects any Phase whose startDate is later than its own earliest
    /// attributed session.
    private func fixPhaseStartDatesFromHistory() {
        var changed = false
        for phase in phases {
            guard let earliest = phase.sessions.map(\.date).min(), earliest < phase.startDate else { continue }
            phase.startDate = earliest
            changed = true
        }
        if changed { try? context.save() }
    }

    /// bootstrap() only seeds Dumbbells (alongside the starter bars) on a
    /// totally empty Equipment list, so an existing install never revisits
    /// it — add the Bands preset-weight bar separately, once, whenever it's
    /// still missing.
    private func ensureBandsBarExists() {
        guard !bars.contains(where: { $0.isDumbbell && $0.name == "Bands" }) else { return }
        context.insert(Bar(name: "Bands", weight: 0, isDumbbell: true,
                           dumbbellWeights: [10, 20, 30, 40, 50]))
        try? context.save()
    }

    /// ExerciseDef.equipment shipped without a `@Relationship` delete rule,
    /// so deleting a Bar left any ExerciseDef still pointing at it with a
    /// dangling reference instead of nullifying it — touching that
    /// ExerciseDef's equipment (e.g. opening a workout using it) then
    /// crashed with "backing data could no longer be found". The model now
    /// declares `.nullify` so this can't recur, but installs that already
    /// have a stale reference from before that fix need it cleared once
    /// here. Comparing only `persistentModelID` (identity metadata) rather
    /// than any real property keeps this safe to run even on an already
    /// dangling reference, which would crash if faulted for its attributes.
    private func repairDanglingEquipmentReferences() {
        let liveBarIDs = Set(bars.map(\.persistentModelID))
        var changed = false
        for def in exerciseDefs {
            guard let equipmentID = def.equipment?.persistentModelID, !liveBarIDs.contains(equipmentID) else { continue }
            def.equipment = nil
            changed = true
        }
        if changed { try? context.save() }
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
        let settings: AppSettings
        if let existing = settingsList.first {
            settings = existing
        } else {
            let new = AppSettings()
            context.insert(new)
            settings = new
        }
        if bars.isEmpty {
            context.insert(Bar(name: "Barbell", weight: 45))
            context.insert(Bar(name: "EZ Bar", weight: 15))
            context.insert(Bar(name: "Trap Bar", weight: 60))
            context.insert(Bar(name: "Dumbbells", weight: 0, isDumbbell: true,
                               dumbbellWeights: [5, 10, 15, 20, 25, 30, 35, 40, 45, 50]))
            context.insert(Bar(name: "Bands", weight: 0, isDumbbell: true,
                               dumbbellWeights: [10, 20, 30, 40, 50]))
        }
        if exerciseDefs.isEmpty && settings.includeDefaultExercises {
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
