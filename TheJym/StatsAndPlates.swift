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
    static func compute(startDate: Date, sessionDates: [Date], now: Date = .now) -> TrainingStats {
        let cal = Calendar.current
        let start = cal.startOfDay(for: startDate)
        let today = cal.startOfDay(for: now)

        let loggedDays = Set(sessionDates.map { cal.startOfDay(for: $0) })
            .filter { $0 >= start && $0 <= today }
            .sorted()

        let daysSinceStart = max(1, (cal.dateComponents([.day], from: start, to: today).day ?? 0) + 1)

        // Max streak (consecutive calendar days)
        var maxStreak = 0, run = 0
        var prev: Date? = nil
        for d in loggedDays {
            if let p = prev, cal.dateComponents([.day], from: p, to: d).day == 1 {
                run += 1
            } else {
                run = 1
            }
            maxStreak = max(maxStreak, run)
            prev = d
        }

        // Current streak: count back from today (a streak survives if the last
        // logged day is today or yesterday)
        var current = 0
        var cursor = today
        let loggedSet = Set(loggedDays)
        if !loggedSet.contains(today) {
            cursor = cal.date(byAdding: .day, value: -1, to: today) ?? today
        }
        while loggedSet.contains(cursor) {
            current += 1
            cursor = cal.date(byAdding: .day, value: -1, to: cursor) ?? cursor
            if current > 10_000 { break }
        }

        let pct = Double(loggedDays.count) / Double(daysSinceStart)
        let weeks = Double(daysSinceStart) / 7.0
        let perWeek = weeks > 0 ? Double(loggedDays.count) / weeks : 0

        return TrainingStats(daysSinceStart: daysSinceStart,
                             daysLogged: loggedDays.count,
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
