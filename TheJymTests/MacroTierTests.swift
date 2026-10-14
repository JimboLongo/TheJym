//
//  MacroTierTests.swift
//  TheJymTests
//
//  MacroTier's calorie math, coherence warning, name uniqueness, and
//  export round trip.
//
//  The calorie rule is the load-bearing one: sugar and fiber are SUBSETS
//  of carbs, so adding them would inflate every figure the app shows. The
//  tests below pin that with numbers chosen so a wrong formula can't
//  coincidentally agree.
//

import XCTest
import SwiftData
@testable import TheJym

@MainActor
final class MacroTierTests: XCTestCase {

    private func makeContext() -> ModelContext {
        let c = try! ModelContainer(
            for: AppSettings.self, Bar.self, ExerciseDef.self, Phase.self, PhaseDay.self,
            PlannedExercise.self, WorkoutSession.self, ExerciseLog.self, SetLog.self,
            BodyWeightEntry.self, RestDayActivity.self, ActiveRecovery.self,
            TrainingDaysPerWeekChange.self, TimerTemplate.self, TimerPreset.self,
            BackupStatus.self, MacroTier.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(c)
    }

    private func bulk() -> MacroTier {
        MacroTier(name: "Bulk", order: 0, proteinGrams: 180, carbsGrams: 300,
                  fatGrams: 80, sugarGrams: 60, fiberGrams: 35)
    }

    // MARK: - Calories

    /// 4×180 + 4×300 + 9×80 = 720 + 1200 + 720 = 2640.
    func testCaloriesAreProteinAndCarbsAtFourAndFatAtNine() {
        XCTAssertEqual(bulk().calories, 2640, accuracy: 1e-9)
    }

    /// The failure this whole rule exists to prevent. Adding sugar and
    /// fiber on top would give 2640 + 4×60 + 4×35 = 3020 — 380 cal of pure
    /// double-counting.
    func testSugarAndFiberAreNotAddedOnTopOfCarbs() {
        let tier = bulk()
        XCTAssertEqual(tier.calories, 2640, accuracy: 1e-9)
        XCTAssertNotEqual(tier.calories, 3020,
                          "sugar and fiber are inside carbs, never added to them")
    }

    /// Changing sugar or fiber alone must not move the calorie figure at
    /// all — they're a breakdown of carbs, not a contribution.
    func testCaloriesIgnoreSugarAndFiberEntirely() {
        let tier = bulk()
        let before = tier.calories
        tier.sugarGrams = 0
        tier.fiberGrams = 0
        XCTAssertEqual(tier.calories, before, accuracy: 1e-9)
        tier.sugarGrams = 120
        tier.fiberGrams = 50
        XCTAssertEqual(tier.calories, before, accuracy: 1e-9)
    }

    /// Fiber counts at 4, not 2, to agree with MyFitnessPal — the source
    /// these numbers are transcribed from. At 2 cal/g this tier would read
    /// 2640 − 2×35 = 2570, and the app would disagree with the app the
    /// number came from by 70 cal every day.
    func testFiberCountsAtFourNotTwo() {
        let tier = bulk()
        XCTAssertEqual(tier.calories, 2640, accuracy: 1e-9)
        XCTAssertNotEqual(tier.calories, 2570,
                          "fiber at 2 cal/g would disagree with MyFitnessPal daily")
    }

    func testEmptyTierIsZeroCalories() {
        XCTAssertEqual(MacroTier().calories, 0, accuracy: 1e-9)
    }

    // MARK: - Coherence

    func testCoherentTierHasNoWarning() {
        XCTAssertNil(bulk().coherenceWarning)
        XCTAssertFalse(bulk().subsetsExceedCarbs)
    }

    func testSubsetsExceedingCarbsWarns() {
        let tier = MacroTier(name: "Broken", carbsGrams: 50, sugarGrams: 40, fiberGrams: 30)
        XCTAssertTrue(tier.subsetsExceedCarbs)
        let warning = try! XCTUnwrap(tier.coherenceWarning)
        XCTAssertTrue(warning.contains("70"), warning)   // 40 + 30
        XCTAssertTrue(warning.contains("50"), warning)
    }

    /// Exactly equal is coherent — all carbs accounted for as sugar and
    /// fiber is unusual but not contradictory.
    func testSubsetsExactlyEqualToCarbsIsNotAWarning() {
        let tier = MacroTier(name: "Edge", carbsGrams: 70, sugarGrams: 40, fiberGrams: 30)
        XCTAssertFalse(tier.subsetsExceedCarbs)
        XCTAssertNil(tier.coherenceWarning)
    }

    /// It warns rather than blocking, so an incoherent tier still computes
    /// a calorie figure from its carbs — deliberate: a prompt you hit on a
    /// typo is one you learn to fight.
    func testAnIncoherentTierStillComputesCalories() {
        let tier = MacroTier(name: "Broken", proteinGrams: 100, carbsGrams: 50,
                             fatGrams: 10, sugarGrams: 40, fiberGrams: 30)
        XCTAssertEqual(tier.calories, 400 + 200 + 90, accuracy: 1e-9)
    }

    // MARK: - Direction is per category, not per tier

    func testDirectionsAreFixedPerCategory() {
        XCTAssertEqual(MacroCategory.protein.direction, .atLeast)
        XCTAssertEqual(MacroCategory.fiber.direction, .atLeast)
        XCTAssertEqual(MacroCategory.carbs.direction, .about)
        XCTAssertEqual(MacroCategory.fat.direction, .about)
        XCTAssertEqual(MacroCategory.sugar.direction, .atMost)
    }

    /// The point of the directions: "+15g" must not render alike on a
    /// floor and a ceiling.
    func testProteinAndSugarPointOppositeWays() {
        XCTAssertNotEqual(MacroCategory.protein.direction, MacroCategory.sugar.direction)
        XCTAssertEqual(MacroCategory.protein.direction.symbol, "\u{2265}")
        XCTAssertEqual(MacroCategory.sugar.direction.symbol, "\u{2264}")
        XCTAssertEqual(MacroCategory.carbs.direction.symbol, "\u{2248}")
    }

    func testOnlySugarAndFiberAreCarbSubsets() {
        XCTAssertTrue(MacroCategory.sugar.isCarbSubset)
        XCTAssertTrue(MacroCategory.fiber.isCarbSubset)
        for c in [MacroCategory.protein, .carbs, .fat] {
            XCTAssertFalse(c.isCarbSubset, "\(c.label)")
        }
    }

    func testGramsAccessorsCoverEveryCategory() {
        let tier = MacroTier()
        for (i, c) in MacroCategory.allCases.enumerated() {
            tier.setGrams(Double(i + 1) * 10, for: c)
        }
        for (i, c) in MacroCategory.allCases.enumerated() {
            XCTAssertEqual(tier.grams(c), Double(i + 1) * 10, "\(c.label)")
        }
    }

    // MARK: - Name uniqueness

    func testNameIsTakenIsCaseAndWhitespaceInsensitive() {
        let tiers = [MacroTier(name: "Bulk"), MacroTier(name: "Cut")]
        XCTAssertTrue(MacroTier.nameIsTaken("bulk", excluding: nil, in: tiers))
        XCTAssertTrue(MacroTier.nameIsTaken("  BULK  ", excluding: nil, in: tiers))
        XCTAssertFalse(MacroTier.nameIsTaken("Maintain", excluding: nil, in: tiers))
    }

    /// Renaming a tier to its own name isn't a collision.
    func testATierDoesNotCollideWithItself() {
        let bulk = MacroTier(name: "Bulk")
        XCTAssertFalse(MacroTier.nameIsTaken("Bulk", excluding: bulk, in: [bulk]))
    }

    func testEmptyNameIsNotTreatedAsTaken() {
        XCTAssertFalse(MacroTier.nameIsTaken("", excluding: nil, in: [MacroTier(name: "Bulk")]))
    }

    // MARK: - Round trip

    func testTiersSurviveExportAndImport() async throws {
        let ctx = makeContext()
        ctx.insert(AppSettings())
        for (i, t) in [bulk(),
                       MacroTier(name: "Cut", order: 1, proteinGrams: 200, carbsGrams: 150,
                                 fatGrams: 55, sugarGrams: 25, fiberGrams: 30)].enumerated() {
            t.order = i
            ctx.insert(t)
        }
        try ctx.save()

        let data = ExportBuilder.workbook(from: ctx)
        let target = makeContext()
        target.insert(AppSettings())
        try target.save()
        let wb = try XCTUnwrap(ImportEngine.parseWorkbook(xlsxData: data))
        ImportEngine.restoreProgram(wb.program, context: target)
        try target.save()

        let restored = try target.fetch(FetchDescriptor<MacroTier>()).sorted { $0.order < $1.order }
        XCTAssertEqual(restored.map(\.name), ["Bulk", "Cut"])
        XCTAssertEqual(restored[0].proteinGrams, 180)
        XCTAssertEqual(restored[0].carbsGrams, 300)
        XCTAssertEqual(restored[0].fatGrams, 80)
        XCTAssertEqual(restored[0].sugarGrams, 60)
        XCTAssertEqual(restored[0].fiberGrams, 35)
        XCTAssertEqual(restored[0].calories, 2640, accuracy: 1e-9)
        XCTAssertEqual(restored[1].name, "Cut")
        XCTAssertEqual(restored[1].order, 1)
    }

    /// Re-importing must UPDATE a tier of the same name, not duplicate it
    /// and not silently skip it — the rule restoreProgram already follows
    /// for phases and timer templates.
    func testReimportUpdatesInPlaceRatherThanDuplicating() async throws {
        let ctx = makeContext()
        ctx.insert(AppSettings())
        let original = bulk()
        ctx.insert(original)
        try ctx.save()
        let data = ExportBuilder.workbook(from: ctx)

        // The store's copy has since drifted.
        original.proteinGrams = 1
        original.carbsGrams = 1
        original.order = 9
        try ctx.save()

        let wb = try XCTUnwrap(ImportEngine.parseWorkbook(xlsxData: data))
        ImportEngine.restoreProgram(wb.program, context: ctx)
        try ctx.save()

        let all = try ctx.fetch(FetchDescriptor<MacroTier>())
        XCTAssertEqual(all.count, 1, "matched by name and updated, never duplicated")
        XCTAssertEqual(all[0].proteinGrams, 180, "the file's values win")
        XCTAssertEqual(all[0].carbsGrams, 300)
        XCTAssertEqual(all[0].order, 0)
    }

    func testReimportMatchesNameCaseInsensitively() async throws {
        let ctx = makeContext()
        ctx.insert(AppSettings())
        ctx.insert(bulk())
        try ctx.save()
        let data = ExportBuilder.workbook(from: ctx)

        let target = makeContext()
        target.insert(AppSettings())
        target.insert(MacroTier(name: "  bulk  ", proteinGrams: 1))
        try target.save()

        let wb = try XCTUnwrap(ImportEngine.parseWorkbook(xlsxData: data))
        ImportEngine.restoreProgram(wb.program, context: target)
        try target.save()

        let all = try target.fetch(FetchDescriptor<MacroTier>())
        XCTAssertEqual(all.count, 1, "\"  bulk  \" and \"Bulk\" are the same tier")
        XCTAssertEqual(all[0].proteinGrams, 180)
    }

    // MARK: - Dates

    func testNewTierIsCreatedAndModifiedNow() {
        let tier = MacroTier(name: "Cut")
        XCTAssertEqual(tier.createdAt.timeIntervalSinceNow, 0, accuracy: 5)
        XCTAssertEqual(tier.modifiedAt.timeIntervalSinceNow, 0, accuracy: 5)
    }

    /// An untouched tier reads as one short line — no "edited" to add.
    func testVintageLabelOmitsEditedWhenNeverRevised() {
        let day = Date(timeIntervalSince1970: 1_760_000_000)
        let tier = MacroTier(name: "Cut", createdAt: day, modifiedAt: day)
        XCTAssertTrue(tier.vintageLabel.hasPrefix("Created "), tier.vintageLabel)
        XCTAssertFalse(tier.vintageLabel.contains("edited"), tier.vintageLabel)
    }

    func testVintageLabelShowsBothOnceRevised() {
        let made = Date(timeIntervalSince1970: 1_760_000_000)
        let tier = MacroTier(name: "Cut", createdAt: made,
                             modifiedAt: made.addingTimeInterval(40 * 86_400))
        XCTAssertTrue(tier.vintageLabel.contains("Created "), tier.vintageLabel)
        XCTAssertTrue(tier.vintageLabel.contains("edited "), tier.vintageLabel)
    }

    /// Edits made the same day aren't a different vintage — the label would
    /// otherwise say "Created Oct 14 · edited Oct 14".
    func testSameDayEditDoesNotAddAnEditedDate() {
        let morning = Date(timeIntervalSince1970: 1_760_000_000)
        let tier = MacroTier(name: "Cut", createdAt: morning,
                             modifiedAt: morning.addingTimeInterval(3 * 3600))
        XCTAssertFalse(tier.vintageLabel.contains("edited"), tier.vintageLabel)
    }

    // MARK: - What counts as a revision

    func testDiffersDetectsAChangedValue() {
        let tier = bulk()
        var same = Dictionary(uniqueKeysWithValues:
            MacroCategory.allCases.map { ($0, tier.grams($0)) })
        XCTAssertFalse(tier.differs(name: "Bulk", grams: same),
                       "re-saving without a change is not a revision")
        same[.fat] = 81
        XCTAssertTrue(tier.differs(name: "Bulk", grams: same))
    }

    func testDiffersDetectsARename() {
        let tier = bulk()
        let same = Dictionary(uniqueKeysWithValues:
            MacroCategory.allCases.map { ($0, tier.grams($0)) })
        XCTAssertTrue(tier.differs(name: "Bulk 2.0", grams: same))
    }

    // MARK: - Dates round-trip

    func testBothDatesSurviveExportAndImport() async throws {
        let ctx = makeContext()
        ctx.insert(AppSettings())
        let made = Date(timeIntervalSince1970: 1_750_000_000)
        let edited = Date(timeIntervalSince1970: 1_760_000_000)
        let tier = bulk()
        tier.createdAt = made
        tier.modifiedAt = edited
        ctx.insert(tier)
        try ctx.save()

        let data = ExportBuilder.workbook(from: ctx)
        let target = makeContext()
        target.insert(AppSettings())
        try target.save()
        let wb = try XCTUnwrap(ImportEngine.parseWorkbook(xlsxData: data))
        ImportEngine.restoreProgram(wb.program, context: target)
        try target.save()

        let restored = try XCTUnwrap(try target.fetch(FetchDescriptor<MacroTier>()).first)
        let cal = Calendar.current
        XCTAssertTrue(cal.isDate(restored.createdAt, inSameDayAs: made))
        XCTAssertTrue(cal.isDate(restored.modifiedAt, inSameDayAs: edited))
        XCTAssertFalse(cal.isDate(restored.createdAt, inSameDayAs: restored.modifiedAt),
                       "the two dates must not collapse into one")
    }

    /// Restoring must not stamp "now" — otherwise every recovery would make
    /// the whole library look freshly revised, and a backup's whole job is
    /// to bring back what was true.
    func testRestoreDoesNotStampTodayOverTheFilesDates() async throws {
        let ctx = makeContext()
        ctx.insert(AppSettings())
        let made = Date(timeIntervalSince1970: 1_700_000_000)
        let tier = bulk()
        tier.createdAt = made
        tier.modifiedAt = made
        ctx.insert(tier)
        try ctx.save()
        let data = ExportBuilder.workbook(from: ctx)

        // A fresh store, as after a reinstall.
        let target = makeContext()
        target.insert(AppSettings())
        try target.save()
        let wb = try XCTUnwrap(ImportEngine.parseWorkbook(xlsxData: data))
        ImportEngine.restoreProgram(wb.program, context: target)
        try target.save()

        let restored = try XCTUnwrap(try target.fetch(FetchDescriptor<MacroTier>()).first)
        XCTAssertTrue(Calendar.current.isDate(restored.createdAt, inSameDayAs: made))
        XCTAssertGreaterThan(abs(restored.createdAt.timeIntervalSinceNow), 86_400,
                             "a restored tier must not read as created today")
    }

    /// An older export has no date columns. Restoring it must leave an
    /// existing tier's dates alone rather than blanking them.
    func testOlderFileWithoutDateColumnsLeavesDatesAlone() async throws {
        let ctx = makeContext()
        ctx.insert(AppSettings())
        let made = Date(timeIntervalSince1970: 1_700_000_000)
        let tier = bulk()
        tier.createdAt = made
        tier.modifiedAt = made
        ctx.insert(tier)
        try ctx.save()

        var program = ImportEngine.Program()
        program.macroTiers = [("Bulk", 0, 180, 300, 80, 60, 35, nil, nil)]
        ImportEngine.restoreProgram(program, context: ctx)
        try ctx.save()

        let restored = try XCTUnwrap(try ctx.fetch(FetchDescriptor<MacroTier>()).first)
        XCTAssertTrue(Calendar.current.isDate(restored.createdAt, inSameDayAs: made))
    }

    /// An older file has no MacroTier rows; restoring it must not wipe the
    /// tiers already in the store.
    func testOlderFileWithoutTierRowsLeavesExistingTiersAlone() async throws {
        let ctx = makeContext()
        ctx.insert(AppSettings())
        ctx.insert(bulk())
        try ctx.save()
        ImportEngine.restoreProgram(ImportEngine.Program(), context: ctx)
        try ctx.save()
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<MacroTier>()).count, 1)
    }
}
