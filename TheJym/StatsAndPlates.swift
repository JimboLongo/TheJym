//
//  StatsAndPlates.swift
//  TheJym
//
//  Training-consistency stats + barbell plate math.
//

import Foundation

// MARK: - Stats

struct TrainingStats {
    var daysSinceStart: Int
    var daysLogged: Int
    var currentStreak: Int      // credited days since the rest bank last broke
    var maxStreak: Int
    /// The actual date range of whichever streak achieved maxStreak, plus
    /// the days right before/after it that closed the previous streak and
    /// broke this one — nil only when maxStreak is 0 (nothing logged yet).
    var maxStreakRange: MaxStreakDateRange?
    /// When the currently-open streak began — nil once currentStreak is 0.
    var currentStreakStartDate: Date?

    /// Consecutive calendar days ending today (or yesterday, if today
    /// hasn't been logged yet) on which SOMETHING was done — training or a
    /// logged rest-day activity. Deliberately NOT a variant of
    /// `currentStreak` above: that one runs on the rest bank, where
    /// training is neutral and rest days spend from a balance, so it
    /// survives rest days. This has no bank at all — an unlogged day of any
    /// kind ends it. See StatsEngine.activeDayStreaks.
    var currentActiveStreak: Int
    /// The first day of the currently-open active run — nil once
    /// `currentActiveStreak` is 0, matching `currentStreakStartDate`'s own
    /// convention, so the Stats row shows no subtitle rather than an empty
    /// one. This is the run's genuine first day: the pending-today rule
    /// only decides where the walk STARTS looking back from, never where
    /// the run began.
    var currentActiveStreakStartDate: Date?
    /// All-time longest run of the same measure. 0, never nil, with no
    /// history.
    var maxActiveStreak: Int
    /// The calendar span whichever run holds `maxActiveStreak` actually
    /// covered — nil only when that's 0 (nothing logged yet), so the Stats
    /// row shows no subtitle at all rather than an empty range. Reuses
    /// MaxStreakDateRange: its `followingBreakDate == nil` already means
    /// "still the ongoing streak", which is exactly the signal the
    /// "– Present" rendering needs, so there's no separate flag.
    var maxActiveStreakRange: MaxStreakDateRange?
    var bankBalance: Double     // current rest-bank balance, >= 0, uncapped above
    var percentLogged: Double   // daysLogged / daysSinceStart
    var daysPerWeek: Double
    /// Same measure as `daysPerWeek`, over the same window and the same
    /// `weeks` denominator, but counting only days that involved actual
    /// LIFTING — a walk-only day doesn't count, while a day with both a
    /// lift and a walk does. See WorkoutSession.hasLiftingLog.
    var liftDaysPerWeek: Double
    /// The remainder of `daysPerWeek` after `liftDaysPerWeek` — days with
    /// a rest activity and NO lift on them. Defined as the set difference
    /// rather than counted independently, so
    /// `liftDaysPerWeek + walkDaysPerWeek == daysPerWeek` holds exactly:
    /// a day with both a lift and a walk belongs to the lift column only,
    /// and can't be double-counted into this one.
    var walkDaysPerWeek: Double

    // Year/month-to-date workout-day counts, vs. the same window last year.
    var ytdWorkoutDays: Int
    var priorYearYtdWorkoutDays: Int
    var mtdWorkoutDays: Int
    var priorYearMtdWorkoutDays: Int

    // Consistency-against-schedule counts. A week/month only counts once
    // it's fully over, and only if a phase was actually active to judge it
    // against (no schedule = not counted either way).
    var perfectWeeks: Int       // every scheduled training day that week was logged
    var perfectMonths: Int      // every scheduled training day that month was logged
    var bestMonthLabel: String? // e.g. "March 2026"
    var bestMonthWorkouts: Int  // workouts logged in that month

    // Active-Phase-only stats (nil with no active phase).
    var cyclePaceDelta: Int?        // actual sessions vs. floor(daysElapsed * pace)
    var adherencePercent: Double?   // sessions logged / sessions scheduled to date

    // Perfect-cycle progress — populated only when there's an active phase.
    var perfectCycleLifetimeCount: Int?
    var perfectCycleCurrentStreak: Int?
    var activePhaseCycleProgress: ActivePhaseCycleProgress?
    // Shown instead of the three fields above when there's no active phase.
    var perfectWeekFallback: PerfectWeekFallback?

    // Miles walked — summed from RestDayActivity.distance entries whose
    // distanceUnit is literally "mi" (a non-mile unit like "km" isn't
    // converted, just excluded from these totals).
    var milesSinceStart: Double     // within [Training Start Date, today]
    var milesThisPhase: Double?     // within [active phase's start, today] — nil with no active phase
    var ytdMiles: Double
    var priorYearYtdMiles: Double
    var mtdMiles: Double
    var priorYearMtdMiles: Double
    var allTimeMiles: Double        // unbounded — every "mi" entry in history
    /// Distinct calendar days with at least one real, exercise-bearing
    /// session ever logged — unbounded, same scope as `allTimeMiles`
    /// above rather than `daysSinceStart`'s window. A day count, not a
    /// session count: training and a walk on the same date is one active
    /// day. Same basis as `yearlyTotals`, so the two agree.
    var allTimeActiveDayCount: Int
    /// Hours across every non-deload session with a recorded
    /// durationSeconds — a session logged before duration tracking existed
    /// (or one where the workout stopwatch was never started), and any
    /// deload session regardless of duration, are excluded from this sum
    /// entirely, not counted as 0. StatsView states this scope explicitly
    /// rather than let the number look complete when it isn't.
    var allTimeHoursTrained: Double

    /// Every finished, no-longer-active phase's frozen final numbers,
    /// newest first. A phase that's complete has no sessions to derive an
    /// end date from is skipped rather than guessing one — see
    /// `compute`'s own note on that.
    var completedPhaseSummaries: [PhaseSummary]

    /// One group per flagged exercise (ExerciseDef.isBigLift) with at least
    /// one qualifying set anywhere in history — see StatsEngine.compute's
    /// own note on exactly how each group's rows are built.
    var bigLiftGroups: [BigLiftGroup]

    /// One group per workout day template (e.g. "Lower Day 1") with at
    /// least one NON-DELOAD session anywhere that has a recorded duration —
    /// see StatsEngine.compute's own note on exactly how each group's rows
    /// are built. The Stats page's first Workout Duration page.
    var dayDurationGroups: [DayDurationGroup]
    /// Same shape as `dayDurationGroups`, built from DELOAD sessions only —
    /// the Stats page's second (swipe-to) Workout Duration page. The two
    /// partition every session that has a duration, so a session appears on
    /// exactly one page and never both.
    var deloadDayDurationGroups: [DayDurationGroup]

    /// One entry per calendar year that has at least one session or any
    /// miles, newest first — see StatsEngine.compute's own note.
    var yearlyTotals: [YearTotal]
    /// A full-year projection of the CURRENT year — what's banked so far
    /// plus the trailing 3-month pace applied to the days remaining — or
    /// nil when there isn't enough of the year on record to extrapolate
    /// from (see compute's own note for the window and the minimum).
    /// Its `year` is the current year — the same one it's projecting —
    /// so the Stats table can sit it next to that year's actuals.
    var currentYearProjection: YearTotal?
}

/// The actual calendar range a streak covered, plus its boundary days —
/// used to filter History to "this streak, and whatever broke it on
/// either side" when the user taps a streak stat. Hashable so it can drive
/// a `.navigationDestination(item:)`.
struct MaxStreakDateRange: Hashable {
    let start: Date
    let end: Date
    /// The day right before `start` that closed the PREVIOUS streak (the
    /// first unlogged day whose deduction broke it) — nil if `start` is the
    /// very first credited day in all of history, so there was no prior
    /// streak to close.
    let precedingBreakDate: Date?
    /// The day that broke this streak — nil if this is still the ongoing,
    /// currently-open streak (hasn't broken as of "today").
    let followingBreakDate: Date?
}

/// "Phase N: X of Y perfect" — X of that phase's own completed cycles met
/// the perfect-cycle bar.
struct ActivePhaseCycleProgress {
    let number: Int
    let perfectCount: Int
    let completedCount: Int
}

/// The no-active-phase substitute for perfect-cycle progress: a plain
/// Mon-Sun week counts as perfect once its logged-session count meets the
/// training-days-per-week setting in effect that week.
struct PerfectWeekFallback {
    let lifetimeCount: Int
    let currentStreak: Int
}

/// A finished, no-longer-active phase's final numbers — frozen at that
/// phase's own end date (its last session) rather than "now". Unlike the
/// active-phase stats above, these never change again once computed, since
/// nothing about a completed phase is still moving.
struct PhaseSummary: Identifiable {
    var id: Int { number }
    let number: Int
    let startDate: Date
    let endDate: Date
    let cyclePaceDelta: Int
    let adherencePercent: Double
    let perfectCount: Int
    let completedCount: Int
    let milesWalked: Double
}

/// One exercise-grouped block in the Stats page's single "Big Lifts"
/// section — the exercise name is the group's own header (see
/// StatsView.BigLiftGroupSection), not a row.
struct BigLiftGroup: Identifiable {
    var id: String { exerciseName }
    let exerciseName: String
    /// All-Time first, then EVERY phase (completed or active — same set
    /// completedPhaseSummaries and the active-phase stats already use),
    /// descending by phase number, so the column reads consistently down
    /// the page regardless of which phases this exercise actually has
    /// history in. A phase with no qualifying set gets a row with `result
    /// == nil` (rendered as "No Data") rather than being skipped — a
    /// visible gap is the point, since it shows where the lift wasn't
    /// being trained. The All-Time row's numbers will often duplicate
    /// whichever phase row actually set them — that's intended: it's what
    /// lets a phase's own numbers be read against the lifetime best
    /// sitting right above them.
    let rows: [BigLiftScopeRow]
}

/// One row within a BigLiftGroup: "All-Time" or "Phase N" paired with that
/// scope's own Heaviest/Est. 1RM — nil if the phase has no qualifying set
/// for this exercise at all ("No Data").
struct BigLiftScopeRow: Identifiable {
    var id: String { scopeLabel }
    let scopeLabel: String
    let result: BigLiftResult?
}

/// One flagged exercise's two headline numbers within one phase, or across
/// all of history — see StatsEngine.bigLiftResult's own doc for exactly
/// which sets qualify.
struct BigLiftResult: Identifiable {
    var id: String { name }
    let name: String
    /// The weight of the heaviest single set actually performed — NOT a
    /// 1-rep-max estimate, just the biggest load outright, regardless of
    /// reps. Reps aren't tracked here — they were only ever for display and
    /// aren't shown — so a weight tie is broken purely by the LATER date
    /// (the most recent time the number was hit).
    let heaviestWeight: Double
    /// The session date of the set that produced heaviestWeight.
    let heaviestDate: Date
    /// The highest Epley-formula estimate (PaceEngine.epley1RM) across
    /// every qualifying set in the phase — not necessarily the heaviest
    /// set's own estimate, since a lighter set done for more reps can imply
    /// a bigger 1RM (e.g. 160x8 estimates higher than 170x5).
    let estimatedOneRepMax: Double
    /// The session date of the set that produced estimatedOneRepMax — often
    /// a different set (and date) than heaviestDate, since the two numbers
    /// aren't necessarily won by the same set.
    let estimatedOneRepMaxDate: Date
}

/// One calendar year's row in the Stats page's "By Year" table. Only years
/// that actually have something in them get one — see StatsEngine.compute's
/// own note on how the year set is assembled.
struct YearTotal: Identifiable {
    var id: Int { year }
    let year: Int
    /// DISTINCT CALENDAR DAYS on which the user did something that year —
    /// trained, walked, or both. Deliberately a day count, not a session
    /// count: a training session and a walk logged on the same date are
    /// one active day, not two. Same basis as
    /// `TrainingStats.allTimeActiveDayCount`, so the per-year column sums
    /// to that lifetime figure.
    let activeDayCount: Int
    /// Same `milesSum(from:through:)` helper every other miles figure on
    /// the page goes through, just bounded to this year — so this column
    /// can never disagree with allTimeMiles/ytdMiles.
    let milesWalked: Double
}

/// One day-template-grouped block in the Stats page's "Workout Duration"
/// section — the day name is the group's own header, same shape as
/// BigLiftGroup with the exercise name promoted to a header.
struct DayDurationGroup: Identifiable {
    var id: String { dayName }
    let dayName: String
    /// All-Time first, then every phase (completed or active), descending
    /// by phase number — same convention as BigLiftGroup.rows, including a
    /// "No Data" row (`result == nil`) for a phase with no qualifying
    /// session for this day, rather than skipping it.
    let rows: [DayDurationScopeRow]
}

/// One row within a DayDurationGroup: "All-Time" or "Phase N" paired with
/// that scope's own Shortest/Average/Longest — nil if the phase has no
/// session with a recorded duration for this day at all ("No Data").
struct DayDurationScopeRow: Identifiable {
    var id: String { scopeLabel }
    let scopeLabel: String
    let result: DayDurationResult?
}

/// One day template's duration spread within one phase, or across all of
/// history — see StatsEngine.dayDurationResult's own doc for exactly which
/// sessions qualify.
struct DayDurationResult {
    let shortestSeconds: Int
    let averageSeconds: Double
    let longestSeconds: Int
}

enum StatsEngine {
    /// A phase's one-cycle day template pinned to the calendar day it started,
    /// purely so stats can tell whether a given past date was a scheduled Rest day.
    struct PhaseSchedule {
        let startDate: Date
        let restFlags: [Bool]   // per position in one cycle: is this a Rest day?
        init(startDate: Date, phase: Phase) {
            self.startDate = startDate
            self.restFlags = phase.orderedDays.map(\.isRest)
        }
    }

    /// Whether `day` was a scheduled Rest day under whichever phase covers it —
    /// nil if no phase was active yet that day.
    private static func isScheduledRestDay(_ day: Date, schedules: [PhaseSchedule], cal: Calendar) -> Bool? {
        let covering = schedules
            .filter { cal.startOfDay(for: $0.startDate) <= day }
            .max { $0.startDate < $1.startDate }
        guard let phase = covering, !phase.restFlags.isEmpty else { return nil }
        let offset = cal.dateComponents([.day], from: cal.startOfDay(for: phase.startDate), to: day).day ?? 0
        guard offset >= 0 else { return nil }
        return phase.restFlags[offset % phase.restFlags.count]
    }

    static func compute(startDate: Date,
                        sessionDates: [Date],
                        restActivityDates: [Date] = [],
                        activeRecoveryDates: [Date] = [],
                        phaseSchedules: [PhaseSchedule] = [],
                        allPhases: [Phase] = [],
                        activePhase: Phase? = nil,
                        restActivities: [RestDayActivity] = [],
                        trainingDaysPerWeekChanges: [(date: Date, value: Int)] = [],
                        defaultTrainingDaysPerWeek: Int = 3,
                        allSessions: [WorkoutSession] = [],
                        bigLiftNames: [String] = [],
                        now: Date = .now) -> TrainingStats {
        let cal = Calendar.current
        let start = cal.startOfDay(for: startDate)
        let today = cal.startOfDay(for: now)
        var iterations = 0

        // Today only counts toward day-based stats (days since start, cycle
        // pace, adherence) once something's actually been logged for it — a
        // workout, a rest-day activity, or a plain rest-day credit — same
        // "pending until logged" rule the rest bank already applies to
        // today's streak credit. Until then, treat "now" as yesterday so a
        // still-open day doesn't drag the denominator down or make today's
        // not-yet-logged workout look missed.
        let loggedToday = (sessionDates + restActivityDates + activeRecoveryDates)
            .contains { cal.isDate($0, inSameDayAs: today) }
        let effectiveNow = loggedToday ? now : (cal.date(byAdding: .day, value: -1, to: today) ?? now)
        let effectiveToday = cal.startOfDay(for: effectiveNow)

        let loggedDays = Set((sessionDates + restActivityDates).map { cal.startOfDay(for: $0) })
            .filter { $0 >= start && $0 <= today }

        let daysSinceStart = max(1, (cal.dateComponents([.day], from: start, to: effectiveToday).day ?? 0) + 1)

        // sessionDates includes rest-day-activity sessions too (an activity
        // gets a real ExerciseLog same as training) — pull those back out so
        // the bank engine sees them as activity-rest, not neutral training.
        let activityRestSet = Set(restActivityDates.map { cal.startOfDay(for: $0) })
        let trainingDates = sessionDates.filter { !activityRestSet.contains(cal.startOfDay(for: $0)) }
        let resetEvents = allPhases.flatMap(\.restBankResetEvents)
        let bank = computeRestBank(trainingDates: trainingDates,
                                   activityRestDates: restActivityDates,
                                   plainRestDates: activeRecoveryDates,
                                   resetEvents: resetEvents, now: now)
        let cyclePace = activePhase.map { cyclePaceDelta(for: $0, now: effectiveNow) }
        let adherence = activePhase.map { adherencePercent(for: $0, now: effectiveNow) }

        let daysLogged = loggedDays.count
        let pct = Double(daysLogged) / Double(daysSinceStart)
        let weeks = Double(daysSinceStart) / 7.0
        let perWeek = weeks > 0 ? Double(daysLogged) / weeks : 0

        // The Total / Lift / Walk partition of `loggedDays`, all three
        // sharing that same window and `weeks` denominator so the row's
        // columns are directly comparable and Lift + Walk == Total.
        //
        // ONE pass over sessions: lift days are collected in that pass,
        // and walk-only days fall out as a set difference rather than a
        // second scan. Needs `allSessions` rather than `sessionDates`
        // because the lift-vs-activity distinction lives in the logs, and
        // sessionDates is only dates by the time it reaches here.
        //
        // Intersected with loggedDays before the subtraction so the
        // identity holds structurally rather than by assumption — every
        // lifting session is exercise-bearing and so already in
        // loggedDays, but a caller passing `allSessions` without the
        // matching `sessionDates` would otherwise push Lift above Total.
        // Deliberately NOT built from `trainingDates`, which drops a whole
        // date that has any RestDayActivity on it: that would lose a day
        // you both lifted and walked, and break the identity outright.
        let liftDays = Set(allSessions.filter(\.hasLiftingLog).map { cal.startOfDay(for: $0.date) })
            .intersection(loggedDays)
        let walkOnlyDays = loggedDays.subtracting(liftDays)
        let liftPerWeek = weeks > 0 ? Double(liftDays.count) / weeks : 0
        let walkPerWeek = weeks > 0 ? Double(walkOnlyDays.count) / weeks : 0

        // Distinct calendar days with a qualifying session on them — the
        // shared basis for YTD/MTD counts, allTimeActiveDayCount, and
        // yearlyTotals, so all three mean the same thing. Collapsing to
        // days is what makes a training session and a walk logged on the
        // same date count once rather than twice.
        let activeDays = Set(sessionDates.map { cal.startOfDay(for: $0) })
        let allTimeActiveDayCount = activeDays.count
        let activeStreaks = activeDayStreaks(activeDays: activeDays, today: today, cal: cal)

        // Perfect-cycle progress needs an active phase to judge cycles
        // against its split pattern — with none, fall back to a simpler,
        // phase-independent perfect-week count instead.
        let perfectCycleLifetimeCount: Int?
        let perfectCycleCurrentStreak: Int?
        let activePhaseCycleProgress: ActivePhaseCycleProgress?
        let perfectWeekFallback: PerfectWeekFallback?
        if let activePhase {
            let allFlags = allPhases.sorted { $0.startDate < $1.startDate }.flatMap { $0.perfectCycleFlags }
            perfectCycleLifetimeCount = allFlags.filter { $0 }.count
            var streak = 0
            for flag in allFlags.reversed() {
                if flag { streak += 1 } else { break }
            }
            perfectCycleCurrentStreak = streak
            let flags = activePhase.perfectCycleFlags
            activePhaseCycleProgress = ActivePhaseCycleProgress(number: activePhase.number,
                                                                perfectCount: flags.filter { $0 }.count,
                                                                completedCount: flags.count)
            perfectWeekFallback = nil
        } else {
            perfectCycleLifetimeCount = nil
            perfectCycleCurrentStreak = nil
            activePhaseCycleProgress = nil
            perfectWeekFallback = computePerfectWeekFallback(workoutDays: activeDays, start: start, today: today,
                                                             trainingDaysPerWeekChanges: trainingDaysPerWeekChanges,
                                                             defaultTrainingDaysPerWeek: defaultTrainingDaysPerWeek)
        }
        // Same "today is pending" rule as effectiveToday above — if today
        // hasn't been logged yet, the prior-year comparison shouldn't
        // include the prior-year equivalent of a day that hasn't happened
        // yet this year either.
        let priorYearToday = cal.date(byAdding: .year, value: -1, to: effectiveToday) ?? effectiveToday

        func dayCount(from windowStart: Date, through windowEnd: Date) -> Int {
            activeDays.filter { $0 >= windowStart && $0 <= windowEnd }.count
        }
        let yearStart = cal.date(from: cal.dateComponents([.year], from: today)) ?? today
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: today)) ?? today
        let priorYearStart = cal.date(from: cal.dateComponents([.year], from: priorYearToday)) ?? priorYearToday
        let priorYearMonthStart = cal.date(from: cal.dateComponents([.year, .month], from: priorYearToday)) ?? priorYearToday

        let ytdWorkoutDays = dayCount(from: yearStart, through: today)
        let mtdWorkoutDays = dayCount(from: monthStart, through: today)
        let priorYearYtdWorkoutDays = dayCount(from: priorYearStart, through: priorYearToday)
        let priorYearMtdWorkoutDays = dayCount(from: priorYearMonthStart, through: priorYearToday)

        // Miles walked — only entries whose distanceUnit is literally "mi";
        // an imported/logged non-mile unit (e.g. "km") isn't converted, just
        // excluded from these totals.
        let milesEntries: [(day: Date, miles: Double)] = restActivities.compactMap { activity in
            guard let distance = activity.distance, activity.distanceUnit.lowercased() == "mi" else { return nil }
            return (cal.startOfDay(for: activity.date), distance)
        }
        func milesSum(from windowStart: Date, through windowEnd: Date) -> Double {
            milesEntries.filter { $0.day >= windowStart && $0.day <= windowEnd }.map(\.miles).reduce(0, +)
        }
        let milesSinceStart = milesSum(from: start, through: today)
        let milesThisPhase = activePhase.map { milesSum(from: cal.startOfDay(for: $0.startDate), through: today) }
        let ytdMiles = milesSum(from: yearStart, through: today)
        let mtdMiles = milesSum(from: monthStart, through: today)
        let priorYearYtdMiles = milesSum(from: priorYearStart, through: priorYearToday)
        let priorYearMtdMiles = milesSum(from: priorYearMonthStart, through: priorYearToday)
        let allTimeMiles = milesEntries.map(\.miles).reduce(0, +)

        // Per-year totals, newest first. A year qualifies on having either
        // an active day or any miles — no padding of empty years between
        // sparse ones, and a year with nothing in it never appears.
        //
        // The first column counts DISTINCT CALENDAR DAYS, not sessions.
        // Which sessions qualify is `sessionDates` — every exercise-bearing
        // session, which INCLUDES rest-day activities (a walk gets a real
        // ExerciseLog just like training — see the activityRestSet note
        // further up) and EXCLUDES both backfilled Rest Day placeholders
        // and plain "Log Rest Day" credits, since neither has any exercise
        // log at all (StatsView's realSessionDates filters those before we
        // ever see them). Those qualifying sessions are then collapsed to
        // one entry per calendar day.
        //
        // That collapse is the whole point: a training session and a walk
        // logged on the same date are two sessions but one active day.
        // Real data had 224 qualifying 2025 sessions across 167 distinct
        // days — 57 dates carrying exactly one training session plus one
        // walk each, all from a CSV import that wrote the walk as its own
        // session. `allTimeActiveDayCount` is built from the same
        // `activeDays` set, so these per-year figures sum to it exactly.
        //
        // Miles go through milesSum, same as every other miles figure
        // here, just bounded to the year.
        let activeDayYears = activeDays.map { cal.component(.year, from: $0) }
        let yearsWithActiveDays = Set(activeDayYears)
        let yearsWithMiles = Set(milesEntries.map { cal.component(.year, from: $0.day) })
        let yearlyTotals: [YearTotal] = yearsWithActiveDays.union(yearsWithMiles)
            .sorted(by: >)
            .compactMap { year -> YearTotal? in
                guard let yearFirstDay = cal.date(from: DateComponents(year: year, month: 1, day: 1)),
                      let yearLastDay = cal.date(from: DateComponents(year: year, month: 12, day: 31))
                else { return nil }
                return YearTotal(year: year,
                                 activeDayCount: activeDayYears.filter { $0 == year }.count,
                                 milesWalked: milesSum(from: yearFirstDay, through: yearLastDay))
            }

        // Full-year projection of the current year, built off a ROLLING
        // 3-MONTH pace rather than the whole year's average: whatever is
        // already banked, plus the last 3 months' per-day rate applied to
        // the days still left in the year.
        //
        // Banked actuals are never re-estimated — only the remaining days
        // are projected — so the projection can never read below what's
        // already happened, and a strong start doesn't get averaged away
        // by a quiet stretch (or vice versa). Using the trailing window
        // rather than the year-to-date rate is the point: it answers
        // "where does my CURRENT pace land me," which is what changes
        // week to week.
        //
        // The window clamps to Jan 1, so for the first three months of a
        // year it's simply the year so far — which makes this a strict
        // generalization of the plain year-to-date run rate it replaced,
        // not a different rule that kicks in at some threshold.
        //
        // Both the window's end and daysElapsed use effectiveToday, not
        // today, for the same reason daysSinceStart/cyclePaceDelta do:
        // until something's logged for today, counting it as a full
        // elapsed day would drag the rate down by a day that hasn't
        // happened yet.
        //
        // nil in two cases, both deliberate: fewer than 14 days elapsed
        // in the year (a rate off one or two days extrapolates to
        // nonsense — two weeks is the shortest window where a training
        // rate means anything), and the year already being complete (on
        // Dec 31 there are no remaining days to project into, so the
        // "projection" would just restate the actual).
        let currentYear = cal.component(.year, from: today)
        let currentYearProjection: YearTotal? = {
            guard let actual = yearlyTotals.first(where: { $0.year == currentYear }),
                  let yearFirstDay = cal.date(from: DateComponents(year: currentYear, month: 1, day: 1)),
                  let yearLastDay = cal.date(from: DateComponents(year: currentYear, month: 12, day: 31))
            else { return nil }
            let daysElapsed = (cal.dateComponents([.day], from: yearFirstDay, to: effectiveToday).day ?? 0) + 1
            let daysInYear = (cal.dateComponents([.day], from: yearFirstDay, to: yearLastDay).day ?? 364) + 1
            guard daysElapsed >= 14, daysElapsed < daysInYear else { return nil }

            let threeMonthsBack = cal.date(byAdding: .month, value: -3, to: effectiveToday) ?? yearFirstDay
            let windowStart = max(yearFirstDay, threeMonthsBack)
            let windowDays = (cal.dateComponents([.day], from: windowStart, to: effectiveToday).day ?? 0) + 1
            guard windowDays >= 1 else { return nil }

            let windowActiveDays = activeDays.filter { $0 >= windowStart && $0 <= effectiveToday }.count
            let windowMiles = milesSum(from: windowStart, through: effectiveToday)
            let daysRemaining = Double(daysInYear - daysElapsed)
            let activeDaysPerDay = Double(windowActiveDays) / Double(windowDays)
            let milesPerDay = windowMiles / Double(windowDays)

            return YearTotal(year: currentYear,
                             activeDayCount: actual.activeDayCount
                                 + Int((activeDaysPerDay * daysRemaining).rounded()),
                             milesWalked: actual.milesWalked + milesPerDay * daysRemaining)
        }()

        // Hours trained — sum of durationSeconds across every non-deload
        // session that has one. A session predating duration tracking (or
        // one where the workout stopwatch was never started) has
        // durationSeconds == nil and is excluded from the sum entirely, not
        // counted as 0 — same "omit rather than show a false number" rule
        // as everywhere else here. A deload session is excluded the same
        // way: its cut weights already skew comparisons elsewhere (see
        // comparisons(for:...)'s own deload-matching doc), and its duration
        // shouldn't quietly pull this average down either — excluded from
        // the input, not folded in as a 0. allSessions, not just
        // realSessionDates' filtered set, since a genuine (non-rest-
        // placeholder) session with no exerciseLogs shouldn't happen once
        // it has a duration anyway.
        let allTimeHoursTrained = Double(allSessions.filter { !$0.isDeload }.compactMap(\.durationSeconds).reduce(0, +)) / 3600

        // Completed, no-longer-active phases get their own frozen summary,
        // anchored to that phase's own end date (its last session) instead
        // of `now` — cyclePaceDelta/adherencePercent both derive daysElapsed
        // as startDate -> now, so passing `now` for a finished phase would
        // make its "final" pace and adherence keep getting worse forever
        // after the fact. `isComplete && !isActive` (not just `!isActive`
        // alone) excludes a phase built ahead of time but never started,
        // which is also inactive but has no sessions to summarize. A phase
        // that's complete but somehow has no sessions at all is skipped
        // rather than guessing an end date — shouldn't normally happen
        // since completing a cycle requires logging into it.
        let completedPhaseSummaries: [PhaseSummary] = allPhases
            .filter { $0.isComplete && !$0.isActive }
            .compactMap { phase -> PhaseSummary? in
                guard let endDate = phase.sessions.map(\.date).max() else { return nil }
                let flags = phase.perfectCycleFlags
                return PhaseSummary(number: phase.number,
                                    startDate: phase.startDate,
                                    endDate: endDate,
                                    cyclePaceDelta: cyclePaceDelta(for: phase, now: endDate),
                                    adherencePercent: adherencePercent(for: phase, now: endDate),
                                    perfectCount: flags.filter { $0 }.count,
                                    completedCount: flags.count,
                                    milesWalked: milesSum(from: cal.startOfDay(for: phase.startDate),
                                                          through: cal.startOfDay(for: endDate)))
            }
            .sorted { $0.number > $1.number }

        // Big Lifts — one group per flagged exercise with a qualifying set
        // ANYWHERE (all-time; a name with none anywhere is omitted
        // entirely), each an All-Time row plus one row for EVERY phase —
        // completed phases (same criterion as completedPhaseSummaries
        // above) PLUS the active one, so a lift still being trained this
        // phase shows up too, not just phases already wrapped up. Every
        // phase gets a row regardless of whether IT has a qualifying set,
        // so the column reads consistently down the page — a phase with
        // none shows "No Data" (see BigLiftScopeRow) rather than being
        // skipped. Sessions with no phase attached (manual/imported
        // entries) only ever surface through the All-Time row.
        let bigLiftPhases = allPhases
            .filter { $0.isActive || ($0.isComplete && !$0.isActive) }
            .sorted { $0.number > $1.number }
        let bigLiftGroups: [BigLiftGroup] = bigLiftNames.compactMap { name -> BigLiftGroup? in
            guard let allTime = bigLiftResult(named: name, in: allSessions) else { return nil }
            var rows = [BigLiftScopeRow(scopeLabel: "All-Time", result: allTime)]
            for phase in bigLiftPhases {
                rows.append(BigLiftScopeRow(scopeLabel: "Phase \(phase.number)",
                                            result: bigLiftResult(named: name, in: phase.sessions)))
            }
            return BigLiftGroup(exerciseName: name, rows: rows)
        }

        // Workout duration per day template — same All-Time-then-phases
        // shape as Big Lifts, reusing bigLiftPhases' own active+completed
        // scope for the phase rows. Grouped by dayLabel (a String snapshot,
        // not the `day` relationship): each phase builds its own distinct
        // PhaseDay rows even when reusing the same template name (e.g.
        // "Lower Day 1" in Phase 1 and Phase 2 are two different PhaseDay
        // objects), so grouping by the relationship would split the same
        // split's history across phases instead of tracking it across
        // them — dayLabel is the one identity that's already meant to
        // survive exactly that (see its own doc: "survives the day being
        // renamed/deleted"). Day names are enumerated from bigLiftPhases'
        // own templates (most-recent phase first), not from what happens to
        // appear in session history, mirroring how bigLiftNames itself
        // comes from the exercise library rather than logged history.
        var seenDayNames = Set<String>()
        let dayNames: [String] = bigLiftPhases
            .flatMap { phase in phase.orderedDays.filter { !$0.isRest }.map(\.name) }
            .filter { seenDayNames.insert($0).inserted }
        //
        // Built twice over the same day names — once from normal sessions,
        // once from deload ones — for the section's two swipe pages. A day
        // with nothing on one side is simply absent from that page rather
        // than shown as an all-"No Data" group.
        func durationGroups(deloadOnly: Bool) -> [DayDurationGroup] {
            dayNames.compactMap { name -> DayDurationGroup? in
                guard let allTime = dayDurationResult(named: name, in: allSessions,
                                                      deloadOnly: deloadOnly) else { return nil }
                var rows = [DayDurationScopeRow(scopeLabel: "All-Time", result: allTime)]
                for phase in bigLiftPhases {
                    rows.append(DayDurationScopeRow(scopeLabel: "Phase \(phase.number)",
                                                    result: dayDurationResult(named: name, in: phase.sessions,
                                                                              deloadOnly: deloadOnly)))
                }
                return DayDurationGroup(dayName: name, rows: rows)
            }
        }
        let dayDurationGroups = durationGroups(deloadOnly: false)
        let deloadDayDurationGroups = durationGroups(deloadOnly: true)

        // Perfect weeks/months: walk day-by-day again, bucketing
        // scheduled-vs-logged training days by week and by month. Bounded to
        // [start, today] since "scheduled" is only meaningful within the
        // tracked training window.
        struct Bucket { var scheduled = 0; var logged = 0 }
        var weekBuckets: [DateComponents: Bucket] = [:]
        var monthBuckets: [DateComponents: Bucket] = [:]
        var walk = start
        iterations = 0
        while walk <= today, iterations < 20_000 {
            iterations += 1
            let scheduledRest = isScheduledRestDay(walk, schedules: phaseSchedules, cal: cal)
            let isTrainingDay = scheduledRest == false
            let wasLogged = activeDays.contains(walk)
            let weekKey = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: walk)
            let monthKey = cal.dateComponents([.year, .month], from: walk)

            if isTrainingDay {
                weekBuckets[weekKey, default: Bucket()].scheduled += 1
                monthBuckets[monthKey, default: Bucket()].scheduled += 1
                if wasLogged {
                    weekBuckets[weekKey, default: Bucket()].logged += 1
                    monthBuckets[monthKey, default: Bucket()].logged += 1
                }
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: walk) else { break }
            walk = next
        }

        let currentWeekKey = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: today)
        let currentMonthKey = cal.dateComponents([.year, .month], from: today)

        let perfectWeeks = weekBuckets.filter { key, bucket in
            key != currentWeekKey && bucket.scheduled > 0 && bucket.logged == bucket.scheduled
        }.count
        let perfectMonths = monthBuckets.filter { key, bucket in
            key != currentMonthKey && bucket.scheduled > 0 && bucket.logged == bucket.scheduled
        }.count

        // Best month all-time: tallied directly from every logged workout
        // date, independent of `start` (Training Start Date) — a month of
        // real history (e.g. from an import) shouldn't be invisible just
        // because it happened before that setting's date.
        var allTimeMonthCounts: [DateComponents: Int] = [:]
        for dayLogged in activeDays {
            let monthKey = cal.dateComponents([.year, .month], from: dayLogged)
            allTimeMonthCounts[monthKey, default: 0] += 1
        }
        var bestMonthLabel: String?
        var bestMonthWorkouts = 0
        if let best = allTimeMonthCounts.filter({ $0.key != currentMonthKey })
            .max(by: { $0.value < $1.value }),
           best.value > 0 {
            bestMonthWorkouts = best.value
            if let monthDate = cal.date(from: best.key) {
                let f = DateFormatter()
                f.dateFormat = "MMMM yyyy"
                bestMonthLabel = f.string(from: monthDate)
            }
        }

        return TrainingStats(daysSinceStart: daysSinceStart,
                             daysLogged: daysLogged,
                             currentStreak: bank.currentStreak,
                             maxStreak: bank.maxStreak,
                             maxStreakRange: bank.maxStreakRange,
                             currentStreakStartDate: bank.currentStreakStartDate,
                             currentActiveStreak: activeStreaks.current,
                             currentActiveStreakStartDate: activeStreaks.currentStart,
                             maxActiveStreak: activeStreaks.max,
                             maxActiveStreakRange: activeStreaks.maxRange,
                             bankBalance: bank.bankBalance,
                             percentLogged: pct,
                             daysPerWeek: perWeek,
                             liftDaysPerWeek: liftPerWeek,
                             walkDaysPerWeek: walkPerWeek,
                             ytdWorkoutDays: ytdWorkoutDays,
                             priorYearYtdWorkoutDays: priorYearYtdWorkoutDays,
                             mtdWorkoutDays: mtdWorkoutDays,
                             priorYearMtdWorkoutDays: priorYearMtdWorkoutDays,
                             perfectWeeks: perfectWeeks,
                             perfectMonths: perfectMonths,
                             bestMonthLabel: bestMonthLabel,
                             bestMonthWorkouts: bestMonthWorkouts,
                             cyclePaceDelta: cyclePace,
                             adherencePercent: adherence,
                             perfectCycleLifetimeCount: perfectCycleLifetimeCount,
                             perfectCycleCurrentStreak: perfectCycleCurrentStreak,
                             activePhaseCycleProgress: activePhaseCycleProgress,
                             perfectWeekFallback: perfectWeekFallback,
                             milesSinceStart: milesSinceStart,
                             milesThisPhase: milesThisPhase,
                             ytdMiles: ytdMiles,
                             priorYearYtdMiles: priorYearYtdMiles,
                             mtdMiles: mtdMiles,
                             priorYearMtdMiles: priorYearMtdMiles,
                             allTimeMiles: allTimeMiles,
                             allTimeActiveDayCount: allTimeActiveDayCount,
                             allTimeHoursTrained: allTimeHoursTrained,
                             completedPhaseSummaries: completedPhaseSummaries,
                             bigLiftGroups: bigLiftGroups,
                             dayDurationGroups: dayDurationGroups,
                             deloadDayDurationGroups: deloadDayDurationGroups,
                             yearlyTotals: yearlyTotals,
                             currentYearProjection: currentYearProjection)
    }

    /// Fallback progress stat for when there's no active phase to judge
    /// cycles against a split pattern: counts a plain Mon-Sun calendar week
    /// as perfect once its logged-session count meets whatever training-
    /// days-per-week setting was in effect that week (own change history,
    /// looked up the same "latest change at or before this date" way as
    /// any other dated setting). Bounded to [start, today] like the rest of
    /// consistency stats, and
    /// forces a Monday-first calendar regardless of the device's locale,
    /// since "Mon-Sun" is part of the definition, not just a display choice.
    private static func computePerfectWeekFallback(workoutDays: Set<Date>, start: Date, today: Date,
                                                   trainingDaysPerWeekChanges: [(date: Date, value: Int)],
                                                   defaultTrainingDaysPerWeek: Int) -> PerfectWeekFallback {
        var mondayCal = Calendar.current
        mondayCal.firstWeekday = 2
        func required(on date: Date) -> Int {
            let applicable = trainingDaysPerWeekChanges.filter { $0.date <= date }.max { $0.date < $1.date }
            return applicable?.value ?? defaultTrainingDaysPerWeek
        }

        var weekCounts: [DateComponents: Int] = [:]
        var weekStarts: [DateComponents: Date] = [:]
        var walk = start
        var iterations = 0
        while walk <= today, iterations < 20_000 {
            iterations += 1
            let key = mondayCal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: walk)
            weekCounts[key, default: 0] += workoutDays.contains(walk) ? 1 : 0
            if weekStarts[key] == nil {
                weekStarts[key] = mondayCal.date(from: key) ?? walk
            }
            guard let next = mondayCal.date(byAdding: .day, value: 1, to: walk) else { break }
            walk = next
        }

        let currentWeekKey = mondayCal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: today)
        let orderedWeeks = weekCounts.keys
            .filter { $0 != currentWeekKey }
            .compactMap { key -> (weekStart: Date, count: Int)? in
                guard let weekStart = weekStarts[key] else { return nil }
                return (weekStart, weekCounts[key] ?? 0)
            }
            .sorted { $0.weekStart < $1.weekStart }

        let flags = orderedWeeks.map { $0.count >= required(on: $0.weekStart) }
        let lifetime = flags.filter { $0 }.count
        var streak = 0
        for flag in flags.reversed() {
            if flag { streak += 1 } else { break }
        }
        return PerfectWeekFallback(lifetimeCount: lifetime, currentStreak: streak)
    }

    /// Plain consecutive-days-with-activity streaks — current (ending today,
    /// or yesterday if today isn't logged yet) and all-time max.
    ///
    /// Deliberately its own walk, NOT a parameterization of
    /// `computeRestBank` below. The two model different things and share no
    /// logic: the rest bank is a ledger where training is neutral, rest days
    /// spend from a balance, and a streak survives a rest day for as long as
    /// the balance holds. This has no bank, no ledger and no concept of
    /// rest — a day is either active or it isn't, and the first inactive day
    /// ends the run. Folding them together would mean one of the two
    /// silently acquiring the other's semantics on a future edit.
    ///
    /// `activeDays` is the same day-collapsed set `allTimeActiveDayCount`
    /// and `yearlyTotals` are built from, so all three agree on what counts:
    /// a training session or a logged rest-day activity (a walk) makes a day
    /// active; a backfilled Rest Day placeholder, a plain "Log Rest Day"
    /// credit, and a day with no session at all are all inactive, since none
    /// of them has any exercise log (StatsView's realSessionDates filters
    /// those out before compute ever sees them).
    ///
    /// Today in progress does NOT break the current streak: if nothing's
    /// logged for it yet the walk starts from yesterday instead, matching
    /// the "today is pending until logged" rule daysSinceStart,
    /// cyclePaceDelta and the rest bank all already use. A genuinely broken
    /// streak still reads 0 — that's when yesterday is inactive too.
    static func activeDayStreaks(activeDays: Set<Date>, today: Date,
                                 cal: Calendar = .current)
    -> (current: Int, max: Int, maxRange: MaxStreakDateRange?, currentStart: Date?) {
        guard !activeDays.isEmpty else { return (0, 0, nil, nil) }

        var current = 0
        // The earliest day of the currently-open run. Assigned on every
        // step of the walk below, which moves backwards, so the final
        // value is the run's first day — and it stays nil when the loop
        // never runs at all, i.e. when the streak is 0.
        var currentStart: Date?
        // Start on today only if it's already active; otherwise step back a
        // day so an as-yet-unlogged today doesn't read as a break.
        var cursor = activeDays.contains(today)
            ? today
            : (cal.date(byAdding: .day, value: -1, to: today) ?? today)
        // The last active day of the currently-open run, if there is one —
        // what the max run is compared against below to tell whether the
        // record IS the ongoing streak.
        let currentRunEnd: Date? = activeDays.contains(cursor) ? cursor : nil
        var iterations = 0
        while activeDays.contains(cursor), iterations < 20_000 {
            iterations += 1
            current += 1
            currentStart = cursor
            guard let previous = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }

        let sortedDays = activeDays.sorted()
        var maxRun = 0
        var run = 0
        var runStart: Date?
        var maxStart: Date?
        var maxEnd: Date?
        var previousDay: Date?
        for day in sortedDays {
            if let previousDay,
               cal.dateComponents([.day], from: previousDay, to: day).day == 1 {
                run += 1
            } else {
                run = 1
                runStart = day
            }
            // >= not >, so a later run that TIES takes over the record —
            // matching computeRestBank's own tie rule (its `streak ==
            // maxStreak` check passes on a tie and hands the record to the
            // newer instance). Keeps the more useful of two equal spans:
            // if the tie is with the run still in progress, the record
            // reads "– Present" rather than pointing at old history.
            if run >= maxRun {
                maxRun = run
                maxStart = runStart
                maxEnd = day
            }
            previousDay = day
        }

        guard let maxStart, let maxEnd else { return (current, maxRun, nil, currentStart) }
        // Ongoing exactly when the record run ends on the current run's
        // last active day — then followingBreakDate stays nil, which is
        // how MaxStreakDateRange already spells "still open".
        let isOngoing = currentRunEnd != nil && maxEnd == currentRunEnd
        let range = MaxStreakDateRange(
            start: maxStart,
            end: maxEnd,
            // The inactive day that ended whatever came before this run —
            // nil when the run opens the whole history, so there was no
            // prior streak for it to have closed.
            precedingBreakDate: maxStart == sortedDays.first
                ? nil
                : cal.date(byAdding: .day, value: -1, to: maxStart),
            followingBreakDate: isOngoing
                ? nil
                : cal.date(byAdding: .day, value: 1, to: maxEnd))
        return (current, maxRun, range, currentStart)
    }

    // MARK: - Rest bank (reset-based: bank resets to restDaysPerCycle at phase start/cycle finish, spent by rest days)

    struct RestBankResult {
        var currentStreak: Int
        var maxStreak: Int
        var bankBalance: Double
        var maxStreakRange: MaxStreakDateRange?
        /// When the currently-open streak began — nil once currentStreak is 0.
        var currentStreakStartDate: Date?
    }

    /// Pure day-by-day walk of the rest-bank model. The bank only ever
    /// moves via `resetEvents` (SET, not added — the bank becomes exactly
    /// this value — the day a phase's first session is logged, and again
    /// the day each of its cycles finishes except the last; see
    /// `Phase.restBankResetEvents`) and rest days, which spend from it: an
    /// activity-logged rest costs 0.5, a plain/unscheduled rest (or a day
    /// with nothing logged at all, while the ledger is open) costs 1.0.
    /// Training is bank-neutral.
    ///
    /// A day's own spend is always evaluated against whatever the bank
    /// already was coming into it — a reset lands AFTER that, unconditionally
    /// overwriting the result (not topping it up, and not re-deducting
    /// today's spend from it again). That matters most on a cycle's last
    /// day: e.g. bank 0.5, a plain rest (-1.0) goes negative, breaking the
    /// streak (bank clamped to 0) — but since this is also the cycle's
    /// finish, the bank still ends the day reset to `restDaysPerCycle`, not
    /// 0. If instead that last day is an activity rest, it grows the streak
    /// (or restarts it at 1, not 0, if the pre-reset spend broke it) since
    /// activity days always count, and the bank still ends reset. A bare
    /// reset landing on an otherwise uncredited day only applies if the
    /// ledger is already open going into it — it can't spontaneously open
    /// one on its own.
    ///
    /// The streak count itself only increases for a training day or an
    /// activity-logged rest — a plain/unscheduled rest "does nothing": it
    /// still spends from the bank (and can still break the streak if that
    /// spend goes negative), it just doesn't add to the count on its own.
    ///
    /// Outside of a reset, the bank never goes negative: the moment a spend
    /// would take it below 0, the streak breaks right there and the ledger
    /// closes — bank sits at a clean 0, and no further uncredited or rest
    /// days do anything (no more spending) until the next credited day
    /// starts a brand-new streak, fresh at 0 rather than inheriting
    /// whatever debt was left. Today is left pending — neither spent nor
    /// credited — if nothing's logged yet.
    static func computeRestBank(trainingDates: [Date],
                                activityRestDates: [Date],
                                plainRestDates: [Date],
                                resetEvents: [(date: Date, resetTo: Double)],
                                now: Date = .now) -> RestBankResult {
        let cal = Calendar.current
        let training = Set(trainingDates.map { cal.startOfDay(for: $0) })
        let activityRest = Set(activityRestDates.map { cal.startOfDay(for: $0) })
        let plainRest = Set(plainRestDates.map { cal.startOfDay(for: $0) })
        var resetByDay: [Date: Double] = [:]
        for event in resetEvents {
            resetByDay[cal.startOfDay(for: event.date)] = event.resetTo
        }
        let today = cal.startOfDay(for: now)
        guard let firstDay = (training.union(activityRest).union(plainRest)).min() else {
            return RestBankResult(currentStreak: 0, maxStreak: 0, bankBalance: 0, maxStreakRange: nil, currentStreakStartDate: nil)
        }

        var bank = 0.0
        var streakOpen = false
        var streak = 0
        var maxStreak = 0
        var day = firstDay
        var iterations = 0

        // Tracks the actual date range of whichever streak instance holds
        // the record, plus its boundary break days, so a stat like "Max
        // Streak: 51" can be traced back to exactly which 51 days (and
        // what broke it on either side) — see MaxStreakDateRange.
        var currentStreakStart: Date?
        var lastBreakDate: Date?
        var maxStreakStartDate: Date?
        var maxStreakEndDate: Date?
        var maxStreakPrecedingBreakDate: Date?
        var maxStreakFollowingBreakDate: Date?

        // Only true once streak has just tied/exceeded the record — a
        // streak that's still smaller than the historical max leaves
        // maxStreak (and this check) untouched.
        func recordCredit(on day: Date) {
            streak += 1
            maxStreak = max(maxStreak, streak)
            if streak == maxStreak {
                if maxStreakStartDate != currentStreakStart {
                    // A new streak instance just took over the record.
                    maxStreakStartDate = currentStreakStart
                    maxStreakPrecedingBreakDate = lastBreakDate
                    maxStreakFollowingBreakDate = nil
                }
                maxStreakEndDate = day
            }
        }

        func breakStreak(on day: Date) {
            if currentStreakStart == maxStreakStartDate {
                maxStreakFollowingBreakDate = day
            }
            streakOpen = false
            streak = 0
            bank = 0   // ledger closed — no meaningful balance until the next streak starts
            lastBreakDate = day
            currentStreakStart = nil
        }

        while day <= today, iterations < 20_000 {
            iterations += 1
            let isToday = day == today
            let isTraining = training.contains(day)
            let isActivityRest = activityRest.contains(day)
            let isPlainRest = plainRest.contains(day)
            let isCredited = isTraining || isActivityRest || isPlainRest

            if isToday && !isCredited { break }   // pending — stop without processing today

            if isCredited {
                if !streakOpen {
                    currentStreakStart = day
                    bank = 0
                    streakOpen = true
                }
                // Evaluate today's own spend against the bank AS IT STOOD
                // coming into today — a reset (if any) hasn't landed yet.
                // This is what decides whether today breaks the streak that
                // was already running.
                if isActivityRest { bank -= 0.5 }
                else if isPlainRest { bank -= 1.0 }
                // isTraining alone: no change, purely neutral.
                // Epsilon guards against floating-point residue spuriously
                // tripping a break right at the edge.
                let brokeToday = bank < -1e-9
                if brokeToday { breakStreak(on: day) }

                if let reset = resetByDay[day] {
                    // A reset always lands, whether or not today just broke
                    // the old streak — if it did, this reopens a brand-new
                    // one on this SAME day rather than waiting for the next
                    // one. Overwrites the bank outright; today's own spend
                    // above isn't re-deducted from the reset value.
                    if !streakOpen {
                        currentStreakStart = day
                        streakOpen = true
                    }
                    bank = reset
                    if isTraining || isActivityRest {
                        recordCredit(on: day)
                    }
                } else if !brokeToday, isTraining || isActivityRest {
                    recordCredit(on: day)
                }
                // else: either a plain rest that stayed non-negative with no
                // reset today (spends, but "does nothing" for the count), or
                // today broke the streak and there's no reset to reopen it.
            } else if streakOpen {
                bank -= 1.0
                let brokeToday = bank < -1e-9
                if brokeToday { breakStreak(on: day) }
                if let reset = resetByDay[day] {
                    if !streakOpen {
                        currentStreakStart = day
                        streakOpen = true
                    }
                    bank = reset
                    // An uncredited day never adds to the streak count,
                    // reset or not.
                }
            }
            // else: ledger already closed, an unlogged day has no effect
            // (any reset landing here is simply lost — it can't spend
            // itself into opening a fresh streak on its own).

            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }

        let maxStreakRange: MaxStreakDateRange? = maxStreakStartDate.map { start in
            MaxStreakDateRange(start: start, end: maxStreakEndDate ?? start,
                              precedingBreakDate: maxStreakPrecedingBreakDate,
                              followingBreakDate: maxStreakFollowingBreakDate)
        }
        return RestBankResult(currentStreak: streak, maxStreak: maxStreak, bankBalance: max(0, bank),
                              maxStreakRange: maxStreakRange,
                              currentStreakStartDate: streakOpen ? currentStreakStart : nil)
    }

    /// Required pace (slots per calendar day) implied by the phase's own
    /// split — one day-template slot (training or Rest, both now tracked by
    /// filledSlotCount) per calendar day, so expected slots by today is just
    /// daysElapsed itself.
    static func cyclePaceDelta(for phase: Phase, now: Date = .now) -> Int {
        let cal = Calendar.current
        let daysElapsed = max(1, (cal.dateComponents([.day],
            from: cal.startOfDay(for: phase.startDate), to: cal.startOfDay(for: now)).day ?? 0) + 1)
        return phase.filledSlotCount - daysElapsed
    }

    /// Sessions logged ÷ sessions scheduled to date (same "scheduled to
    /// date" quantity used by cyclePaceDelta), as a percentage.
    static func adherencePercent(for phase: Phase, now: Date = .now) -> Double {
        let cal = Calendar.current
        let daysElapsed = max(1, (cal.dateComponents([.day],
            from: cal.startOfDay(for: phase.startDate), to: cal.startOfDay(for: now)).day ?? 0) + 1)
        return Double(phase.filledSlotCount) / Double(daysElapsed) * 100
    }

    /// Every performed set on `name` within `sessions` that qualifies for a
    /// Big Lift stat, each dated to its own session. Excludes: a
    /// rest-day-activity log (its one "set" stores distance, not weight); a
    /// never-filled-in set (reps == 0, e.g. History's "Add Set" placeholder,
    /// or a draft set never actually logged); and, for a bodyweight exercise
    /// specifically, a set with no `bodyweightAtLog` on record (logged
    /// before that field existed, or imported with no weigh-in to resolve
    /// against) — SetLog's own doc confirms `weight` is already the resolved
    /// bodyweight-inclusive total for a bodyweight set, but when no
    /// bodyweight was on record at log time that resolution silently fell
    /// back to treating it as 0, so `weight` on such a set understates the
    /// real number. Skipped rather than trusted, since there's no way to
    /// tell the difference after the fact between "really was ~0 bodyweight"
    /// and "bodyweight just wasn't known yet". The final `weight > 0` filter
    /// is a backstop against any set that still nets out non-positive some
    /// other way. A log with no session (shouldn't normally happen) is
    /// skipped too — every qualifying set needs a real date.
    private static func bigLiftQualifyingSets(named name: String,
                                              in sessions: [WorkoutSession]) -> [(weight: Double, reps: Int, date: Date)] {
        sessions
            .flatMap(\.exerciseLogs)
            .filter { $0.exerciseName == name && $0.restDayActivity == nil }
            .flatMap { log -> [(weight: Double, reps: Int, date: Date)] in
                guard let date = log.session?.date else { return [] }
                return log.sets
                    .filter { $0.reps > 0 }
                    .filter { !log.isBodyweight || $0.bodyweightAtLog != nil }
                    .map { (weight: $0.weight, reps: $0.reps, date: date) }
            }
            .filter { $0.weight > 0 }
    }

    /// One flagged exercise's Big Lift summary within `sessions` — nil if it
    /// has no qualifying set (see bigLiftQualifyingSets) among them at all,
    /// rather than a result with a 0 in it. Heaviest and Est. 1RM are each
    /// resolved independently (often different sets, different dates) — a
    /// tie on either uses the LATER date, the most recent time the number
    /// was hit.
    static func bigLiftResult(named name: String, in sessions: [WorkoutSession]) -> BigLiftResult? {
        let sets = bigLiftQualifyingSets(named: name, in: sessions)
        guard let heaviest = sets.max(by: { a, b in
            if a.weight != b.weight { return a.weight < b.weight }
            return a.date < b.date
        }) else { return nil }
        guard let bestEstimate = sets.max(by: { a, b in
            let estimateA = PaceEngine.epley1RM(weight: a.weight, reps: a.reps)
            let estimateB = PaceEngine.epley1RM(weight: b.weight, reps: b.reps)
            if estimateA != estimateB { return estimateA < estimateB }
            return a.date < b.date
        }) else { return nil }
        return BigLiftResult(name: name, heaviestWeight: heaviest.weight, heaviestDate: heaviest.date,
                             estimatedOneRepMax: PaceEngine.epley1RM(weight: bestEstimate.weight, reps: bestEstimate.reps),
                             estimatedOneRepMaxDate: bestEstimate.date)
    }

    /// Every non-deload session logged against day template `name` (matched
    /// by dayLabel — see dayDurationGroups' own note on why) within
    /// `sessions` that has a recorded duration — a session with
    /// durationSeconds == nil (predates duration tracking, or the stopwatch
    /// was never started that day) is skipped rather than treated as 0, and
    /// a deload session is skipped the same way (its cut weights already
    /// get excluded from comparable history elsewhere; its duration
    /// shouldn't enter this spread either).
    /// `deloadOnly` selects which half of the split to measure: false (the
    /// default, and every pre-existing caller) takes normal sessions,
    /// true takes deload ones. `isDeload == deloadOnly` rather than two
    /// separate predicates, so the two are exhaustive and mutually
    /// exclusive by construction — no session can land on both Workout
    /// Duration pages or fall through the gap between them.
    private static func dayDurationQualifyingSessions(named name: String,
                                                       in sessions: [WorkoutSession],
                                                       deloadOnly: Bool) -> [Int] {
        sessions.filter { $0.dayLabel == name && $0.isDeload == deloadOnly }.compactMap(\.durationSeconds)
    }

    /// One day template's duration spread within `sessions` — nil if none
    /// of them has a recorded duration for this day at all, rather than a
    /// result with a 0 in it.
    static func dayDurationResult(named name: String, in sessions: [WorkoutSession],
                                  deloadOnly: Bool = false) -> DayDurationResult? {
        let durations = dayDurationQualifyingSessions(named: name, in: sessions, deloadOnly: deloadOnly)
        guard !durations.isEmpty, let shortest = durations.min(), let longest = durations.max() else { return nil }
        let average = Double(durations.reduce(0, +)) / Double(durations.count)
        return DayDurationResult(shortestSeconds: shortest, averageSeconds: average, longestSeconds: longest)
    }

    /// Classifies a single calendar day for the Claude Stats consistency
    /// heatmap — reuses the same session shapes every other stat already
    /// reads (WorkoutSession.isDeload, ExerciseLog.restDayActivity) rather
    /// than inventing a new way to tell what a day was. A day can have more
    /// than one session (e.g. a bonus session); it counts as `.trained` (or
    /// `.deload`) the moment ANY of that day's sessions has a real,
    /// non-rest-activity exercise log — a plain "I rested today" credit and
    /// a backfilled gap-fill placeholder both have `exerciseLogs` that are
    /// either empty or restDayActivity-only, so both land in `.rest`
    /// identically; there's no meaningful difference between them for a
    /// glance-at-a-heatmap purpose the way there is elsewhere in Stats.
    static func consistencyDayKind(on date: Date, sessions: [WorkoutSession],
                                   cal: Calendar = .current) -> ConsistencyDayKind {
        let daySessions = sessions.filter { cal.isDate($0.date, inSameDayAs: date) }
        guard !daySessions.isEmpty else { return .empty }
        let trainedSessions = daySessions.filter(\.hasLiftingLog)
        guard !trainedSessions.isEmpty else { return .rest }
        return trainedSessions.contains(where: \.isDeload) ? .deload : .trained
    }
}

/// One day's classification on the Claude Stats consistency heatmap — see
/// StatsEngine.consistencyDayKind for exactly how a day earns each case.
enum ConsistencyDayKind {
    case trained
    case deload
    case rest
    case empty
}

/// The Claude Stats page's one new derived number: a single 0-100 "how am I
/// doing right now" composite, distinct from anything StatsEngine itself
/// computes. StatsEngine's own numbers are each exhaustive-and-exact by
/// design (a lifetime percentage, an unbounded day-delta, a streak count) —
/// this engine's only job is blending three of them into one glanceable
/// score, which is a presentation concern, not a new fact about the data.
enum MomentumEngine {
    /// Maps an unbounded day-delta (StatsAndPlates.cyclePaceDelta: actual
    /// sessions vs. scheduled-to-date, can run arbitrarily far either way)
    /// onto a 0-1 signal — 0 at `ceilingDays` or more behind, 1 at
    /// `ceilingDays` or more ahead, exactly 0.5 dead on pace, linear between.
    /// `ceilingDays` defaults to 5: far enough that a single missed/bonus
    /// session (±1 day) doesn't swing the signal wildly, close enough that a
    /// full week's slip still reads as close to the floor rather than
    /// barely denting it.
    static func normalizedPace(_ delta: Int, ceilingDays: Int = 5) -> Double {
        guard ceilingDays > 0 else { return 0.5 }
        let clamped = max(-ceilingDays, min(ceilingDays, delta))
        return (Double(clamped) / Double(ceilingDays) + 1) / 2
    }

    /// Maps a streak length onto a 0-1 signal — `streak / ceiling`, clamped
    /// to 1. `ceiling` defaults to 14 (two weeks): long enough that a normal
    /// week-to-week streak doesn't instantly max the signal out, short
    /// enough that a genuinely long streak still saturates it rather than
    /// asymptotically creeping toward 1 forever.
    static func normalizedStreak(_ streak: Int, ceiling: Int = 14) -> Double {
        guard ceiling > 0 else { return 0 }
        return min(1, Double(streak) / Double(ceiling))
    }

    /// The composite score itself.
    ///
    /// WEIGHTING (a genuine design call, not a fact derivable from the data):
    /// with an active phase, adherence 50% / pace 30% / streak 20%.
    /// Adherence carries the most weight because it's already a clean,
    /// lifetime-scoped 0-100 signal — direct, and hard to swing with just a
    /// day or two. Pace comes next: it reacts fastest to how THIS block is
    /// going right now (a couple of missed or bonus days move it visibly),
    /// which is exactly the "right now" flavor this page wants, but that
    /// same reactivity makes it noisier than adherence, hence the smaller
    /// share. Streak gets the least weight on purpose — a single day off
    /// zeroes it outright, and a score that let a streak break crater the
    /// whole number would misrepresent someone who's otherwise training
    /// consistently. It's still included, just as a smaller accent, because
    /// "on a roll" is real and worth reflecting.
    ///
    /// With NO active phase, adherencePercent/cyclePaceDelta are both nil
    /// (StatsEngine only computes them against a phase's own schedule) —
    /// pace has no meaning to fall back to, so its 30% share folds into
    /// adherence, using `percentLogged` (the same daysLogged/daysSinceStart
    /// ratio TrainingStats always computes, phase or no phase) as the
    /// lifetime-adherence substitute. Streak keeps its 20%.
    static func score(adherencePercent: Double?, cyclePaceDelta: Int?,
                      currentStreak: Int, percentLogged: Double) -> Int {
        let streak01 = normalizedStreak(currentStreak)
        let composite: Double
        if let adherencePercent, let cyclePaceDelta {
            let adherence01 = min(1, max(0, adherencePercent / 100))
            let pace01 = normalizedPace(cyclePaceDelta)
            composite = adherence01 * 0.5 + pace01 * 0.3 + streak01 * 0.2
        } else {
            let adherence01 = min(1, max(0, percentLogged))
            composite = adherence01 * 0.8 + streak01 * 0.2
        }
        return Int((composite * 100).rounded())
    }
}

// MARK: - Plate Calculator

struct PlateResult: Identifiable {
    let id = UUID()
    let plate: Double
    let countPerSide: Int
}

enum PlateCalculator {
    /// Standard plate inventory (per side). Edit if your gym differs.
    static let defaultPlates: [Double] = [45, 35, 25, 10, 5, 2.5, 1.25]

    /// Returns plates PER SIDE for a target total, or nil if unreachable exactly.
    /// `sides` is how many sides of the bar you can actually load (2 for a
    /// standard barbell, 1 for e.g. a landmine attachment) — with 1 side, all
    /// the plate weight goes on that single side instead of splitting in half.
    /// Example: bar 45, target 100, 2 sides -> per side 27.5 -> [25 x1, 2.5 x1]
    /// Example: EZ bar 15, target 42.5, 2 sides -> per side 13.75 -> [10, 2.5, 1.25]
    static func plates(target: Double, barWeight: Double,
                       available: [Double] = defaultPlates,
                       sides: Int = 2) -> (result: [PlateResult], leftover: Double)? {
        let loadableSides = max(1, sides)
        let perSide = (target - barWeight) / Double(loadableSides)
        guard perSide >= 0 else { return nil }

        var remaining = perSide
        var out: [PlateResult] = []
        for p in available.sorted(by: >) {
            let count = Int((remaining / p) + 1e-9)
            if count > 0 {
                out.append(PlateResult(plate: p, countPerSide: count))
                remaining -= Double(count) * p
            }
        }
        // Round tiny fp residue
        if abs(remaining) < 1e-6 { remaining = 0 }
        return (out, remaining)
    }

    struct DumbbellMatch {
        let baseWeight: Double
        /// One entry per clip-on attachment used, largest first.
        let attachments: [Double]
    }

    /// Finds an owned dumbbell weight that, topped up with owned clip-on
    /// attachments (1.25 / 2.5 lb), hits `target` exactly — e.g. a 35 lb
    /// dumbbell + one 1.25 lb attachment for 36.25, or + two for 37.5.
    /// Prefers whichever owned base weight needs the fewest attachments;
    /// nil if no owned weight/attachment combination reaches it exactly.
    static func dumbbellMatch(target: Double, ownedWeights: [Double],
                              attachmentSizes: [Double]) -> DumbbellMatch? {
        var best: (base: Double, combo: [Double])?
        for base in ownedWeights {
            let gap = target - base
            guard gap >= -1e-6 else { continue }
            if abs(gap) < 1e-6 {
                if best == nil || best!.combo.count > 0 || base > best!.base {
                    best = (base, [])
                }
                continue
            }
            guard !attachmentSizes.isEmpty else { continue }
            var remaining = gap
            var combo: [Double] = []
            for size in attachmentSizes.sorted(by: >) {
                let count = Int((remaining / size) + 1e-9)
                for _ in 0..<count { combo.append(size) }
                remaining -= Double(count) * size
            }
            guard abs(remaining) < 1e-6 else { continue }
            if best == nil || combo.count < best!.combo.count {
                best = (base, combo)
            }
        }
        guard let best else { return nil }
        return DumbbellMatch(baseWeight: best.base, attachments: best.combo)
    }
}
