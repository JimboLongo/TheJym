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
            ActiveRecovery.self, TrainingDaysPerWeekChange.self,
            TimerTemplate.self, TimerPreset.self
        ])
    }
}

/// The tabs that don't get a permanent slot in the bottom bar — reached
/// instead through the hamburger menu in the top-right of every main tab.
/// Presented as a sheet, so each keeps its own NavigationStack/toolbar as-is,
/// just with a "Done" button added to close it.
enum OverflowTab: Int, Identifiable {
    case phases, equipment, timer, settings
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .phases: return "Phases"
        case .equipment: return "Equipment"
        case .timer: return "Timer"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .phases: return "calendar"
        case .equipment: return "circle.circle"
        case .timer: return "timer"
        case .settings: return "gearshape.fill"
        }
    }
}

/// The 5 tabs with a permanent slot in the bottom bar — as opposed to
/// `OverflowTab`, reached through the hamburger menu instead. Given its own
/// binding (rather than leaving `TabView`'s selection implicit) so a deeply
/// nested view — e.g. finishing a workout from `WorkoutLogView`, several
/// navigation pushes deep under the Train tab — can jump to another tab
/// programmatically.
enum MainTab: Hashable {
    case train, stats, history, exercises, weight
}

/// Hamburger button added to every main tab's toolbar, giving access to the
/// overflow tabs (Phases, Equipment, Timer, Settings) from anywhere in the app.
struct OverflowMenuButton: View {
    @Binding var overflowTab: OverflowTab?

    var body: some View {
        Menu {
            ForEach([OverflowTab.phases, .equipment, .timer, .settings]) { tab in
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
    @State private var selectedTab: MainTab = .train

    var body: some View {
        TabView(selection: $selectedTab) {
            TodayView(overflowTab: $overflowTab, selectedTab: $selectedTab)
                .tabItem { Label("Train", systemImage: "dumbbell.fill") }
                .tag(MainTab.train)
            StatsView(overflowTab: $overflowTab)
                .tabItem { Label("Stats", systemImage: "chart.bar.fill") }
                .tag(MainTab.stats)
            HistoryView(overflowTab: $overflowTab)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(MainTab.history)
            ExercisesView(overflowTab: $overflowTab)
                .tabItem { Label("Exercises", systemImage: "figure.strengthtraining.traditional") }
                .tag(MainTab.exercises)
            BodyWeightView(overflowTab: $overflowTab)
                .tabItem { Label("Weight", systemImage: "scalemass.fill") }
                .tag(MainTab.weight)
        }
        .sheet(item: $overflowTab) { tab in
            switch tab {
            case .phases: PhasesView()
            case .equipment: EquipmentView()
            case .timer: TimerTemplatesListView()
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
            repairRestDaySessionsMissingPhase()
            WorkoutSession.backfillRestDays(context: context)
            WorkoutSession.creditYesterdayAsRestIfNothingLogged(context: context)
            backfillBodyweightFlags()
            syncPlannedExerciseBodyweightFlags()
            repairDuplicatePlannedExerciseSlotIDs()
            ensureBandsBarExists()
            repairDanglingEquipmentReferences()
            fixPhaseStartDatesFromHistory()
            stampLegacyCompletedCycles()
            repairMissingCycleNumbers()
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

    /// Freezes Phase.legacyCompletedCycles once for any phase that doesn't
    /// have it yet — replays the old training-only completion rule (Rest
    /// slots not required) against history as it stands right now, then
    /// banks one cycle short of that count as the permanent grandfather
    /// floor. The "one short" is deliberate: it's what makes the cycle in
    /// progress at the moment Rest-aware tracking shipped actually have to
    /// earn its completion under the new rule (which is exactly the report
    /// that motivated this — finishing the last training day of a cycle was
    /// completing it and rolling to the next cycle before that cycle's own
    /// Rest day was ever logged) instead of being grandfathered in too.
    /// Never recomputed after that: doing so from then-current history
    /// would keep re-including cycles the Rest-aware rule has since validly
    /// completed on its own, silently regranting a floor that should stay
    /// fixed.
    private func stampLegacyCompletedCycles() {
        var changed = false
        for phase in phases where phase.legacyCompletedCycles == nil {
            let trainingSlotIDs = Set(phase.trainingDays.map(\.persistentModelID))
            guard !trainingSlotIDs.isEmpty else {
                phase.legacyCompletedCycles = 0
                changed = true
                continue
            }
            let relevant = phase.sessions
                .filter { $0.day != nil }
                .sorted { $0.date < $1.date }
            var filled: Set<PersistentIdentifier> = []
            var completedCycles = 0
            for session in relevant {
                guard let dayID = session.day?.persistentModelID,
                      trainingSlotIDs.contains(dayID), !filled.contains(dayID) else { continue }
                filled.insert(dayID)
                guard trainingSlotIDs.isSubset(of: filled) else { continue }
                completedCycles += 1
                filled = []
            }
            phase.legacyCompletedCycles = max(0, completedCycles - 1)
            changed = true
        }
        if changed { try? context.save() }
    }

    /// One-time repair: stamps a real `cycleNumber` onto any existing
    /// session that still has `day != nil` but `cycleNumber == 0` — i.e.
    /// predates `cycleNumber` becoming Phase.cycleWalk's source of truth
    /// (see Phase.legacyCycleNumbers' doc). Uses that frozen replay of the
    /// OLD chronological algorithm so nothing visibly shifts for anyone on
    /// upgrade. Must run after repairRestDaySessionsMissingPhase() (needs
    /// correct `.phase` first) and stampLegacyCompletedCycles() (the replay
    /// reads legacyCompletedCycles) — and before anything reads
    /// phase.currentCycle. Only ever touches sessions still at the `0`
    /// marker, never a session with a real cycle number already (whether
    /// from live logging before this shipped, or a manual edit in History
    /// afterward) — safe to leave running on every launch, since
    /// `cycleNumber == 0` with `day != nil` can no longer happen once every
    /// session-creation path is fixed, making this a fast no-op from then on.
    private func repairMissingCycleNumbers() {
        var changed = false
        for phase in phases {
            let toFix = phase.sessions.filter { $0.day != nil && $0.cycleNumber == 0 }
            guard !toFix.isEmpty else { continue }
            let assignments = phase.legacyCycleNumbers()
            for session in toFix {
                guard let n = assignments[session.persistentModelID] else { continue }
                session.cycleNumber = n
                changed = true
            }
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

    /// One-time repair for a RestDayLogView bug (fixed alongside this):
    /// logging a Rest day live — the one-tap "Log Rest Day" button, a Rest
    /// Day activity, or an ad hoc exercise on a Rest day — set the new
    /// session's `day` but never its `phase`. Phase.cycleWalk only ever
    /// walks `phase.sessions` (the inverse of that same `phase` field), so
    /// those Rest sessions were invisible to it — the Rest slot a8702ad
    /// requires could never actually fill from live logging, only from
    /// import (which always set `phase` correctly). A session's `day`
    /// unambiguously names its owning Phase (PhaseDay.phase), so this is a
    /// safe, lossless repair: any session tied to a real PhaseDay but
    /// missing its Phase gets it filled back in. Run early, before the
    /// other phase-cycle repairs below, so they see the corrected history.
    private func repairRestDaySessionsMissingPhase() {
        let sessions = (try? context.fetch(FetchDescriptor<WorkoutSession>())) ?? []
        var changed = false
        for session in sessions {
            guard session.phase == nil, let owningPhase = session.day?.phase else { continue }
            session.phase = owningPhase
            changed = true
        }
        if changed { try? context.save() }
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

    /// One-time repair for a bug where every PlannedExercise ended up with
    /// the SAME `slotID`: SwiftData's @Model macro doesn't reliably re-run
    /// a stored property's `= UUID()` default inside a hand-written init,
    /// so PlannedExercise.init's own `self.slotID = UUID()` used to be
    /// missing (now added). A shared slotID broke per-cycle overrides —
    /// Phase.plan(for:cycle:) matches an override to its base slot BY
    /// slotID, so one override's substitution ended up applying to every
    /// slot in its day instead of just its own, exactly matching the
    /// report that motivated this fix. Reassigns a fresh, distinct slotID
    /// to every base slot (cycleOverride == 0) that collides with another
    /// PlannedExercise anywhere in the store; any override whose
    /// `overriddenSlotID` pointed at a colliding value can no longer be
    /// trusted to identify which specific base slot it meant, so it's
    /// deleted rather than left silently inert (or still colliding).
    private func repairDuplicatePlannedExerciseSlotIDs() {
        guard let all = try? context.fetch(FetchDescriptor<PlannedExercise>()), !all.isEmpty else { return }
        var countsBySlotID: [UUID: Int] = [:]
        for pe in all { countsBySlotID[pe.slotID, default: 0] += 1 }
        let collidingIDs = Set(countsBySlotID.filter { $0.value > 1 }.map(\.key))
        guard !collidingIDs.isEmpty else { return }

        for pe in all where pe.cycleOverride > 0 {
            if let overridden = pe.overriddenSlotID, collidingIDs.contains(overridden) {
                context.delete(pe)
            }
        }
        for pe in all where pe.cycleOverride == 0 && collidingIDs.contains(pe.slotID) {
            pe.slotID = UUID()
        }
        try? context.save()
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
