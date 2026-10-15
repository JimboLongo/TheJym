//
//  MacroVariance.swift
//  TheJym
//
//  How a cycle's logged macros compare to the tier it was tagged with.
//
//  Two rules run through everything here, and both exist because a number
//  on its own can mislead:
//
//  1. EVERY AVERAGE CARRIES ITS DENOMINATOR. Categories average over the
//     days that logged them, so protein over 6 days and fiber over 4 sit
//     side by side on different bases. MacroAverage makes it impossible to
//     hold a mean without its day count.
//  2. DIRECTION DECIDES WHETHER A DEVIATION IS GOOD. "+15g" on protein is
//     the target beaten; "+15g" on sugar is the ceiling breached. Rendering
//     them alike would make the readout worse than no readout.
//

import Foundation

/// Calories averaged over a cycle.
///
/// A SEPARATE, STRICTER BASIS than the per-category averages, and this is
/// the whole reason the type exists. Computing calories from the category
/// means would assemble one figure out of three different day sets —
/// protein's 6 days, carbs' 5, fat's 4 — producing a number that is no
/// day's calories. It hides better than the per-category version because
/// calories look like a single measurement.
///
/// So: averaged only over days where protein, carbs AND fat are ALL
/// present. Sugar and fiber don't enter the sum (they're subsets of carbs
/// — see MacroTier.calories) so they don't gate it either. When this count
/// differs from the category counts, that's informative: it means some
/// days are only partly logged.
struct CalorieAverage {
    let mean: Double?
    let dayCount: Int

    static func compute(over logs: [MacroLog]) -> CalorieAverage {
        let complete = logs.filter {
            $0.proteinGrams != nil && $0.carbsGrams != nil && $0.fatGrams != nil
        }
        guard !complete.isEmpty else { return CalorieAverage(mean: nil, dayCount: 0) }
        let total = complete.reduce(0.0) { $0 + ($1.calories ?? 0) }
        return CalorieAverage(mean: total / Double(complete.count), dayCount: complete.count)
    }
}

/// Whether an average landed where its target pointed.
enum MacroVarianceStatus {
    case met, under, over

    /// Only `met` reads as good. A one-sided target that's been beaten is
    /// already `met` (200g against "protein >= 185" is met, not over), so
    /// anything else here is a genuine miss.
    var isFavourable: Bool { self == .met }
}

struct MacroVariance: Identifiable {
    let category: MacroCategory
    let average: MacroAverage
    let target: Double

    var id: String { category.rawValue }

    /// Signed difference from target — positive is above it, whichever way
    /// the target points. The sign says which way you moved; `status` says
    /// whether that was the right way.
    var delta: Double? { average.mean.map { $0 - target } }

    /// Tolerance applied to `≈` categories ONLY, as a PERCENTAGE of target
    /// rather than flat grams: 5g off 75g of fat is a different matter from
    /// 5g off 260g of carbs, and a proportional band says so where a gram
    /// tolerance wouldn't. One-sided targets need no band — "at least 185"
    /// is exact, and softening it would just move the line somewhere
    /// undocumented.
    static let aboutTolerance = 0.05

    var status: MacroVarianceStatus? {
        guard let mean = average.mean else { return nil }
        switch category.direction {
        case .atLeast:
            return mean >= target ? .met : .under
        case .atMost:
            return mean <= target ? .met : .over
        case .about:
            let band = abs(target) * Self.aboutTolerance
            if abs(mean - target) <= band { return .met }
            return mean < target ? .under : .over
        }
    }
}

/// One cycle's macro picture: what it was tagged with, what was logged,
/// and how the two compare.
struct MacroCycleSummary {
    let phaseNumber: Int
    let cycleNumber: Int
    let tier: MacroTier
    let range: ClosedRange<Date>
    let variances: [MacroVariance]
    let calories: CalorieAverage
    /// The tier's own implied calories — the figure `calories.mean` is
    /// measured against.
    let calorieTarget: Double

    var calorieDelta: Double? { calories.mean.map { $0 - calorieTarget } }

    /// Days in the window that logged anything at all. Distinct from any
    /// per-category count, and from the calorie count.
    let loggedDayCount: Int

    /// Nothing was logged in this cycle's window — the section should say
    /// so rather than render five empty rows.
    var isEmpty: Bool { loggedDayCount == 0 }

    /// nil when the cycle has no attributed sessions (so no date range) or
    /// no tier to measure against. Both are ordinary states, not errors.
    static func compute(phase: Phase, cycle: Int, logs: [MacroLog],
                        now: Date = .now) -> MacroCycleSummary? {
        guard let tier = CycleMacroTag.tag(for: phase, cycle: cycle)?.tier,
              let range = phase.dateRange(forCycle: cycle, now: now)
        else { return nil }
        let cal = Calendar.current
        let inRange = logs.filter { range.contains(cal.startOfDay(for: $0.date)) }
        return MacroCycleSummary(
            phaseNumber: phase.number,
            cycleNumber: cycle,
            tier: tier,
            range: range,
            variances: MacroCategory.allCases.map {
                MacroVariance(category: $0,
                              average: MacroAverage.compute($0, over: inRange),
                              target: tier.grams($0))
            },
            calories: CalorieAverage.compute(over: inRange),
            calorieTarget: tier.calories,
            loggedDayCount: inRange.filter { !$0.isEmpty }.count)
    }
}
