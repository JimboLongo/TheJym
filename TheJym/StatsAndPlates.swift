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
    var bankBalance: Double     // current rest-bank balance, 0...2
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

        let ratePeriods = buildRatePeriods(phases: allPhases,
                                          trainingDaysPerWeekChanges: trainingDaysPerWeekChanges,
                                          defaultTrainingDaysPerWeek: defaultTrainingDaysPerWeek)
        let bank = computeRestBank(creditedDates: sessionDates + activeRecoveryDates,
                                   ratePeriods: ratePeriods, now: now)
        let cyclePace = activePhase.map { cyclePaceDelta(for: $0, now: effectiveNow) }
        let adherence = activePhase.map { adherencePercent(for: $0, now: effectiveNow) }

        let daysLogged = loggedDays.count
        let pct = Double(daysLogged) / Double(daysSinceStart)
        let weeks = Double(daysSinceStart) / 7.0
        let perWeek = weeks > 0 ? Double(daysLogged) / weeks : 0

        // YTD/MTD: "worked out" means an actual training session, not a rest
        // day activity — separate from loggedDays above (which is streak math).
        let workoutDays = Set(sessionDates.map { cal.startOfDay(for: $0) })
        let priorYearToday = cal.date(byAdding: .year, value: -1, to: today) ?? today

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

        // Perfect weeks/months + best month all-time: walk day-by-day again,
        // bucketing scheduled-vs-logged training days by week and by month.
        struct Bucket { var scheduled = 0; var logged = 0; var sessions = 0 }
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
            if wasLogged {
                monthBuckets[monthKey, default: Bucket()].sessions += 1
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

        var bestMonthLabel: String?
        var bestMonthWorkouts = 0
        if let best = monthBuckets.filter({ $0.key != currentMonthKey })
            .max(by: { $0.value.sessions < $1.value.sessions }),
           best.value.sessions > 0 {
            bestMonthWorkouts = best.value.sessions
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
                             adherencePercent: adherence)
    }

    // MARK: - Rest bank (replaces the old schedule-walking streak model)

    /// A minimum floor so a 7-day-a-week trainer (or an all-training-day
    /// split with no Rest day) isn't stuck earning ~0 and living on a
    /// knife's edge where any missed day breaks the streak outright.
    static let minEarnRate = 0.15
    /// The bank never holds more than this many "days" of buffer.
    static let bankCap = 2.0

    static func earnRate(restDays: Int, trainingDays: Int) -> Double {
        guard trainingDays > 0 else { return minEarnRate }
        return max(minEarnRate, Double(restDays) / Double(trainingDays))
    }

    /// A window of time over which a constant earn rate applies. Periods are
    /// meant to be sorted by `start` ascending; the rate in effect on a given
    /// day is whichever period's `start` is the latest one at or before it.
    struct RatePeriod {
        let start: Date
        let earnRate: Double
    }

    struct RestBankResult {
        var currentStreak: Int
        var maxStreak: Int
        var bankBalance: Double
    }

    /// Builds the earn-rate timeline: an active Phase's split-derived rate
    /// takes over from its start date forward (until a later Phase
    /// supersedes it); everywhere else, the "Training days per week"
    /// setting's rate applies, itself changing at whatever date it was
    /// actually changed — never recomputing history retroactively.
    static func buildRatePeriods(phases: [Phase],
                                 trainingDaysPerWeekChanges: [(date: Date, value: Int)],
                                 defaultTrainingDaysPerWeek: Int) -> [RatePeriod] {
        let cal = Calendar.current
        var events: [(date: Date, rate: Double)] = []

        let sortedChanges = trainingDaysPerWeekChanges.sorted { $0.date < $1.date }
        if sortedChanges.isEmpty {
            events.append((date: .distantPast,
                           rate: earnRate(restDays: 7 - defaultTrainingDaysPerWeek,
                                         trainingDays: defaultTrainingDaysPerWeek)))
        } else {
            for change in sortedChanges {
                events.append((date: change.date,
                               rate: earnRate(restDays: 7 - change.value, trainingDays: change.value)))
            }
        }

        for phase in phases.sorted(by: { $0.startDate < $1.startDate }) {
            events.append((date: phase.startDate, rate: phase.restBankEarnRate))
        }

        return events
            .sorted { $0.date < $1.date }
            .map { RatePeriod(start: cal.startOfDay(for: $0.date), earnRate: $0.rate) }
    }

    /// Pure day-by-day walk of the rest-bank model. A streak begins on a
    /// credited day with the bank reset to 1.0 (capped at `bankCap`); every
    /// other credited day within that same streak adds that day's earn
    /// rate. Uncredited days spend 1.0 — but only while the streak is still
    /// open. The moment the bank drops below 0, the streak ends right there
    /// and the ledger closes: further uncredited days do nothing (no more
    /// spending) until the next credited day starts a brand-new streak,
    /// fresh at 1.0 rather than inheriting whatever debt was left. Today is
    /// left pending — neither earned nor spent — if nothing's logged yet.
    static func computeRestBank(creditedDates: [Date],
                                ratePeriods: [RatePeriod],
                                now: Date = .now) -> RestBankResult {
        let cal = Calendar.current
        let credited = Set(creditedDates.map { cal.startOfDay(for: $0) })
        let today = cal.startOfDay(for: now)
        guard let firstDay = credited.min() else {
            return RestBankResult(currentStreak: 0, maxStreak: 0, bankBalance: 0)
        }
        let sortedPeriods = ratePeriods.sorted { $0.start < $1.start }

        func rate(on day: Date) -> Double {
            let covering = sortedPeriods.filter { $0.start <= day }.max { $0.start < $1.start }
            return covering?.earnRate ?? (sortedPeriods.first?.earnRate ?? minEarnRate)
        }

        var bank = 0.0
        var streakOpen = false
        var streak = 0
        var maxStreak = 0
        var day = firstDay
        var iterations = 0
        while day <= today, iterations < 20_000 {
            iterations += 1
            let isToday = day == today
            let isCredited = credited.contains(day)

            if isToday && !isCredited { break }   // pending — stop without processing today

            if isCredited {
                bank = streakOpen ? min(bankCap, bank + rate(on: day)) : 1.0
                streakOpen = true
                streak += 1
                maxStreak = max(maxStreak, streak)
            } else if streakOpen {
                bank -= 1.0
                // Epsilon guards against floating-point residue (e.g. a
                // repeating-decimal earn rate landing at -1e-16 instead of
                // exactly 0) spuriously tripping a break right at the edge.
                if bank < -1e-9 {
                    streakOpen = false
                    streak = 0
                    bank = 0   // ledger closed — no meaningful balance until the next streak starts
                }
            }
            // else: ledger already closed, an uncredited day has no effect.

            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return RestBankResult(currentStreak: streak, maxStreak: maxStreak, bankBalance: bank)
    }

    /// Required pace (workouts per calendar day) implied by the phase's own
    /// split — one day-template slot per calendar day, so totalCycles cancel
    /// out: pace = trainingDaysPerCycle / (days in one pass of the template).
    static func cyclePaceDelta(for phase: Phase, now: Date = .now) -> Int {
        let cal = Calendar.current
        let daysElapsed = max(1, (cal.dateComponents([.day],
            from: cal.startOfDay(for: phase.startDate), to: cal.startOfDay(for: now)).day ?? 0) + 1)
        let pace = Double(phase.trainingDaysPerCycle) / Double(max(phase.orderedDays.count, 1))
        let expected = Int(floor(Double(daysElapsed) * pace))
        return phase.filledSlotCount - expected
    }

    /// Sessions logged ÷ sessions scheduled to date (same "scheduled to
    /// date" quantity used by cyclePaceDelta), as a percentage.
    static func adherencePercent(for phase: Phase, now: Date = .now) -> Double {
        let cal = Calendar.current
        let daysElapsed = max(1, (cal.dateComponents([.day],
            from: cal.startOfDay(for: phase.startDate), to: cal.startOfDay(for: now)).day ?? 0) + 1)
        let pace = Double(phase.trainingDaysPerCycle) / Double(max(phase.orderedDays.count, 1))
        let expected = max(1, Int(floor(Double(daysElapsed) * pace)))
        return Double(phase.filledSlotCount) / Double(expected) * 100
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
}
