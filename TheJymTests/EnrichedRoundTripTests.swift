//
//  EnrichedRoundTripTests.swift
//  TheJymTests
//
//  Store -> export -> import -> store, asserting what survives.
//
//  The fixture is shaped like Jimmy's restored store rather than like a
//  convenient minimum: two phases with six-day splits, planned exercises
//  including a per-cycle override, attributed and unattributed sessions,
//  a bodyweight set with a frozen bodyweightAtLog, a walk, a weigh-in, a
//  rest-day credit, and a session carrying a duration. Those are exactly
//  the things the three-sheet export silently dropped and that the Oct
//  2026 recovery therefore couldn't get back.
//

import XCTest
import SwiftData
@testable import TheJym

@MainActor
final class EnrichedRoundTripTests: XCTestCase {
    private let cal = Calendar.current
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func makeContext() -> ModelContext {
        let container = try! ModelContainer(
            for: AppSettings.self, Bar.self, ExerciseDef.self, Phase.self, PhaseDay.self,
            PlannedExercise.self, WorkoutSession.self, ExerciseLog.self, SetLog.self,
            BodyWeightEntry.self, RestDayActivity.self, ActiveRecovery.self,
            TrainingDaysPerWeekChange.self, TimerTemplate.self, TimerPreset.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    // MARK: - A store shaped like the real one

    private func buildSourceStore(_ ctx: ModelContext) {
        let settings = AppSettings()
        settings.trainingStartDate = day(2026, 7, 6)
        settings.trainingDaysPerWeek = 4
        settings.weightReminderHour = 9
        ctx.insert(settings)

        for (number, active) in [(1, false), (2, true)] {
            let phase = Phase(number: number, totalCycles: 8, startDate: day(2026, 7, 6))
            phase.isActive = active
            ctx.insert(phase)
            for (order, name) in ["Lower Day 1", "Upper Day 1", "Rest",
                                  "Lower Day 2", "Upper Day 2", "Rest"].enumerated() {
                let d = PhaseDay(order: order, name: name, isRest: name == "Rest")
                d.phase = phase
                ctx.insert(d)
                guard !d.isRest else { continue }
                let pe = PlannedExercise(order: 0, exerciseName: "Bench Press",
                                         targetReps: [5, 5, 5], suggestedWeights: [135, 135, 135],
                                         restTimeSeconds: 180)
                pe.day = d
                ctx.insert(pe)
                if name == "Upper Day 1" {
                    // A per-cycle override — distinct from its base slot
                    // by cycleOverride, which is the thing most likely to
                    // be flattened by a careless round trip.
                    let override = PlannedExercise(order: 0, exerciseName: "Incline Press",
                                                   targetReps: [8, 8], cycleOverride: 3)
                    override.day = d
                    ctx.insert(override)
                }
            }
        }
        let phase2 = (try! ctx.fetch(FetchDescriptor<Phase>())).first { $0.number == 2 }!
        let upper = phase2.days.first { $0.name == "Upper Day 1" }!

        // An ATTRIBUTED session with duration, deload and a bodyweight set.
        let attributed = WorkoutSession(date: day(2026, 9, 1), day: upper,
                                        dayLabel: "Upper Day 1", cycleNumber: 3,
                                        isDeload: true, isBonusSession: false)
        attributed.phase = phase2
        attributed.durationSeconds = 3720
        ctx.insert(attributed)
        let bwLog = ExerciseLog(exerciseName: "Pull-Up", targetReps: [8], order: 0, isBodyweight: true)
        bwLog.session = attributed
        ctx.insert(bwLog)
        for i in 0..<2 {
            // weight = bodyweight + added, frozen at log time.
            let set = SetLog(index: i, weight: 196.5, reps: 8, addedWeight: 15, bodyweightAtLog: 181.5)
            set.exerciseLog = bwLog
            ctx.insert(set)
        }

        // An UNATTRIBUTED session, as the old CSV bulk produced.
        let loose = WorkoutSession(date: day(2026, 9, 2), dayLabel: "Imported", cycleNumber: 0)
        ctx.insert(loose)
        let log = ExerciseLog(exerciseName: "Back Squat", targetReps: [5], order: 0)
        log.session = loose
        ctx.insert(log)
        let set = SetLog(index: 0, weight: 225, reps: 5)
        set.exerciseLog = log
        ctx.insert(set)

        // A walk.
        let activity = RestDayActivity(date: day(2026, 9, 3), name: "Walk", distance: 3.1)
        ctx.insert(activity)
        let walkSession = WorkoutSession(date: day(2026, 9, 3), dayLabel: "Rest", cycleNumber: 0)
        ctx.insert(walkSession)
        let walkLog = ExerciseLog(exerciseName: "Walk", targetReps: [], order: 0)
        walkLog.session = walkSession
        walkLog.restDayActivity = activity
        ctx.insert(walkLog)
        let walkSet = SetLog(index: 0, weight: 3.1, reps: 1)
        walkSet.exerciseLog = walkLog
        ctx.insert(walkSet)

        ctx.insert(BodyWeightEntry(date: day(2026, 9, 4), weight: 181.5))
        ctx.insert(ActiveRecovery(date: day(2026, 9, 5), type: .rest))
        ctx.insert(TrainingDaysPerWeekChange(date: day(2026, 8, 1), trainingDaysPerWeek: 5))
        ctx.insert(ExerciseDef(name: "Bench Press", repSchemes: [[5, 5, 5]]))
        ctx.insert(Bar(name: "Barbell", weight: 45))
        try? ctx.save()
    }

    /// Mirrors SettingsView's sheet builders. Kept here rather than
    /// reaching into the View so the test exercises the same SHAPES the
    /// export writes without needing to stand up SwiftUI.
    private func exportWorkbook(_ ctx: ModelContext) -> Data {
        let sessions = (try! ctx.fetch(FetchDescriptor<WorkoutSession>())).sorted { $0.date < $1.date }
        let bodyWeights = try! ctx.fetch(FetchDescriptor<BodyWeightEntry>())
        let phases = (try! ctx.fetch(FetchDescriptor<Phase>())).sorted { $0.number < $1.number }
        let recoveries = try! ctx.fetch(FetchDescriptor<ActiveRecovery>())
        let changes = try! ctx.fetch(FetchDescriptor<TrainingDaysPerWeekChange>())
        let settings = (try! ctx.fetch(FetchDescriptor<AppSettings>())).first!

        var history: [[XLSXCell]] = [[.string("Date"), .string("Exercise"), .string("Sets"),
                                      .string("Weights"), .string("Reps"), .string("Phase"),
                                      .string("Day"), .string("Cycle"), .string("Duration"),
                                      .string("Deload"), .string("Bonus"),
                                      .string("AddedWeight"), .string("BodyweightAtLog")]]
        for session in sessions {
            for log in session.exerciseLogs.sorted(by: { $0.order < $1.order }) {
                let sets = log.sortedSets
                guard !sets.isEmpty else { continue }
                let added = sets.map { $0.addedWeight.map(Formatters.trim) ?? "" }.joined(separator: "/")
                let bwAt = sets.map { $0.bodyweightAtLog.map(Formatters.trim) ?? "" }.joined(separator: "/")
                history.append([
                    .string(Formatters.exportDate.string(from: session.date)),
                    .string(log.exerciseName), .string(log.setsSummaryText),
                    .string(sets.map { Formatters.trim($0.weight) }.joined(separator: "/")),
                    .string(sets.map { String($0.reps) }.joined(separator: "/")),
                    session.phase.map { .number(Double($0.number)) } ?? .blank,
                    .string(session.dayLabel),
                    session.cycleNumber > 0 ? .number(Double(session.cycleNumber)) : .blank,
                    session.durationSeconds.map { .number(Double($0)) } ?? .blank,
                    session.isDeload ? .string("Yes") : .blank,
                    session.isBonusSession ? .string("Yes") : .blank,
                    added.replacingOccurrences(of: "/", with: "").isEmpty ? .blank : .string(added),
                    bwAt.replacingOccurrences(of: "/", with: "").isEmpty ? .blank : .string(bwAt),
                ])
            }
        }
        for entry in bodyWeights {
            history.append([.string(Formatters.exportDate.string(from: entry.date)),
                            .string("Body Weight"), .blank, .number(entry.weight), .blank])
        }

        var program: [[XLSXCell]] = [[.string("Type"), .string("A"), .string("B"), .string("C"),
                                      .string("D"), .string("E"), .string("F"), .string("G"),
                                      .string("H"), .string("I"), .string("J"), .string("K"), .string("L")]]
        for phase in phases {
            program.append([.string("Phase"), .number(Double(phase.number)),
                            .number(Double(phase.totalCycles)),
                            .string(Formatters.exportDate.string(from: phase.startDate)),
                            .string(phase.isActive ? "Yes" : "No"),
                            .number(Double(phase.deloadCycle)),
                            .string(phase.manualDeloadCycles.map(String.init).joined(separator: ",")),
                            phase.legacyCompletedCycles.map { .number(Double($0)) } ?? .blank])
            for d in phase.orderedDays {
                program.append([.string("PhaseDay"), .number(Double(phase.number)),
                                .number(Double(d.order)), .string(d.name),
                                .string(d.isRest ? "Yes" : "No")])
                for pe in d.plannedExercises.sorted(by: { $0.order < $1.order }) {
                    program.append([.string("PlannedExercise"), .number(Double(phase.number)),
                                    .string(d.name), .number(Double(pe.order)),
                                    .string(pe.exerciseName),
                                    .string(pe.targetReps.map(String.init).joined(separator: "/")),
                                    .string(pe.suggestedWeights.map { Formatters.trim($0) }.joined(separator: "/")),
                                    .string(pe.isBodyweight ? "Yes" : "No"),
                                    .number(Double(pe.goalKindRaw)),
                                    .number(Double(pe.repTotalTarget)),
                                    pe.restTimeSeconds.map { .number(Double($0)) } ?? .blank,
                                    .number(Double(pe.cycleOverride)),
                                    .number(Double(d.order))])
                }
            }
        }
        for r in recoveries {
            program.append([.string("ActiveRecovery"),
                            .string(Formatters.exportDate.string(from: r.date)),
                            .number(Double(r.typeRaw))])
        }
        for c in changes {
            program.append([.string("TrainingDaysPerWeek"),
                            .string(Formatters.exportDate.string(from: c.date)),
                            .number(Double(c.trainingDaysPerWeek))])
        }
        program.append([.string("Setting"), .string("trainingStartDate"),
                        .string(Formatters.exportDate.string(from: settings.trainingStartDate))])
        program.append([.string("Setting"), .string("trainingDaysPerWeek"),
                        .number(Double(settings.trainingDaysPerWeek))])
        program.append([.string("Setting"), .string("weightReminderHour"),
                        .number(Double(settings.weightReminderHour))])

        return XLSXWriter.makeWorkbook(sheets: [
            ("History", history),
            ("Exercises", [[.string("Exercise"), .string("Equipment"), .string("Bodyweight"),
                            .string("Sets"), .string("Notes")],
                           [.string("Bench Press"), .string("Barbell"), .string("No"),
                            .string("5/5/5"), .string("")]]),
            ("Equipment", [[.string("Name"), .string("Type"), .string("Weight"),
                            .string("Sides"), .string("Dumbbell/Band Weights")],
                           [.string("Barbell"), .string("Barbell"), .number(45),
                            .number(2), .string("")]]),
            ("Program", program),
        ])
    }

    // MARK: - The round trip

    func testStoreSurvivesExportAndReimport() async {
        let source = makeContext()
        buildSourceStore(source)
        let data = exportWorkbook(source)

        let target = makeContext()
        target.insert(AppSettings())
        try? target.save()

        guard let wb = ImportEngine.parseWorkbook(xlsxData: data, restActivityNames: ["walk"]) else {
            return XCTFail("workbook didn't parse")
        }
        XCTAssertEqual(wb.skipped.total, 0, "nothing dropped: \(wb.skipped.breakdown)")
        XCTAssertFalse(wb.program.isEmpty, "the Program sheet must be found")

        ImportEngine.restoreProgram(wb.program, context: target)
        ImportEngine.restoreLibraryAndEquipment(wb, context: target)
        _ = await ImportEngine.importIntoStore(wb.historyRows, context: target)
        try? target.save()

        // --- the program ---
        let phases = (try! target.fetch(FetchDescriptor<Phase>())).sorted { $0.number < $1.number }
        XCTAssertEqual(phases.map(\.number), [1, 2], "both phases")
        XCTAssertEqual(phases.map(\.totalCycles), [8, 8])
        XCTAssertEqual(phases.filter(\.isActive).map(\.number), [2], "the active one stays active")
        for phase in phases {
            XCTAssertEqual(phase.orderedDays.map(\.name),
                           ["Lower Day 1", "Upper Day 1", "Rest", "Lower Day 2", "Upper Day 2", "Rest"],
                           "phase \(phase.number)'s split, in order")
            XCTAssertEqual(phase.orderedDays.filter(\.isRest).count, 2)
        }
        let planned = try! target.fetch(FetchDescriptor<PlannedExercise>())
        XCTAssertEqual(planned.count, 10, "8 base slots + 2 per-cycle overrides")
        XCTAssertEqual(planned.filter { $0.cycleOverride == 3 }.count, 2,
                       "a per-cycle override must not be flattened into its base slot")
        let base = planned.first { $0.cycleOverride == 0 && $0.exerciseName == "Bench Press" }
        XCTAssertEqual(base?.targetReps, [5, 5, 5])
        XCTAssertEqual(base?.suggestedWeights, [135, 135, 135])
        XCTAssertEqual(base?.restTimeSeconds, 180)

        // --- session attribution ---
        let sessions = try! target.fetch(FetchDescriptor<WorkoutSession>())
        let attributed = sessions.first { cal.isDate($0.date, inSameDayAs: day(2026, 9, 1)) }
        XCTAssertEqual(attributed?.phase?.number, 2, "Phase column reattached the session")
        XCTAssertEqual(attributed?.day?.name, "Upper Day 1", "Day column reattached the slot")
        XCTAssertEqual(attributed?.cycleNumber, 3, "Cycle column survived")
        XCTAssertEqual(attributed?.durationSeconds, 3720, "duration survived")
        XCTAssertTrue(attributed?.isDeload == true, "isDeload survived")

        // --- the bodyweight set, frozen not re-resolved ---
        let bwSets = (try! target.fetch(FetchDescriptor<SetLog>()))
            .filter { $0.bodyweightAtLog != nil }
        XCTAssertEqual(bwSets.count, 2)
        XCTAssertEqual(bwSets.first?.bodyweightAtLog, 181.5, "the FROZEN value, not a re-resolution")
        XCTAssertEqual(bwSets.first?.addedWeight, 15)
        XCTAssertEqual(bwSets.first?.weight, 196.5)

        // --- walks stay walks, weigh-ins stay weigh-ins ---
        let activities = try! target.fetch(FetchDescriptor<RestDayActivity>())
        XCTAssertEqual(activities.count, 1, "the walk is a RestDayActivity, not a lift")
        XCTAssertEqual(activities.first?.distance, 3.1)
        let weighIns = try! target.fetch(FetchDescriptor<BodyWeightEntry>())
        XCTAssertEqual(weighIns.count, 1, "the weigh-in is a BodyWeightEntry, not an exercise")
        XCTAssertEqual(weighIns.first?.weight, 181.5)
        XCTAssertFalse((try! target.fetch(FetchDescriptor<ExerciseLog>()))
            .contains { ImportEngine.isBodyWeightLabel($0.exerciseName) },
            "no weigh-in may come back as an exercise log")

        // --- the rest ---
        XCTAssertEqual((try! target.fetch(FetchDescriptor<ActiveRecovery>())).count, 1,
                       "rest-day credits survive — the rest bank's input")
        XCTAssertEqual((try! target.fetch(FetchDescriptor<TrainingDaysPerWeekChange>())).count, 1)
        let restored = (try! target.fetch(FetchDescriptor<AppSettings>())).first
        XCTAssertEqual(restored.map { cal.startOfDay(for: $0.trainingStartDate) },
                       day(2026, 7, 6), "trainingStartDate survived")
        XCTAssertEqual(restored?.trainingDaysPerWeek, 4)
        XCTAssertEqual(restored?.weightReminderHour, 9)
    }

    /// Every pre-existing export lacks a Program sheet, including the one
    /// used for the Oct 2026 recovery. That must stay a normal import.
    func testFileWithNoProgramSheetStillImports() async {
        let data = XLSXWriter.makeWorkbook(sheets: [("History", [
            [.string("Date"), .string("Exercise"), .string("Sets"), .string("Weights"), .string("Reps")],
            [.string("2026-09-15"), .string("Bench Press"), .string("5/5"), .string("135/135"), .string("5/5")],
            [.string("2026-09-15"), .string("Body Weight"), .blank, .number(181.4), .blank],
        ])])
        guard let wb = ImportEngine.parseWorkbook(xlsxData: data) else {
            return XCTFail("workbook didn't parse")
        }
        XCTAssertTrue(wb.program.isEmpty, "no Program sheet is normal, not an error")
        XCTAssertEqual(wb.skipped.total, 0)

        let target = makeContext()
        ImportEngine.restoreProgram(wb.program, context: target)   // must be a no-op
        XCTAssertEqual((try! target.fetch(FetchDescriptor<Phase>())).count, 0)
        let outcome = await ImportEngine.importIntoStore(wb.historyRows, context: target)
        XCTAssertEqual(outcome.bodyWeightEntriesCreated, 1)
        XCTAssertEqual((try! target.fetch(FetchDescriptor<SetLog>())).count, 2)
    }

    /// An unknown Type row must be skipped, not abort the sheet, so a
    /// newer file still imports on an older build.
    func testUnknownProgramRowTypeIsIgnored() {
        let grid = [["Type", "A", "B"],
                    ["Phase", "1", "8"],
                    ["SomethingNew", "x", "y"],
                    ["Setting", "trainingDaysPerWeek", "4"]]
        let p = ImportEngine.parseProgramSheet(grid)
        XCTAssertEqual(p.settings["trainingDaysPerWeek"], "4",
                       "rows after an unknown type must still parse")
        XCTAssertTrue(p.phases.isEmpty, "the Phase row has no date, so it's skipped on its own merits")
    }
}
