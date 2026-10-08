//
//  SessionDurationEditTests.swift
//  TheJymTests
//
//  Editing and clearing a session's duration, and the estimated flag that
//  distinguishes a remembered duration from a measured one.
//
//  The nil-vs-zero distinction is the load-bearing part: History omits the
//  duration line entirely when it's nil rather than showing "0:00", and
//  both duration stats skip a nil rather than averaging a 0 into the
//  spread. A clear that wrote 0 would silently halve an average.
//

import XCTest
import SwiftData
@testable import TheJym

@MainActor
final class SessionDurationEditTests: XCTestCase {
    private let cal = Calendar.current
    private func d(_ y: Int, _ m: Int, _ day: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: day))!
    }

    private func makeContext() -> ModelContext {
        let c = try! ModelContainer(
            for: AppSettings.self, Bar.self, ExerciseDef.self, Phase.self, PhaseDay.self,
            PlannedExercise.self, WorkoutSession.self, ExerciseLog.self, SetLog.self,
            BodyWeightEntry.self, RestDayActivity.self, ActiveRecovery.self,
            TrainingDaysPerWeekChange.self, TimerTemplate.self, TimerPreset.self,
            BackupStatus.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(c)
    }

    @discardableResult
    private func session(_ ctx: ModelContext, _ day: Int, label: String = "Upper Day 1",
                         seconds: Int? = nil, estimated: Bool = false,
                         deload: Bool = false) -> WorkoutSession {
        let s = WorkoutSession(date: d(2026, 10, day), dayLabel: label,
                               cycleNumber: 1, isDeload: deload)
        s.durationSeconds = seconds
        s.durationIsEstimated = estimated
        ctx.insert(s)
        let log = ExerciseLog(exerciseName: "Bench Press", targetReps: [5], order: 0)
        log.session = s
        ctx.insert(log)
        let set = SetLog(index: 0, weight: 185, reps: 5)
        set.exerciseLog = log
        ctx.insert(set)
        try? ctx.save()
        return s
    }

    // MARK: - nil vs zero

    func testClearingSetsNilNotZero() {
        let ctx = makeContext()
        let s = session(ctx, 1, seconds: 4328)
        s.durationSeconds = nil
        s.durationIsEstimated = false
        try? ctx.save()
        XCTAssertNil(s.durationSeconds)
        XCTAssertNotEqual(s.durationSeconds, 0, "nil and 0 are different statements")
    }

    /// A cleared duration must leave the spread as if the session never
    /// had one — not drag it toward zero.
    func testClearedDurationLeavesTheSpreadUntouched() {
        let ctx = makeContext()
        session(ctx, 1, seconds: 3600)
        session(ctx, 3, seconds: 5400)
        let third = session(ctx, 5, seconds: 60)
        let all = try! ctx.fetch(FetchDescriptor<WorkoutSession>())

        let before = StatsEngine.dayDurationResult(named: "Upper Day 1", in: all)
        XCTAssertEqual(before?.shortestSeconds, 60)

        third.durationSeconds = nil
        try? ctx.save()
        let after = StatsEngine.dayDurationResult(named: "Upper Day 1",
                                                  in: try! ctx.fetch(FetchDescriptor<WorkoutSession>()))
        XCTAssertEqual(after?.shortestSeconds, 3600, "the cleared session is gone, not a 0")
        XCTAssertEqual(after?.longestSeconds, 5400)
        XCTAssertEqual(after?.averageSeconds ?? 0, 4500, accuracy: 0.001)
    }

    /// The failure a clear-to-zero would cause, stated directly.
    func testAZeroWouldCorruptTheSpread() {
        let ctx = makeContext()
        session(ctx, 1, seconds: 3600)
        session(ctx, 3, seconds: 5400)
        session(ctx, 5, seconds: 0)   // what a careless "clear" would write
        let all = try! ctx.fetch(FetchDescriptor<WorkoutSession>())
        let r = StatsEngine.dayDurationResult(named: "Upper Day 1", in: all)
        XCTAssertEqual(r?.shortestSeconds, 0,
                       "a stored 0 DOES enter the spread — which is why clearing must write nil")
    }

    // MARK: - Editing

    func testSettingADurationCreatesASpreadWhereThereWasNone() {
        let ctx = makeContext()
        session(ctx, 1)   // no duration
        var all = try! ctx.fetch(FetchDescriptor<WorkoutSession>())
        XCTAssertNil(StatsEngine.dayDurationResult(named: "Upper Day 1", in: all),
                     "no durations at all means no row, not a row of zeroes")

        all.first?.durationSeconds = 4320
        try? ctx.save()
        all = try! ctx.fetch(FetchDescriptor<WorkoutSession>())
        let r = StatsEngine.dayDurationResult(named: "Upper Day 1", in: all)
        // One sample has no spread — all three figures are the same value.
        // Not a bug, and the thing most likely to look like one.
        XCTAssertEqual(r?.shortestSeconds, 4320)
        XCTAssertEqual(r?.longestSeconds, 4320)
        XCTAssertEqual(r?.averageSeconds ?? 0, 4320, accuracy: 0.001)
    }

    func testWholeMinutesRoundTrip() {
        let ctx = makeContext()
        let s = session(ctx, 1)
        s.durationSeconds = 1 * 3600 + 12 * 60
        try? ctx.save()
        XCTAssertEqual(s.durationSeconds, 4320)
        // h:mm:ss past the hour, m:ss below it — so a 72-minute entry
        // reads "1:12:00", and the seconds field is :00 rather than the
        // stopwatch noise a measured value carries.
        XCTAssertEqual(Formatters.duration(Double(s.durationSeconds!)), "1:12:00")
        XCTAssertEqual(Formatters.durationRoundedToMinute(Double(s.durationSeconds!)), "1:12")
        // The measured reading this store actually holds, for contrast.
        XCTAssertEqual(Formatters.duration(4328), "1:12:08")
    }

    // MARK: - Estimated flag

    func testEstimatedFlagDoesNotChangeAnyAverage() {
        let ctx = makeContext()
        session(ctx, 1, seconds: 3600, estimated: true)
        session(ctx, 3, seconds: 5400, estimated: false)
        let all = try! ctx.fetch(FetchDescriptor<WorkoutSession>())
        let r = StatsEngine.dayDurationResult(named: "Upper Day 1", in: all)
        // Deliberate: excluding estimates would empty the table that
        // hand-entering them exists to fill.
        XCTAssertEqual(r?.averageSeconds ?? 0, 4500, accuracy: 0.001)
        XCTAssertEqual(r?.shortestSeconds, 3600)
        XCTAssertEqual(r?.longestSeconds, 5400)
    }

    func testCountsScopeMatchesTheHoursSum() {
        let ctx = makeContext()
        ctx.insert(AppSettings())
        session(ctx, 1, seconds: 3600, estimated: true)
        session(ctx, 3, seconds: 5400, estimated: true)
        session(ctx, 5, seconds: 4328, estimated: false)
        session(ctx, 7, seconds: 3600, estimated: true, deload: true)  // deload: excluded
        session(ctx, 9)                                                // no duration: excluded
        try? ctx.save()

        let all = try! ctx.fetch(FetchDescriptor<WorkoutSession>())
        let stats = StatsEngine.compute(startDate: d(2026, 10, 1),
                                        sessionDates: all.map(\.date),
                                        allSessions: all)

        // Same population the hours figure sums: non-deload, has a
        // duration. The footnote must describe exactly that set.
        XCTAssertEqual(stats.durationSessionCount, 3)
        XCTAssertEqual(stats.estimatedDurationCount, 2)
        XCTAssertEqual(stats.allTimeHoursTrained,
                       Double(3600 + 5400 + 4328) / 3600, accuracy: 1e-9)
    }

    func testNoEstimatesMeansNothingToDisclose() {
        let ctx = makeContext()
        ctx.insert(AppSettings())
        session(ctx, 1, seconds: 4328, estimated: false)
        try? ctx.save()
        let all = try! ctx.fetch(FetchDescriptor<WorkoutSession>())
        let stats = StatsEngine.compute(startDate: d(2026, 10, 1),
                                        sessionDates: all.map(\.date),
                                        allSessions: all)
        XCTAssertEqual(stats.estimatedDurationCount, 0)
        XCTAssertEqual(stats.durationSessionCount, 1)
    }

    // MARK: - Round trip

    /// The mark must travel with the number. A restore that kept a
    /// hand-entered 72 minutes and dropped the "estimated" flag would
    /// launder every recollection into a measurement.
    func testEstimatedFlagSurvivesExportAndImport() async throws {
        let ctx = makeContext()
        ctx.insert(AppSettings())
        session(ctx, 1, label: "Upper Day 1", seconds: 4320, estimated: true)
        session(ctx, 3, label: "Lower Day 1", seconds: 4328, estimated: false)
        try? ctx.save()

        let data = ExportBuilder.workbook(from: ctx)
        let target = makeContext()
        target.insert(AppSettings())
        try target.save()
        let wb = try XCTUnwrap(ImportEngine.parseWorkbook(xlsxData: data))
        _ = await ImportEngine.importIntoStore(wb.historyRows, context: target)
        try target.save()

        let restored = try target.fetch(FetchDescriptor<WorkoutSession>())
        let estimated = restored.first { $0.durationSeconds == 4320 }
        let measured = restored.first { $0.durationSeconds == 4328 }
        XCTAssertEqual(estimated?.durationIsEstimated, true)
        XCTAssertEqual(measured?.durationIsEstimated, false,
                       "a measured duration must not come back marked as estimated")
    }

    /// An older export has no DurationEstimated column. Its durations were
    /// all stopwatch readings, so reading them as measured is right.
    func testOlderFileWithoutTheColumnReadsAsMeasured() {
        let data = XLSXWriter.makeWorkbook(sheets: [
            ("History", [
                [.string("Date"), .string("Exercise"), .string("Sets"),
                 .string("Weights"), .string("Reps"), .string("Duration")],
                [.string("2026-10-01"), .string("Bench Press"), .string("5"),
                 .string("185"), .string("5"), .number(4328)],
            ]),
        ])
        guard let wb = ImportEngine.parseWorkbook(xlsxData: data) else {
            return XCTFail("didn't parse")
        }
        XCTAssertEqual(wb.historyRows.first?.durationSeconds, 4328)
        XCTAssertEqual(wb.historyRows.first?.durationIsEstimated, false)
    }
}
