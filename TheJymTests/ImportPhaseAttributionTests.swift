//
//  ImportPhaseAttributionTests.swift
//  TheJymTests
//
//  Reproduces the exact sequence HistoryView's "import -> review -> Start
//  Phase" flow runs: create a Phase + its PhaseDays (mirroring
//  PhaseBuilderView.save()), then immediately call
//  ImportEngine.importIntoStore(attributeTo:) with that just-created,
//  not-yet-saved Phase — exactly like onPhaseCreated fires before
//  dismiss(). Isolates whether the "no history imported" report is an
//  ImportEngine bug or a UI-wiring bug.
//

import XCTest
import SwiftData
@testable import TheJym

final class ImportPhaseAttributionTests: XCTestCase {
    @MainActor
    private func makeContext() -> ModelContext {
        let container = try! ModelContainer(
            for: AppSettings.self, Bar.self, ExerciseDef.self,
                 Phase.self, PhaseDay.self, PlannedExercise.self,
                 WorkoutSession.self, ExerciseLog.self, SetLog.self,
                 BodyWeightEntry.self, RestDayActivity.self,
                 ActiveRecovery.self, TrainingDaysPerWeekChange.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @MainActor
    func testForcedPhaseAttributionRightAfterCreation() async {
        let context = makeContext()

        // Mirror PhaseBuilderView.save() exactly: insert the Phase, then
        // insert each PhaseDay with day.phase set, with NO context.save()
        // in between (matches save() calling context.save() once at the
        // very end, then onPhaseCreated(phase) firing right after).
        let phase = Phase(number: 1, totalCycles: 8)
        context.insert(phase)

        let day1 = PhaseDay(order: 0, name: "Upper A", isRest: false)
        day1.phase = phase
        context.insert(day1)

        let day2 = PhaseDay(order: 1, name: "Rest", isRest: true)
        day2.phase = phase
        context.insert(day2)

        try? context.save()

        XCTAssertEqual(phase.orderedDays.count, 2, "Phase should see its just-inserted days without a fresh fetch")

        // A row whose Day label matches "Upper A" case-insensitively.
        let row = ImportEngine.ImportedEntry(
            date: Date(),
            exerciseName: "Back Squat",
            kind: .exercise(goalType: .fixedSets, targetReps: [5, 5, 5], weights: [135, 135, 135], reps: [5, 5, 5]),
            phaseNumber: nil,
            dayLabel: "Upper A",
            equipmentName: nil
        )

        let result = await ImportEngine.importIntoStore([row], context: context, attributeTo: phase)

        XCTAssertEqual(result.sessionsCreated, 1, "Expected exactly one session to be created")
        XCTAssertEqual(result.setsImported, 3, "Expected all 3 sets to import")

        let sessions = (try? context.fetch(FetchDescriptor<WorkoutSession>())) ?? []
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.phase?.number, 1, "Session should be attributed to the forced Phase")
        XCTAssertEqual(sessions.first?.day?.name, "Upper A")

        let logs = (try? context.fetch(FetchDescriptor<ExerciseLog>())) ?? []
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(logs.first?.exerciseName, "Back Squat")

        let sets = (try? context.fetch(FetchDescriptor<SetLog>())) ?? []
        XCTAssertEqual(sets.count, 3)
    }

    /// A rest-activity row should only be retroactively attributed to the
    /// forced Phase from whichever date this same import's own exercise
    /// rows first got attributed onward — a "Rest" row that predates that
    /// (even though its label matches the Phase's Rest day too) should
    /// stay unattributed, same as if no Phase had ever matched it.
    @MainActor
    func testRestRowOnlyAttributedFromEarliestAttributedExerciseDateOnward() async {
        let context = makeContext()

        let phase = Phase(number: 1, totalCycles: 8)
        context.insert(phase)
        let trainDay = PhaseDay(order: 0, name: "Upper A", isRest: false)
        trainDay.phase = phase
        context.insert(trainDay)
        let restDay = PhaseDay(order: 1, name: "Rest", isRest: true)
        restDay.phase = phase
        context.insert(restDay)
        try? context.save()

        let cal = Calendar.current
        let exerciseDate = cal.startOfDay(for: Date())
        let earlyRestDate = cal.date(byAdding: .day, value: -5, to: exerciseDate)!
        let lateRestDate = cal.date(byAdding: .day, value: 5, to: exerciseDate)!

        let exerciseRow = ImportEngine.ImportedEntry(
            date: exerciseDate, exerciseName: "Back Squat",
            kind: .exercise(goalType: .fixedSets, targetReps: [5], weights: [135], reps: [5]),
            phaseNumber: nil, dayLabel: "Upper A", equipmentName: nil)
        let earlyRestRow = ImportEngine.ImportedEntry(
            date: earlyRestDate, exerciseName: "Walk",
            kind: .restActivity(distance: nil, distanceUnit: "mi"),
            phaseNumber: nil, dayLabel: "Rest", equipmentName: nil)
        let lateRestRow = ImportEngine.ImportedEntry(
            date: lateRestDate, exerciseName: "Yoga",
            kind: .restActivity(distance: nil, distanceUnit: "mi"),
            phaseNumber: nil, dayLabel: "Rest", equipmentName: nil)

        _ = await ImportEngine.importIntoStore([exerciseRow, earlyRestRow, lateRestRow],
                                               context: context, attributeTo: phase)

        let sessions = (try? context.fetch(FetchDescriptor<WorkoutSession>())) ?? []
        let earlySession = sessions.first { cal.isDate($0.date, inSameDayAs: earlyRestDate) }
        let lateSession = sessions.first { cal.isDate($0.date, inSameDayAs: lateRestDate) }

        XCTAssertNil(earlySession?.phase, "A rest row before the earliest attributed exercise date shouldn't be attributed")
        XCTAssertEqual(lateSession?.phase?.number, 1, "A rest row on/after the earliest attributed exercise date should be attributed")
    }

    /// The app's own backfilled rest sessions are labeled "Rest Day"
    /// (WorkoutSession.backfillRestDays), so a user hand-filling history
    /// naturally types that instead of the bare "Rest" a built Phase's Rest
    /// PhaseDay is always actually named. parseRows must normalize either
    /// spelling to the canonical "Rest" so matchPhaseDay's exact-name
    /// comparison still finds it.
    @MainActor
    func testParseRowsNormalizesRestDayLabelToCanonicalRest() {
        let csv = "Date,Day,Exercise,Sets,Weights,Reps\n2026-01-02,Rest Day,Walk,,,3.1mi"
        let (rows, skipped) = ImportEngine.parseRows(csv: csv)
        XCTAssertEqual(skipped, 0)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.dayLabel, "Rest", "\"Rest Day\" in the Day column should normalize to \"Rest\"")
    }

    /// End-to-end reproduction of the actual bug: a file that spells every
    /// rest day "Rest Day" (as backfillRestDays and RestDayLogView both do)
    /// used to leave every one of those sessions unmatched to the Phase's
    /// "Rest" PhaseDay — so no cycle could ever complete, and currentCycle
    /// stayed stuck at 1 no matter how many cycles' worth of history came
    /// in. Three full Upper A / Rest passes should land on cycle 4.
    @MainActor
    func testCurrentCycleAdvancesAfterImportingMultipleCyclesWithRestDaySpelling() async {
        let context = makeContext()
        let phase = Phase(number: 1, totalCycles: 8)
        context.insert(phase)
        let trainDay = PhaseDay(order: 0, name: "Upper A", isRest: false)
        trainDay.phase = phase
        context.insert(trainDay)
        let restDay = PhaseDay(order: 1, name: "Rest", isRest: true)
        restDay.phase = phase
        context.insert(restDay)
        try? context.save()

        let csv = """
        Date,Day,Exercise,Sets,Weights,Reps
        2026-01-01,Upper A,Back Squat,5,135,5
        2026-01-02,Rest Day,Walk,,,3.1mi
        2026-01-03,Upper A,Back Squat,5,135,5
        2026-01-04,Rest Day,Walk,,,3.1mi
        2026-01-05,Upper A,Back Squat,5,135,5
        2026-01-06,Rest Day,Walk,,,3.1mi
        """
        let (rows, skipped) = ImportEngine.parseRows(csv: csv)
        XCTAssertEqual(skipped, 0)

        _ = await ImportEngine.importIntoStore(rows, context: context, attributeTo: phase)

        XCTAssertEqual(phase.currentCycle, 4, "Three complete Upper A/Rest passes should leave cycle 4 in progress")
    }

    /// A row tagged with any Dumbbell/Band spelling shouldn't create a
    /// plain weight+sides Bar in the Equipment tab's "Bars" section — it
    /// should route to the same special isDumbbell "Dumbbells"/"Bands"
    /// table EquipmentView's own "Add" buttons write to.
    @MainActor
    func testDumbbellAndBandEquipmentRouteToTheirSpecialTablesNotAPlainBar() async {
        let context = makeContext()
        let rows = [
            ImportEngine.ImportedEntry(
                date: Date(), exerciseName: "Dumbbell Curl",
                kind: .exercise(goalType: .fixedSets, targetReps: [10], weights: [25], reps: [10]),
                phaseNumber: nil, dayLabel: nil, equipmentName: "Dumbbell"),
            ImportEngine.ImportedEntry(
                date: Date(), exerciseName: "Goblet Squat",
                kind: .exercise(goalType: .fixedSets, targetReps: [10], weights: [30], reps: [10]),
                phaseNumber: nil, dayLabel: nil, equipmentName: "Dumbell"),   // common misspelling
            ImportEngine.ImportedEntry(
                date: Date(), exerciseName: "Band Pull-Apart",
                kind: .exercise(goalType: .fixedSets, targetReps: [20], weights: [10], reps: [20]),
                phaseNumber: nil, dayLabel: nil, equipmentName: "Bands"),
        ]
        _ = await ImportEngine.importIntoStore(rows, context: context)

        let bars = (try? context.fetch(FetchDescriptor<Bar>())) ?? []
        XCTAssertEqual(bars.count, 2, "Both Dumbbell spellings should share one \"Dumbbells\" table, plus one \"Bands\" table — never a plain Bar")

        let dumbbellsBar = bars.first { $0.name == "Dumbbells" }
        XCTAssertNotNil(dumbbellsBar)
        XCTAssertEqual(dumbbellsBar?.isDumbbell, true)

        let bandsBar = bars.first { $0.name == "Bands" }
        XCTAssertNotNil(bandsBar)
        XCTAssertEqual(bandsBar?.isDumbbell, true)

        let defs = (try? context.fetch(FetchDescriptor<ExerciseDef>())) ?? []
        XCTAssertEqual(defs.first { $0.name == "Dumbbell Curl" }?.equipment?.name, "Dumbbells")
        XCTAssertEqual(defs.first { $0.name == "Goblet Squat" }?.equipment?.name, "Dumbbells")
        XCTAssertEqual(defs.first { $0.name == "Band Pull-Apart" }?.equipment?.name, "Bands")
    }

    /// A split with TWO Rest days a cycle (e.g. Lower1/Upper1/Rest/Lower2/
    /// Upper2/Rest — a legitimate, PhaseBuilderView-supported template with
    /// two separate PhaseDay objects both named "Rest") used to never
    /// complete a single cycle via import: matchPhaseDay resolved "Rest" by
    /// name with Swift's `first`, so every Rest row kept re-filling the
    /// SAME PhaseDay — the second one could never be reached. Reproduces
    /// the actual dates/pattern from a real user import (including a
    /// genuine gap on 7/26, no session of any kind that day) to confirm the
    /// fix correctly advances through multiple cycles instead of staying
    /// stuck at cycle 1.
    @MainActor
    func testTwoIdenticallyNamedRestSlotsBothFillAcrossMultipleCycles() async {
        let context = makeContext()
        let phase = Phase(number: 1, totalCycles: 8)
        context.insert(phase)
        let names = ["Lower Day 1", "Upper Day 1", "Rest", "Lower Day 2", "Upper Day 2", "Rest"]
        for (i, name) in names.enumerated() {
            let day = PhaseDay(order: i, name: name, isRest: name == "Rest")
            day.phase = phase
            context.insert(day)
        }
        try? context.save()
        XCTAssertEqual(phase.orderedDays.filter { $0.name == "Rest" }.count, 2)

        func exerciseRow(_ dateStr: String, _ label: String) -> ImportEngine.ImportedEntry {
            ImportEngine.ImportedEntry(
                date: ISO8601DateFormatter().date(from: "\(dateStr)T00:00:00Z")!,
                exerciseName: "Some Exercise",
                kind: .exercise(goalType: .fixedSets, targetReps: [5], weights: [100], reps: [5]),
                phaseNumber: 1, dayLabel: label, equipmentName: nil)
        }
        func restRow(_ dateStr: String) -> ImportEngine.ImportedEntry {
            ImportEngine.ImportedEntry(
                date: ISO8601DateFormatter().date(from: "\(dateStr)T00:00:00Z")!,
                exerciseName: "Walk", kind: .restActivity(distance: nil, distanceUnit: "mi"),
                phaseNumber: 1, dayLabel: "Rest", equipmentName: nil)
        }

        // Matches WorkoutImport16.xlsx exactly: 3 clean passes, then a
        // fourth that skips 7/26 entirely before resuming.
        let rows = [
            exerciseRow("2026-07-06", "Lower Day 1"), exerciseRow("2026-07-08", "Upper Day 1"),
            restRow("2026-07-09"),
            exerciseRow("2026-07-12", "Lower Day 2"), exerciseRow("2026-07-13", "Upper Day 2"),
            restRow("2026-07-14"),
            exerciseRow("2026-07-15", "Lower Day 1"), exerciseRow("2026-07-16", "Upper Day 1"),
            restRow("2026-07-17"),
            exerciseRow("2026-07-18", "Lower Day 2"), exerciseRow("2026-07-19", "Upper Day 2"),
            restRow("2026-07-20"),
            exerciseRow("2026-07-21", "Lower Day 1"), exerciseRow("2026-07-22", "Upper Day 1"),
            restRow("2026-07-23"),
            exerciseRow("2026-07-24", "Lower Day 2"), exerciseRow("2026-07-25", "Upper Day 2"),
            // 7/26 skipped entirely
            exerciseRow("2026-07-27", "Lower Day 1"), exerciseRow("2026-07-28", "Upper Day 1"),
            restRow("2026-07-29"),
            exerciseRow("2026-07-30", "Lower Day 2"), exerciseRow("2026-07-31", "Upper Day 2"),
            restRow("2026-08-01"),
        ]

        _ = await ImportEngine.importIntoStore(rows, context: context, attributeTo: phase)

        XCTAssertGreaterThan(phase.currentCycle, 1,
            "Both Rest slots should be reachable, so at least one cycle should complete instead of staying stuck at 1")
        XCTAssertEqual(phase.currentCycle, 4,
            "3 clean passes complete outright; the skipped 7/26 delays the 3rd cycle's 2nd Rest slot until 7/29, absorbing 7/27-28 as bonus sessions and leaving cycle 4 with only Lower Day 2/Upper Day 2/Rest logged so far")
    }
}
