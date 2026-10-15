//
//  MacroLogTests.swift
//  TheJymTests
//
//  Daily macro logging.
//
//  The rule everything here protects is NIL-NOT-ZERO: a day with no fiber
//  entry is a day you didn't record fiber, not a day you ate none. It's
//  the same distinction durationSeconds and RestDayActivity.distance make,
//  and the one most likely to break silently — a restore that invented
//  zeroes looks identical to one that carried the nils until an average
//  comes out wrong months later.
//
//  The second is that an average NEVER travels without its denominator:
//  per-category averaging means protein over 20 days and fiber over 12
//  sit side by side on different bases.
//

import XCTest
import SwiftData
@testable import TheJym

@MainActor
final class MacroLogTests: XCTestCase {
    private let cal = Calendar.current
    private func d(_ day: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: day))!
    }

    private func makeContext() -> ModelContext {
        let c = try! ModelContainer(
            for: AppSettings.self, Bar.self, ExerciseDef.self, Phase.self, PhaseDay.self,
            PlannedExercise.self, WorkoutSession.self, ExerciseLog.self, SetLog.self,
            BodyWeightEntry.self, RestDayActivity.self, ActiveRecovery.self,
            TrainingDaysPerWeekChange.self, TimerTemplate.self, TimerPreset.self,
            BackupStatus.self, MacroTier.self, CycleMacroTag.self, MacroLog.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(c)
    }

    // MARK: - nil is not zero

    func testUnloggedCategoriesAreNilNotZero() {
        let log = MacroLog(date: d(15), proteinGrams: 185)
        XCTAssertEqual(log.proteinGrams, 185)
        XCTAssertNil(log.carbsGrams)
        XCTAssertNil(log.fatGrams)
        XCTAssertNotEqual(log.carbsGrams, 0, "absent is not zero")
    }

    func testAnEmptyLogIsRecognisable() {
        XCTAssertTrue(MacroLog(date: d(15)).isEmpty)
        XCTAssertFalse(MacroLog(date: d(15), fiberGrams: 30).isEmpty)
    }

    /// A logged zero is a real answer and must survive — only ABSENT is nil.
    func testAnExplicitZeroIsNotTreatedAsAbsent() {
        let log = MacroLog(date: d(15), sugarGrams: 0)
        XCTAssertEqual(log.sugarGrams, 0)
        XCTAssertFalse(log.isEmpty)
    }

    // MARK: - Calories

    /// Mirrors MacroTier.calories: sugar and fiber are subsets of carbs and
    /// never add.
    func testCaloriesIgnoreSugarAndFiber() {
        let log = MacroLog(date: d(15), proteinGrams: 185, carbsGrams: 260,
                           fatGrams: 75, sugarGrams: 90, fiberGrams: 36)
        // Split out: as one literal these exceeded the type checker's
        // budget for a single expression.
        let expected: Double = 740 + 1040 + 675      // 4x185 + 4x260 + 9x75
        let inflated: Double = expected + 504        // + 4x(90 sugar + 36 fiber)
        XCTAssertEqual(log.calories ?? 0, expected, accuracy: 1e-9)
        XCTAssertNotEqual(log.calories ?? 0, inflated, accuracy: 1e-9)
    }

    func testCaloriesAreNilWhenNoneOfTheThreeIsLogged() {
        XCTAssertNil(MacroLog(date: d(15)).calories)
        XCTAssertNil(MacroLog(date: d(15), sugarGrams: 90, fiberGrams: 36).calories,
                     "sugar and fiber alone imply no calorie figure")
    }

    /// A partial day still computes — the best available answer, with the
    /// day counts elsewhere stopping it being mistaken for a complete one.
    func testCaloriesComputeFromAPartialDay() {
        XCTAssertEqual(MacroLog(date: d(15), proteinGrams: 185).calories ?? 0, 740, accuracy: 1e-9)
    }

    // MARK: - Per-category averages carry their own denominator

    func testEachCategoryAveragesOverItsOwnDays() {
        let logs = [
            MacroLog(date: d(1), proteinGrams: 180, fiberGrams: 30),
            MacroLog(date: d(2), proteinGrams: 190),              // no fiber
            MacroLog(date: d(3), proteinGrams: 200),              // no fiber
        ]
        let protein = MacroAverage.compute(.protein, over: logs)
        let fiber = MacroAverage.compute(.fiber, over: logs)
        XCTAssertEqual(protein.mean ?? 0, 190, accuracy: 1e-9)
        XCTAssertEqual(protein.dayCount, 3)
        XCTAssertEqual(fiber.mean ?? 0, 30, accuracy: 1e-9)
        XCTAssertEqual(fiber.dayCount, 1, "fiber averages over its own single day")
    }

    /// The thing the type exists to prevent: two means on different bases
    /// looking comparable. Both are available, so a display can't show one
    /// without the other to hand.
    func testDenominatorsDifferAndAreBothReported() {
        let logs = (1...20).map { i in
            MacroLog(date: d(i), proteinGrams: 180,
                     fiberGrams: i <= 12 ? 30 : nil)
        }
        let all = MacroAverage.all(over: logs)
        let protein = all.first { $0.category == .protein }!
        let fiber = all.first { $0.category == .fiber }!
        XCTAssertEqual(protein.dayCount, 20)
        XCTAssertEqual(fiber.dayCount, 12)
        XCTAssertNotEqual(protein.dayCount, fiber.dayCount,
                          "different bases — the readout has to say so")
    }

    func testAverageIsNilWithNoDataForThatCategory() {
        let a = MacroAverage.compute(.sugar, over: [MacroLog(date: d(1), proteinGrams: 180)])
        XCTAssertNil(a.mean)
        XCTAssertEqual(a.dayCount, 0)
    }

    /// A logged zero counts toward the average; an absent value doesn't.
    func testZeroCountsButAbsentDoesNot() {
        let logs = [MacroLog(date: d(1), sugarGrams: 0), MacroLog(date: d(2), sugarGrams: 50),
                    MacroLog(date: d(3))]
        let a = MacroAverage.compute(.sugar, over: logs)
        XCTAssertEqual(a.dayCount, 2, "the unlogged day is not a zero")
        XCTAssertEqual(a.mean ?? -1, 25, accuracy: 1e-9)
    }

    // MARK: - Upsert

    func testOneLogPerCalendarDay() {
        let ctx = makeContext()
        let morning = cal.date(byAdding: .hour, value: 8, to: d(15))!
        let evening = cal.date(byAdding: .hour, value: 21, to: d(15))!
        let log = MacroLog(date: morning, proteinGrams: 100)
        ctx.insert(log)
        try? ctx.save()
        let found = MacroLog.log(on: evening, in: try! ctx.fetch(FetchDescriptor<MacroLog>()))
        XCTAssertIdentical(found, log, "same calendar day, same log")
    }

    func testInitNormalisesToStartOfDay() {
        let noon = cal.date(byAdding: .hour, value: 12, to: d(15))!
        XCTAssertEqual(MacroLog(date: noon).date, d(15))
    }

    // MARK: - Weight upsert is shared

    func testWeightUpsertUpdatesRatherThanDuplicating() {
        let ctx = makeContext()
        BodyWeightEntry.upsert(weight: 181.5, on: d(15),
                               in: try! ctx.fetch(FetchDescriptor<BodyWeightEntry>()), context: ctx)
        try? ctx.save()
        BodyWeightEntry.upsert(weight: 182.0, on: d(15),
                               in: try! ctx.fetch(FetchDescriptor<BodyWeightEntry>()), context: ctx)
        try? ctx.save()
        let all = try! ctx.fetch(FetchDescriptor<BodyWeightEntry>())
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.weight, 182.0)
    }

    // MARK: - Round trip

    func testMacroLogsSurviveExportAndImportWithNilsIntact() async throws {
        let ctx = makeContext()
        ctx.insert(AppSettings())
        ctx.insert(MacroLog(date: d(14), proteinGrams: 186, carbsGrams: 261,
                            fatGrams: 74, sugarGrams: 91, fiberGrams: 37))
        // Protein and fiber only.
        ctx.insert(MacroLog(date: d(15), proteinGrams: 172, fiberGrams: 29))
        try ctx.save()

        let data = ExportBuilder.workbook(from: ctx)
        let target = makeContext()
        target.insert(AppSettings())
        try target.save()
        let wb = try XCTUnwrap(ImportEngine.parseWorkbook(xlsxData: data))
        ImportEngine.restoreMacroLogs(wb.macroRows, context: target)
        try target.save()

        let logs = try target.fetch(FetchDescriptor<MacroLog>()).sorted { $0.date < $1.date }
        XCTAssertEqual(logs.count, 2)
        XCTAssertEqual(logs[0].proteinGrams, 186)
        XCTAssertEqual(logs[0].fiberGrams, 37)
        // The whole point: a blank cell must come back nil, not 0.
        XCTAssertEqual(logs[1].proteinGrams, 172)
        XCTAssertEqual(logs[1].fiberGrams, 29)
        XCTAssertNil(logs[1].carbsGrams, "a blank cell must restore as nil")
        XCTAssertNil(logs[1].fatGrams)
        XCTAssertNil(logs[1].sugarGrams)
    }

    /// The Macros sheet carries a Weight column for readability, but the
    /// importer must NOT read it — History restores weigh-ins, and both
    /// writing the same row would have them fight.
    func testMacrosSheetWeightColumnIsNotImported() async throws {
        let ctx = makeContext()
        ctx.insert(AppSettings())
        BodyWeightEntry.upsert(weight: 181.5, on: d(14), in: [], context: ctx)
        ctx.insert(MacroLog(date: d(14), proteinGrams: 186))
        try ctx.save()

        let data = ExportBuilder.workbook(from: ctx)
        let target = makeContext()
        target.insert(AppSettings())
        try target.save()
        let wb = try XCTUnwrap(ImportEngine.parseWorkbook(xlsxData: data))
        ImportEngine.restoreMacroLogs(wb.macroRows, context: target)
        try target.save()

        XCTAssertEqual(try target.fetch(FetchDescriptor<MacroLog>()).count, 1)
        XCTAssertTrue(try target.fetch(FetchDescriptor<BodyWeightEntry>()).isEmpty,
                      "restoreMacroLogs must not create weigh-ins")
    }

    func testReimportUpdatesLogsInPlace() async throws {
        let ctx = makeContext()
        ctx.insert(AppSettings())
        ctx.insert(MacroLog(date: d(14), proteinGrams: 186, carbsGrams: 261))
        try ctx.save()
        let data = ExportBuilder.workbook(from: ctx)

        let wb = try XCTUnwrap(ImportEngine.parseWorkbook(xlsxData: data))
        ImportEngine.restoreMacroLogs(wb.macroRows, context: ctx)
        ImportEngine.restoreMacroLogs(wb.macroRows, context: ctx)
        try ctx.save()
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<MacroLog>()).count, 1)
    }

    func testOlderFileWithoutAMacrosSheetParsesToNoRows() {
        let data = XLSXWriter.makeWorkbook(sheets: [
            ("History", [[.string("Date"), .string("Exercise"), .string("Sets"),
                          .string("Weights"), .string("Reps")]]),
        ])
        let wb = ImportEngine.parseWorkbook(xlsxData: data)
        XCTAssertEqual(wb?.macroRows.count, 0)
    }
}
