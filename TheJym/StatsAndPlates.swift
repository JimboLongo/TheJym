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
    var currentStreak: Int      // consecutive logged days ending today/yesterday
    var maxStreak: Int
    var percentLogged: Double   // daysLogged / daysSinceStart
    var daysPerWeek: Double
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
                        phaseSchedules: [PhaseSchedule] = [],
                        now: Date = .now) -> TrainingStats {
        let cal = Calendar.current
        let start = cal.startOfDay(for: startDate)
        let today = cal.startOfDay(for: now)

        let loggedDays = Set((sessionDates + restActivityDates).map { cal.startOfDay(for: $0) })
            .filter { $0 >= start && $0 <= today }

        let daysSinceStart = max(1, (cal.dateComponents([.day], from: start, to: today).day ?? 0) + 1)

        // A day with nothing logged doesn't break a streak if it's a scheduled
        // Rest day, or if it's today (not over yet) — it's simply skipped, as
        // if it weren't part of the timeline. Any other empty day is a
        // genuinely missed training day and breaks the streak.
        func omittedIfEmpty(_ day: Date) -> Bool {
            day == today || (isScheduledRestDay(day, schedules: phaseSchedules, cal: cal) ?? false)
        }

        // Max streak: walk forward from start to today.
        var maxStreak = 0, run = 0, iterations = 0
        var day = start
        while day <= today, iterations < 20_000 {
            iterations += 1
            if loggedDays.contains(day) {
                run += 1
                maxStreak = max(maxStreak, run)
            } else if !omittedIfEmpty(day) {
                run = 0
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }

        // Current streak: walk backward from today, stopping at the first
        // genuinely missed training day.
        var current = 0
        var cursor = today
        iterations = 0
        while cursor >= start, iterations < 20_000 {
            iterations += 1
            if loggedDays.contains(cursor) {
                current += 1
            } else if !omittedIfEmpty(cursor) {
                break
            }
            guard let prev = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }

        let daysLogged = loggedDays.count
        let pct = Double(daysLogged) / Double(daysSinceStart)
        let weeks = Double(daysSinceStart) / 7.0
        let perWeek = weeks > 0 ? Double(daysLogged) / weeks : 0

        return TrainingStats(daysSinceStart: daysSinceStart,
                             daysLogged: daysLogged,
                             currentStreak: current,
                             maxStreak: maxStreak,
                             percentLogged: pct,
                             daysPerWeek: perWeek)
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
    /// Example: bar 45, target 100 -> per side 27.5 -> [25 x1, 2.5 x1]
    /// Example: EZ bar 15, target 42.5 -> per side 13.75 -> [10, 2.5, 1.25]
    static func plates(target: Double, barWeight: Double,
                       available: [Double] = defaultPlates) -> (result: [PlateResult], leftover: Double)? {
        let perSide = (target - barWeight) / 2
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
