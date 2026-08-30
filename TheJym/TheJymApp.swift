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
            migrateBigLiftFlagsToExerciseDef()
            repairDuplicatePlannedExerciseSlotIDs()
            ensureBandsBarExists()
            repairDanglingEquipmentReferences()
            fixPhaseStartDatesFromHistory()
            stampLegacyCompletedCycles()
            repairMissingCycleNumbers()
            undoPrematurePhaseAutoContinue()
            autoContinueQueuedPhases()
            repairLegacyRestActivityNames()
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
        // across midnight instead of relaunching it — same reasoning for
        // auto-continuing into a queued next phase, right below.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                WorkoutSession.backfillRestDays(context: context)
                WorkoutSession.creditYesterdayAsRestIfNothingLogged(context: context)
                undoPrematurePhaseAutoContinue()
                autoContinueQueuedPhases()
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

    /// If a Phase just showed as complete (displayIsComplete — the day
    /// after its last slot filled, same freeze the Phase Complete screen
    /// itself waits on so today's own header/summary doesn't flip out
    /// from under you mid-day) and a standby phase numbered exactly one
    /// higher already exists (built ahead of time via the Phases tab's
    /// "+"), auto-continues straight into it — no "Phase Complete"
    /// screen, no manual pick needed, once the day actually rolls over.
    /// The Train tab's own "next up" preview (TodayView.effectiveDaySource)
    /// separately handles TODAY, before this fires — once a phase's
    /// cycles are truly exhausted, a day beyond what's already been
    /// logged today previews the queued phase's matching day instead of
    /// wrapping this phase's own template back to day one, even while
    /// this phase is still the one shown active. Leaves everything alone
    /// whenever there's no single, unambiguous "next" phase already
    /// queued up — Phase Complete's own picker still handles that case.
    /// Must run after repairMissingCycleNumbers() (its cycle-completion
    /// math depends on correct cycleNumbers).
    private func autoContinueQueuedPhases() {
        var changed = false
        for phase in phases where phase.isActive && phase.displayIsComplete {
            guard let next = phases.queuedNextPhase(after: phase) else { continue }
            next.activate(among: phases)
            changed = true
        }
        if changed { try? context.save() }
    }

    /// One-time repair for pre-Aug-17 rest-day activity rows: commit
    /// e5089d3 moved a walk's distance from ExerciseLog.exerciseName
    /// (e.g. "Walk (3.1 mi)") into that log's single SetLog.weight, linked
    /// back to the originating RestDayActivity via the new
    /// ExerciseLog.restDayActivity relationship — but only changed the
    /// write paths, never migrated records already in the old shape.
    /// HistoryView gates its whole distance display/edit path on
    /// restDayActivity != nil, so an unmigrated row renders as a normal
    /// exercise ("3.1 lbs x 1 rep") instead of a distance.
    ///
    /// Also links the rarer case of a rest activity logged with no
    /// distance at all (a bare "Walk", say) — it never had a suffix for
    /// the pass below to key off, so it's still unlinked even though its
    /// RestDayActivity exists. That second pass matches purely by same
    /// name + same calendar day and never writes SetLog.weight, since
    /// there's no distance to move. Bounded to sessions before this
    /// commit's date — see the pass itself for why that bound has to
    /// exist at all, unlike the suffix pass above it.
    ///
    /// Only ever touches a log whose exerciseName still carries the old
    /// " (N mi)"/" (N km)" suffix — matched via the same regex `hasMatch`
    /// used to identify junk ExerciseDef rows below. A log already in the
    /// new shape (bare name, distance already in SetLog.weight,
    /// restDayActivity already set) has no suffix to match and is left
    /// completely alone; the suffix requirement is what keeps this from
    /// ever touching a correct row. Also requires exactly one SetLog —
    /// that's the shape the old write path always produced, and every row
    /// found on-device matched it, but a row with any other count is left
    /// alone rather than guessed at.
    ///
    /// For each match: finds the RestDayActivity dated the same calendar
    /// day with the stripped base name (and matching unit) and prefers
    /// ITS distance, since that's what StatsEngine's miles-walked totals
    /// already read — only falls back to the value parsed out of the old
    /// name if no RestDayActivity matches (didn't happen for any row this
    /// was checked against, but the fallback is kept for safety). Then
    /// renames the log, sets its one SetLog's weight to that distance, and
    /// links restDayActivity — the link is what actually makes History's
    /// distance UI take over; a rename alone would leave the row broken.
    ///
    /// Also deletes two kinds of junk ExerciseDef, so a rest activity has
    /// no entry point into the Exercises tab (matching c417e8a's intent,
    /// which only ever reached the import path — TodayView.logActivity's
    /// own ExerciseDef.ensureAnyVariantExists call was still live until
    /// this same repair):
    ///  1. Any def whose name matches the suffix — left behind by the old
    ///     write path's ensureAnyVariantExists(name: "Walk (2 mi)", ...),
    ///     one per distinct distance ever logged.
    ///  2. Any def named exactly like a RestDayActivity (e.g. bare
    ///     "Walk") where EVERY ExerciseLog sharing that name traces back
    ///     to a same-day RestDayActivity of that name — i.e. nothing
    ///     using that name is a real, independently-planned exercise.
    ///     Checked by date match, not just `restDayActivity != nil`, so a
    ///     rest activity logged before restDayActivity existed (no
    ///     distance, so no suffix for the loop above to migrate) still
    ///     counts as accounted for and doesn't block the def's deletion.
    /// Both are safe: ExerciseDef has no incoming relationship (matched
    /// only by name string), and neither deletion touches the
    /// ExerciseLog/RestDayActivity data itself.
    private func repairLegacyRestActivityNames() {
        let suffixPattern = /^(.+) \((\d+(?:\.\d+)?) (mi|km)\)$/
        guard let logs = try? context.fetch(FetchDescriptor<ExerciseLog>()) else { return }
        let restActivities = (try? context.fetch(FetchDescriptor<RestDayActivity>())) ?? []
        let cal = Calendar.current
        var changed = false

        for log in logs {
            guard log.restDayActivity == nil,
                  let match = log.exerciseName.firstMatch(of: suffixPattern),
                  log.sets.count == 1, let set = log.sets.first
            else { continue }
            let baseName = String(match.1)
            let parsedDistance = Double(match.2)
            let unit = String(match.3)
            let logDate = log.session?.date
            let matchedActivity = restActivities.first { activity in
                activity.name == baseName && activity.distanceUnit == unit
                    && logDate.map { cal.isDate(activity.date, inSameDayAs: $0) } == true
            }
            set.weight = matchedActivity?.distance ?? parsedDistance ?? 0
            log.exerciseName = baseName
            log.restDayActivity = matchedActivity
            changed = true
        }

        // Second, narrower pass: a log that never had a distance suffix at
        // all (a distance-less rest activity, e.g. a plain "Walk" logged
        // with no mileage) has nothing for the pass above to match, so it's
        // left permanently unlinked even though its RestDayActivity exists.
        // Link purely by same-day + same-name; never touch SetLog.weight
        // here since there's no distance to move and inventing one would
        // fabricate data.
        //
        // Unlike the suffix pass, this match criteria doesn't self-expire —
        // restDayActivity == nil / one SetLog / same-day-name-match is a
        // standing condition, not something that gets consumed by running
        // once. Left unbounded, it would silently re-fire on every future
        // launch against new data: a single-set ad hoc exercise named
        // "Walk" or "Cardio" (also an ActiveRecoveryType label) logged on a
        // day that also has a same-named RestDayActivity would get linked,
        // HistoryView would render it as a distance, and SetEditRow's
        // write-through would push weight edits into
        // RestDayActivity.distance — which StatsEngine sums for miles.
        // Bounding to sessions before e5089d3 (2026-08-17, when the write
        // paths started linking correctly on their own) confines this to
        // the legacy backlog it was written for, matching how every other
        // repair in this file re-derives "already done" from data rather
        // than a persisted flag — there's no didRepair-style Bool anywhere
        // in AppSettings, so a settings marker would be a new pattern, not
        // a followed one.
        let cutoff = cal.date(from: DateComponents(year: 2026, month: 8, day: 17))!
        for log in logs {
            guard log.restDayActivity == nil, log.sets.count == 1,
                  let logDate = log.session?.date, logDate < cutoff
            else { continue }
            guard let matchedActivity = restActivities.first(where: {
                $0.name == log.exerciseName && cal.isDate($0.date, inSameDayAs: logDate)
            }) else { continue }
            log.restDayActivity = matchedActivity
            changed = true
        }

        let restActivityDatesByName = Dictionary(grouping: restActivities, by: \.name)
            .mapValues { Set($0.map { cal.startOfDay(for: $0.date) }) }
        for def in (try? context.fetch(FetchDescriptor<ExerciseDef>())) ?? [] {
            let matchesSuffix = def.name.firstMatch(of: suffixPattern) != nil
            let restDatesForName = restActivityDatesByName[def.name]
            // Matches by name + date, not identity — a genuine planned
            // exercise that happens to share a name with a rest activity
            // (e.g. "Cardio", also an ActiveRecoveryType label) and is only
            // ever logged on days that also have a same-named
            // RestDayActivity would have its def deleted here too. Fine in
            // practice: this migration already ran and the real data had
            // no such collision, but a future re-run wouldn't be immune.
            let isRestActivityOnlyName = restDatesForName.map { restDates in
                logs.allSatisfy { candidate in
                    guard candidate.exerciseName == def.name else { return true }
                    guard let sessionDate = candidate.session?.date else { return false }
                    return restDates.contains(cal.startOfDay(for: sessionDate))
                }
            } ?? false
            guard matchesSuffix || isRestActivityOnlyName else { continue }
            context.delete(def)
            changed = true
        }

        if changed { try? context.save() }
    }

    /// One-time cleanup for a bug in an earlier build of this same
    /// feature: autoContinueQueuedPhases briefly activated a queued Phase
    /// n+1 the instant its predecessor's LIVE isComplete turned true,
    /// rather than waiting for displayIsComplete like it does now — so
    /// finishing every cycle of a phase in one sitting switched the
    /// active phase (and the Train tab's whole header) over immediately,
    /// before the "day after" freeze the rest of this screen relies on.
    /// Reverts that: if the active phase has never actually been trained
    /// (no sessions) and the phase one number below it hasn't reached
    /// displayIsComplete yet, that's overwhelmingly the signature of this
    /// bug — a real, deliberate switch via the standby picker is only
    /// ever reachable once the old phase's displayIsComplete has already
    /// flipped, so this can't misfire on a legitimate manual switch.
    /// Harmless to leave running indefinitely: once no install is left
    /// carrying that bad state, it's a fast no-op forever after. Must run
    /// before autoContinueQueuedPhases (undoes the bad activation first,
    /// so that check then correctly finds nothing to do yet).
    private func undoPrematurePhaseAutoContinue() {
        guard let active = phases.first(where: \.isActive), active.sessions.isEmpty,
              let previous = phases.first(where: { $0.number == active.number - 1 }),
              !previous.displayIsComplete
        else { return }
        previous.activate(among: phases)
        try? context.save()
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

    /// ONE-TIME migration for the Big Lift flag's move off PlannedExercise
    /// (289beb9) onto ExerciseDef, keyed by name instead of by slot — see
    /// ExerciseDef.isBigLift's own doc for why. Copies every already-flagged
    /// PlannedExercise's flag forward onto the matching ExerciseDef (by
    /// name) before PlannedExercise.isBigLift is removed from the schema —
    /// idempotent like every other repair here (no persisted "already ran"
    /// marker): once no PlannedExercise carries the old flag anymore
    /// (either because none ever did, or because this has already copied
    /// them all forward), it's a no-op every subsequent launch. Logs what it
    /// found so a real-device run can be confirmed from the console.
    private func migrateBigLiftFlagsToExerciseDef() {
        guard let flaggedSlots = try? context.fetch(FetchDescriptor<PlannedExercise>()) else { return }
        let flagged = flaggedSlots.filter(\.isBigLift)
        guard !flagged.isEmpty else { return }
        let defsByName = Dictionary(uniqueKeysWithValues: exerciseDefs.map { ($0.name, $0) })
        var matchedNames: Set<String> = []
        var unmatchedNames: Set<String> = []
        var changed = false
        for pe in flagged {
            guard let def = defsByName[pe.exerciseName] else {
                unmatchedNames.insert(pe.exerciseName)
                continue
            }
            matchedNames.insert(pe.exerciseName)
            guard !def.isBigLift else { continue }
            def.isBigLift = true
            changed = true
        }
        if changed { try? context.save() }
        print("Big Lift migration: \(flagged.count) flagged PlannedExercise row(s) found, "
              + "\(matchedNames.count) distinct ExerciseDef(s) flagged (\(matchedNames.sorted().joined(separator: ", "))), "
              + "\(unmatchedNames.count) with no matching ExerciseDef"
              + (unmatchedNames.isEmpty ? "." : ": \(unmatchedNames.sorted().joined(separator: ", "))."))
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
