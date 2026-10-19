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

    /// Every day count the table shows: the five categories plus
    /// calories, in row order.
    var allDayCounts: [Int] { variances.map(\.average.dayCount) + [calories.dayCount] }

    /// The count to put in the section header, so six identical "(3d)"
    /// suffixes don't have to be read six times.
    ///
    /// The MODE, not the maximum: the header stands for "what most of
    /// this table is measured over", and a row that disagrees prints its
    /// own count beside it. Ties break toward the larger count, so the
    /// header never understates the basis.
    ///
    /// nil only when there is nothing to count at all.
    var headerDayCount: Int? {
        let counts = allDayCounts
        guard !counts.isEmpty else { return nil }
        var tally: [Int: Int] = [:]
        for c in counts { tally[c, default: 0] += 1 }
        return tally.max { a, b in
            a.value != b.value ? a.value < b.value : a.key < b.key
        }?.key
    }

    /// True when every row shares the header's count — the common case,
    /// and the one where both the per-row suffixes and half the footnote
    /// are saying nothing.
    var dayCountsAreUniform: Bool { Set(allDayCounts).count <= 1 }

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
            // IF YOU ARE HERE BECAUSE THE HEADER SAYS 2450 AND THIS ROW
            // SAYS 2455, THAT IS CORRECT. They are different numbers
            // measuring different things:
            //
            //   2450  the tier's NAME — a label you typed, which happens
            //         to look like a calorie figure because that is how
            //         diet tiers are usually named
            //   2455  this tier's macros, costed: 4*185 + 4*260 + 9*75
            //
            // A tier named "2450" whose grams come to 2455 is not
            // inconsistent; naming is free text and nothing rounds the
            // grams to make the label come true. Sourcing the target
            // from the name would measure the cycle against a string,
            // and would silently stop tracking the moment anyone edited
            // a gram value without renaming the tier.
            //
            // MacroCalorieIdentityTests asserts this, and fails if the
            // target is ever taken from the name.
            calorieTarget: tier.calories,
            loggedDayCount: inRange.filter { !$0.isEmpty }.count)
    }
}

// MARK: - Display

/// The ONE place a figure in the cycle macro table becomes text.
///
/// Every value in that table is rounded to whole units for display, and
/// computed unrounded. Two decimals were wide enough to wrap protein and
/// carbs but not fat and sugar, which made the row heights uneven and the
/// units look inconsistently spaced — one fix for all three symptoms.
///
/// Rounding the DISPLAY only, never the arithmetic: `MacroVariance.delta`
/// still subtracts the exact mean from the exact target, and `status` is
/// still decided on exact values, so a 0.4g miss is still coloured as a
/// miss even when it rounds to a delta of 0.
///
/// THE TIE RULE IS LOAD-BEARING. The three columns stay consistent —
/// displayed value minus target equals displayed delta — only if
/// rounding commutes with subtracting a whole number, and most tie rules
/// don't. Measured, mean 118.5 against a target of 185:
///
///     half away from zero (Swift's .rounded())   119 - 185 = -66,  round(-66.5) = -67
///     half to even                               118 - 185 = -67,  round(-66.5) = -66
///     half UP (floor(x + 0.5))                   119 - 185 = -66,  round(-66.5) = -66
///
/// Half-up is the only one of the three that is translation-invariant,
/// because floor(x + n + 0.5) == floor(x + 0.5) + n for whole n. The
/// other two break at exactly .5, which a mean over an even number of
/// days reaches routinely (187 and 188 average to 187.5). So `round`
/// below is half-up, deliberately, and not Double.rounded().
///
/// It exists as a type rather than three call sites because the unit and
/// its spacing drifted last time: the category rows carried "g" with no
/// space while the calorie row carried none at all, and nothing stopped
/// them diverging further.
enum MacroFigure {
    /// What a missing average reads as — this codebase's existing way of
    /// saying "no value", not zero.
    static let none = "\u{2014}"

    /// Half-UP, not Double.rounded(). See the note above — this is the
    /// only tie rule under which the table's three number columns can't
    /// contradict each other.
    static func round(_ v: Double) -> Int { Int((v + 0.5).rounded(.down)) }

    /// A measured average. `unit` is "g" for the five categories and ""
    /// for calories, whose row label already says what it is; the SPACING
    /// rule (none, unit butted against the digits) is the part that is
    /// shared and must not drift.
    static func value(_ v: Double?, unit: String) -> String {
        guard let v else { return none }
        return "\(round(v))\(unit)"
    }

    /// A target, with its direction symbol. Calories pass no symbol.
    static func target(_ v: Double, symbol: String = "") -> String {
        "\(symbol)\(round(v))"
    }

    /// A signed difference, or nil when there is no average to compare.
    ///
    /// A rounded-to-zero delta prints as a bare "0", never "+0" or "-0":
    /// the sign would claim a direction the displayed numbers don't show.
    /// Its colour still carries the truth — a 184.6g average against a
    /// 185g floor shows "0" in orange, because `status` was decided
    /// before any rounding.
    static func delta(_ v: Double?) -> String? {
        guard let v else { return nil }
        let rounded = round(v)
        if rounded == 0 { return "0" }
        return rounded > 0 ? "+\(rounded)" : "\(rounded)"
    }
}
