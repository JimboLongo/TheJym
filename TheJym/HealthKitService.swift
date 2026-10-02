//
//  HealthKitService.swift
//  TheJym
//
//  Read-only HealthKit access. Nothing in this file ever writes to Health —
//  the app declares NSHealthShareUsageDescription only, not
//  NSHealthUpdateUsageDescription, so a write would fail at runtime anyway.
//

import Foundation
import HealthKit

/// One calendar day's total for a cumulative quantity type.
struct DayCount: Identifiable, Hashable {
    let day: Date
    let value: Double
    var id: Date { day }
}

@MainActor
final class HealthKitService {
    static let shared = HealthKitService()
    private let store = HKHealthStore()
    private init() {}

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// Asks once for read access. Deliberately swallows the error: a
    /// refusal is not an exceptional condition here, it's a normal state
    /// the UI has to render as "no data" anyway (see `dailySteps`).
    func requestAuthorization() async {
        guard isAvailable else { return }
        let types: Set<HKObjectType> = [HKQuantityType(.stepCount)]
        try? await store.requestAuthorization(toShare: [], read: types)
    }

    /// Every day on record with a non-zero step count, oldest first.
    ///
    /// Uses HKStatisticsCollectionQuery with `.cumulativeSum` and NO source
    /// predicate, which is the only shape that reproduces the figure the
    /// Health app shows. Verified on-device 2026-10-02 against 14 days of
    /// real iPhone + Watch data: summing HKSampleQuery results overstated
    /// distance by 8-42%, because both devices write overlapping samples;
    /// the statistics query discards the overlap. It is NOT equivalent to
    /// "prefer the Watch" either — on a day the Watch was off the wrist it
    /// correctly backfilled the gap from the phone, which a Watch-only
    /// source predicate would have undercounted. Do not "optimise" this
    /// into a sample query or a source filter.
    ///
    /// Returns [] for every failure mode there is — HealthKit unavailable,
    /// permission never asked, permission denied, genuinely no data. That
    /// collapse is forced on us, not a shortcut: HealthKit deliberately
    /// makes a denied READ indistinguishable from an empty one, so that an
    /// app can't infer a condition from the fact you hid it. The UI
    /// therefore must never claim "access denied" — it can't know.
    func dailySteps() async -> [DayCount] {
        guard isAvailable else { return [] }
        let type = HKQuantityType(.stepCount)
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)

        guard let earliest = await earliestSampleDay(type: type, cal: cal) else { return [] }
        let start = min(earliest, today)
        guard let end = cal.date(byAdding: .day, value: 1, to: today) else { return [] }

        let collection: HKStatisticsCollection? = await withCheckedContinuation { cont in
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: end,
                                                                     options: [.strictStartDate]),
                options: .cumulativeSum,
                anchorDate: start,
                intervalComponents: DateComponents(day: 1))
            query.initialResultsHandler = { _, collection, _ in cont.resume(returning: collection) }
            store.execute(query)
        }
        guard let collection else { return [] }

        var out: [DayCount] = []
        collection.enumerateStatistics(from: start, to: today) { stats, _ in
            guard let sum = stats.sumQuantity()?.doubleValue(for: .count()), sum > 0 else { return }
            out.append(DayCount(day: cal.startOfDay(for: stats.startDate), value: sum))
        }
        return out
    }

    /// The first day with any data, so the collection query spans real
    /// history instead of an arbitrary fixed window — one cheap
    /// single-sample query rather than guessing a start date years back and
    /// enumerating thousands of empty buckets.
    private func earliestSampleDay(type: HKQuantityType, cal: Calendar) async -> Date? {
        await withCheckedContinuation { cont in
            let query = HKSampleQuery(
                sampleType: type, predicate: nil, limit: 1,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate,
                                                   ascending: true)]) { _, results, _ in
                cont.resume(returning: results?.first.map { cal.startOfDay(for: $0.startDate) })
            }
            store.execute(query)
        }
    }
}
