//
//  CycleMacroTagTests.swift
//  TheJymTests
//
//  Per-cycle tier tagging.
//
//  The load-bearing decision is that the tag holds a RELATIONSHIP to its
//  tier, never a stored name. A stored name would orphan every tag the
//  moment a tier is renamed — the identical failure to a rep ceiling keyed
//  on the reps array an edit then changes. The rename test below is the
//  one that would catch a regression to a String.
//

import XCTest
import SwiftData
@testable import TheJym

@MainActor
final class CycleMacroTagTests: XCTestCase {

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

    private func fixture(_ ctx: ModelContext) -> (Phase, MacroTier, MacroTier) {
        let phase = Phase(number: 3, totalCycles: 8, startDate: .now, isActive: true)
        ctx.insert(phase)
        let cut = MacroTier(name: "2250", order: 0, proteinGrams: 185, carbsGrams: 220, fatGrams: 70)
        let bulk = MacroTier(name: "2550", order: 1, proteinGrams: 185, carbsGrams: 272, fatGrams: 80)
        ctx.insert(cut); ctx.insert(bulk)
        try? ctx.save()
        return (phase, cut, bulk)
    }

    // MARK: - The relationship

    /// The regression a stored name would cause: rename the tier and every
    /// tag goes on pointing at it.
    func testRenamingATierDoesNotOrphanItsTags() {
        let ctx = makeContext()
        let (phase, cut, _) = fixture(ctx)
        CycleMacroTag.set(cut, for: phase, cycle: 1, context: ctx)
        try? ctx.save()

        cut.name = "2250 v2"
        try? ctx.save()

        let tag = try! XCTUnwrap(CycleMacroTag.tag(for: phase, cycle: 1))
        XCTAssertEqual(tag.tier?.name, "2250 v2",
                       "the tag follows the rename — it holds the object, not the name")
        XCTAssertIdentical(tag.tier, cut)
    }

    // MARK: - Upsert

    func testTaggingTwiceUpdatesRatherThanAddingASecondTag() {
        let ctx = makeContext()
        let (phase, cut, bulk) = fixture(ctx)
        CycleMacroTag.set(cut, for: phase, cycle: 1, context: ctx)
        CycleMacroTag.set(bulk, for: phase, cycle: 1, context: ctx)
        try? ctx.save()
        XCTAssertEqual(try! ctx.fetch(FetchDescriptor<CycleMacroTag>()).count, 1)
        XCTAssertEqual(CycleMacroTag.tag(for: phase, cycle: 1)?.tier?.name, "2550")
    }

    func testSettingNilClearsTheTag() {
        let ctx = makeContext()
        let (phase, cut, _) = fixture(ctx)
        CycleMacroTag.set(cut, for: phase, cycle: 1, context: ctx)
        try? ctx.save()
        CycleMacroTag.set(nil, for: phase, cycle: 1, context: ctx)
        try? ctx.save()
        XCTAssertNil(CycleMacroTag.tag(for: phase, cycle: 1))
        XCTAssertTrue(try! ctx.fetch(FetchDescriptor<CycleMacroTag>()).isEmpty)
    }

    func testDifferentCyclesTagIndependently() {
        let ctx = makeContext()
        let (phase, cut, bulk) = fixture(ctx)
        CycleMacroTag.set(cut, for: phase, cycle: 1, context: ctx)
        CycleMacroTag.set(bulk, for: phase, cycle: 2, context: ctx)
        try? ctx.save()
        XCTAssertEqual(CycleMacroTag.tag(for: phase, cycle: 1)?.tier?.name, "2250")
        XCTAssertEqual(CycleMacroTag.tag(for: phase, cycle: 2)?.tier?.name, "2550")
        XCTAssertNil(CycleMacroTag.tag(for: phase, cycle: 3))
    }

    // MARK: - Cascade

    func testDeletingATierDeletesItsTags() {
        let ctx = makeContext()
        let (phase, cut, bulk) = fixture(ctx)
        CycleMacroTag.set(cut, for: phase, cycle: 1, context: ctx)
        CycleMacroTag.set(bulk, for: phase, cycle: 2, context: ctx)
        try? ctx.save()

        ctx.delete(cut)
        try? ctx.save()

        let remaining = try! ctx.fetch(FetchDescriptor<CycleMacroTag>())
        XCTAssertEqual(remaining.count, 1, "2250's tag went with it")
        XCTAssertEqual(remaining.first?.tier?.name, "2550", "2550's tag is untouched")
    }

    func testDeletingAPhaseDeletesItsTags() {
        let ctx = makeContext()
        let (phase, cut, _) = fixture(ctx)
        CycleMacroTag.set(cut, for: phase, cycle: 1, context: ctx)
        try? ctx.save()
        ctx.delete(phase)
        try? ctx.save()
        XCTAssertTrue(try! ctx.fetch(FetchDescriptor<CycleMacroTag>()).isEmpty)
        XCTAssertEqual(try! ctx.fetch(FetchDescriptor<MacroTier>()).count, 2,
                       "the tiers themselves survive — only the tags were phase-scoped")
    }

    // MARK: - The delete warning

    func testNoWarningForAnUntaggedTier() {
        let ctx = makeContext()
        let (_, cut, _) = fixture(ctx)
        XCTAssertNil(MacroTiersView.deleteWarning(for: cut),
                     "confirm only when the impact is non-zero")
    }

    /// The wording has to name the CONSEQUENCE, not the row count.
    func testWarningNamesTheLostAnalysisNotJustTheTagCount() {
        let ctx = makeContext()
        let (phase, cut, _) = fixture(ctx)
        CycleMacroTag.set(cut, for: phase, cycle: 1, context: ctx)
        CycleMacroTag.set(cut, for: phase, cycle: 2, context: ctx)
        try? ctx.save()

        let text = try! XCTUnwrap(MacroTiersView.deleteWarning(for: cut))
        XCTAssertTrue(text.contains("2 cycles ran on 2250"), text)
        XCTAssertTrue(text.contains("Phase 3 cycle 1"), text)
        XCTAssertTrue(text.contains("Phase 3 cycle 2"), text)
        XCTAssertTrue(text.contains("measured against"), text)
        XCTAssertTrue(text.contains("can't be worked out afterwards"), text)
    }

    // MARK: - Round trip

    func testTagsSurviveExportAndImport() async throws {
        let ctx = makeContext()
        ctx.insert(AppSettings())
        let (phase, cut, bulk) = fixture(ctx)
        CycleMacroTag.set(cut, for: phase, cycle: 1, context: ctx)
        CycleMacroTag.set(bulk, for: phase, cycle: 4, context: ctx)
        try ctx.save()

        let data = ExportBuilder.workbook(from: ctx)
        let target = makeContext()
        target.insert(AppSettings())
        try target.save()
        let wb = try XCTUnwrap(ImportEngine.parseWorkbook(xlsxData: data))
        ImportEngine.restoreProgram(wb.program, context: target)
        try target.save()

        let restoredPhase = try XCTUnwrap(try target.fetch(FetchDescriptor<Phase>()).first)
        XCTAssertEqual(CycleMacroTag.tag(for: restoredPhase, cycle: 1)?.tier?.name, "2250")
        XCTAssertEqual(CycleMacroTag.tag(for: restoredPhase, cycle: 4)?.tier?.name, "2550")
        XCTAssertNil(CycleMacroTag.tag(for: restoredPhase, cycle: 2))
        XCTAssertEqual(try target.fetch(FetchDescriptor<CycleMacroTag>()).count, 2)
    }

    /// The restored tag must hold a real relationship to the restored
    /// tier, not a dangling one — provable by renaming after the import.
    func testRestoredTagsAreRealRelationships() async throws {
        let ctx = makeContext()
        ctx.insert(AppSettings())
        let (phase, cut, _) = fixture(ctx)
        CycleMacroTag.set(cut, for: phase, cycle: 1, context: ctx)
        try ctx.save()
        let data = ExportBuilder.workbook(from: ctx)

        let target = makeContext()
        target.insert(AppSettings())
        try target.save()
        let wb = try XCTUnwrap(ImportEngine.parseWorkbook(xlsxData: data))
        ImportEngine.restoreProgram(wb.program, context: target)
        try target.save()

        let restoredTier = try XCTUnwrap(
            try target.fetch(FetchDescriptor<MacroTier>()).first { $0.name == "2250" })
        restoredTier.name = "renamed after restore"
        try target.save()

        let restoredPhase = try XCTUnwrap(try target.fetch(FetchDescriptor<Phase>()).first)
        XCTAssertEqual(CycleMacroTag.tag(for: restoredPhase, cycle: 1)?.tier?.name,
                       "renamed after restore")
    }

    /// Re-importing the same file must not stack duplicate tags.
    func testReimportDoesNotDuplicateTags() async throws {
        let ctx = makeContext()
        ctx.insert(AppSettings())
        let (phase, cut, _) = fixture(ctx)
        CycleMacroTag.set(cut, for: phase, cycle: 1, context: ctx)
        try ctx.save()
        let data = ExportBuilder.workbook(from: ctx)

        let wb = try XCTUnwrap(ImportEngine.parseWorkbook(xlsxData: data))
        ImportEngine.restoreProgram(wb.program, context: ctx)
        ImportEngine.restoreProgram(wb.program, context: ctx)
        try ctx.save()
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<CycleMacroTag>()).count, 1)
    }
}
