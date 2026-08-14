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
    var bankBalance: Double     // current rest-bank balance, >= 0, uncapped above
    var percentLogged: Double   // daysLogged / daysSinceStart
    var daysPerWeek: Double

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
                        trainingDaysPerWeekChanges: [(date: Date, value: Int)] = [],
                        defaultTrainingDaysPerWeek: Int = 3,
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
        let creditEvents = allPhases.flatMap(\.restBankCreditEvents)
        let bank = computeRestBank(trainingDates: trainingDates,
                                   activityRestDates: restActivityDates,
                                   plainRestDates: activeRecoveryDates,
                                   creditEvents: creditEvents, now: now)
        let cyclePace = activePhase.map { cyclePaceDelta(for: $0, now: effectiveNow) }
        let adherence = activePhase.map { adherencePercent(for: $0, now: effectiveNow) }

        let daysLogged = loggedDays.count
        let pct = Double(daysLogged) / Double(daysSinceStart)
        let weeks = Double(daysSinceStart) / 7.0
        let perWeek = weeks > 0 ? Double(daysLogged) / weeks : 0

        // YTD/MTD: "worked out" means an actual training session, not a rest
        // day activity — separate from loggedDays above (which is streak math).
        let workoutDays = Set(sessionDates.map { cal.startOfDay(for: $0) })

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
            perfectWeekFallback = computePerfectWeekFallback(workoutDays: workoutDays, start: start, today: today,
                                                             trainingDaysPerWeekChanges: trainingDaysPerWeekChanges,
                                                             defaultTrainingDaysPerWeek: defaultTrainingDaysPerWeek)
        }
        // Same "today is pending" rule as effectiveToday above — if today
        // hasn't been logged yet, the prior-year comparison shouldn't
        // include the prior-year equivalent of a day that hasn't happened
        // yet this year either.
        let priorYearToday = cal.date(byAdding: .year, value: -1, to: effectiveToday) ?? effectiveToday

        func dayCount(from windowStart: Date, through windowEnd: Date) -> Int {
            workoutDays.filter { $0 >= windowStart && $0 <= windowEnd }.count
        }
        let yearStart = cal.date(from: cal.dateComponents([.year], from: today)) ?? today
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: today)) ?? today
        let priorYearStart = cal.date(from: cal.dateComponents([.year], from: priorYearToday)) ?? priorYearToday
        let priorYearMonthStart = cal.date(from: cal.dateComponents([.year, .month], from: priorYearToday)) ?? priorYearToday

        let ytdWorkoutDays = dayCount(from: yearStart, through: today)
        let mtdWorkoutDays = dayCount(from: monthStart, through: today)
        let priorYearYtdWorkoutDays = dayCount(from: priorYearStart, through: priorYearToday)
        let priorYearMtdWorkoutDays = dayCount(from: priorYearMonthStart, through: priorYearToday)

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
            let wasLogged = workoutDays.contains(walk)
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
        for dayLogged in workoutDays {
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
                             bankBalance: bank.bankBalance,
                             percentLogged: pct,
                             daysPerWeek: perWeek,
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
                             perfectWeekFallback: perfectWeekFallback)
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

    // MARK: - Rest bank (deposit-based: credited at phase start/cycle finish, spent by rest days)

    struct RestBankResult {
        var currentStreak: Int
        var maxStreak: Int
        var bankBalance: Double
        var maxStreakRange: MaxStreakDateRange?
        /// When the currently-open streak began — nil once currentStreak is 0.
        var currentStreakStartDate: Date?
    }

    /// Pure day-by-day walk of the rest-bank model. Training itself is
    /// bank-neutral — it just keeps the streak alive. The bank only ever
    /// moves via `creditEvents` (+2 the day a phase starts, +2 the day each
    /// of its cycles finishes except the last — see `Phase.restBankCreditEvents`)
    /// and rest days, which spend from it: an activity-logged rest costs
    /// 0.5, a plain/unscheduled rest (or a day with nothing logged at all,
    /// while a streak is open) costs 1.0. A credit landing on an otherwise
    /// uncredited day only applies if the streak is already open going into
    /// it — a bare credit event can't spontaneously open one on its own.
    ///
    /// The bank never goes negative: the moment a spend would take it below
    /// 0, the streak ends right there and the ledger closes — bank sits at a
    /// clean 0, and no further uncredited or rest days do anything (no more
    /// spending) until the next credited day starts a brand-new streak,
    /// fresh at 0 rather than inheriting whatever debt was left. Today is
    /// left pending — neither spent nor credited — if nothing's logged yet.
    static func computeRestBank(trainingDates: [Date],
                                activityRestDates: [Date],
                                plainRestDates: [Date],
                                creditEvents: [(date: Date, amount: Double)],
                                now: Date = .now) -> RestBankResult {
        let cal = Calendar.current
        let training = Set(trainingDates.map { cal.startOfDay(for: $0) })
        let activityRest = Set(activityRestDates.map { cal.startOfDay(for: $0) })
        let plainRest = Set(plainRestDates.map { cal.startOfDay(for: $0) })
        var creditByDay: [Date: Double] = [:]
        for event in creditEvents {
            creditByDay[cal.startOfDay(for: event.date), default: 0] += event.amount
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
                if isActivityRest { bank -= 0.5 }
                else if isPlainRest { bank -= 1.0 }
                // isTraining alone: no change, purely neutral.
                bank += creditByDay[day] ?? 0
                // Epsilon guards against floating-point residue spuriously
                // tripping a break right at the edge.
                if bank < -1e-9 {
                    breakStreak(on: day)
                } else {
                    recordCredit(on: day)
                }
            } else if streakOpen {
                bank -= 1.0
                bank += creditByDay[day] ?? 0
                if bank < -1e-9 {
                    breakStreak(on: day)
                }
            }
            // else: ledger already closed, an unlogged day has no effect
            // (any credit landing here is simply lost — it can't spend
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
