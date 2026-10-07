//
//  FullRoundTripDiffTests.swift
//  TheJymTests
//
//  The definitive export test: build a store that exercises EVERY stored
//  field on every model, round-trip it through the real writer, reader and
//  importer, then diff field by field and REPORT what differs.
//
//  Deliberately a diff rather than a pass/fail on "everything survives".
//  The claim worth having is a measured list of what does NOT round-trip,
//  because that list is the restore floor — and three times now a field
//  was assumed carried when it wasn't (bodyweightAtLog, isBigLift,
//  distanceUnit).
//

import XCTest
import SwiftData
@testable import TheJym

@MainActor
final class FullRoundTripDiffTests: XCTestCase {
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
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(c)
    }

    /// Every stored field set to a DISTINCTIVE non-default value, so a
    /// field that silently falls back to its default is visible as a
    /// difference rather than coincidentally matching.
    private func buildSource(_ ctx: ModelContext) {
        let settings = AppSettings()
        settings.trainingStartDate = d(2026, 7, 6)
        settings.trainingDaysPerWeek = 5
        settings.weightReminderHour = 9
        settings.streakReminderHour = 20
        settings.customWeightIncreaseEnabled = true
        settings.customWeightIncreaseStreak = 3
        settings.customWeightIncreaseAmount = 2.5
        settings.availablePlateSizes = [45, 25, 10, 5, 2.5]
        settings.hasDumbbell125Attachment = true
        // Both flipped AWAY from their defaults (true / false) on purpose —
        // they round-tripped before only because the live values happened
        // to match, so a fixture using the defaults proves nothing.
        settings.aiAssistantEnabled = false
        settings.useGeminiForPhasePlanning = true
        ctx.insert(settings)

        let bar = Bar(name: "Trap Bar", weight: 60, isDumbbell: false, loadableSides: 2)
        ctx.insert(bar)
        let dumbbells = Bar(name: "Dumbbells", weight: 0, isDumbbell: true,
                            dumbbellWeights: [10, 20, 30, 40])
        ctx.insert(dumbbells)

        let def = ExerciseDef(name: "Bench Press", repSchemes: [[5, 5, 5], [8, 8]])
        def.notes = "Pause on chest"
        def.additionalNotes = "Elbows 45 degrees"
        def.isBigLift = true
        def.isBodyweight = false
        def.equipment = bar
        def.dateAdded = d(2026, 1, 15)
        def.repSchemeCeilings = [RepSchemeCeiling(reps: [5, 5, 5], upperTargetReps: [8, 8, 8],
                                                  weightIncreaseAmount: 5)]
        def.repTotalTargets = [100]
        ctx.insert(def)

        let pullUp = ExerciseDef(name: "Pull-Up", repSchemes: [[8]])
        pullUp.isBodyweight = true
        ctx.insert(pullUp)

        let phase = Phase(number: 2, totalCycles: 8, startDate: d(2026, 8, 27))
        phase.isActive = true
        phase.deloadCycle = 4
        phase.manualDeloadCycles = [6]
        ctx.insert(phase)
        // TWO days called "Rest" — the collision that sent every rest
        // session to the first of them, and that collapsed every split
        // 6 -> 5 in the program restore. Both must survive distinctly.
        for (order, name) in ["Lower Day 1", "Upper Day 1", "Rest", "Rest"].enumerated() {
            let day = PhaseDay(order: order, name: name, isRest: name == "Rest")
            day.phase = phase
            ctx.insert(day)
            guard !day.isRest else { continue }
            let pe = PlannedExercise(order: 0, exerciseName: "Bench Press",
                                     targetReps: [5, 5, 5], suggestedWeights: [135, 140, 145],
                                     isBodyweight: false, goalType: .fixedSets,
                                     restTimeSeconds: 180)
            pe.repTotalProgressesReps = true
            pe.day = day
            ctx.insert(pe)
        }
        let upper = phase.orderedDays.first { $0.name == "Upper Day 1" }!

        // A per-cycle override. Its `overriddenSlotID` is a UUID, which
        // can't survive a restore — but (day, order, cycleOverride) is pure
        // data and identifies it exactly, so the link is rebuildable.
        // Checked below by comparing plan(for:cycle:), not just fields: a
        // link rebuilt to the wrong base slot would still read as equal.
        let baseSlot = upper.plannedExercises.first { $0.cycleOverride == 0 }!
        upper.setCycleOverride(for: baseSlot, cycle: 4, exerciseName: "Close-Grip Bench",
                               targetReps: [6, 4, 4], goalType: .fixedSets,
                               isBodyweight: false, restTimeSeconds: 240, context: ctx)

        let session = WorkoutSession(date: d(2026, 9, 1), day: upper, dayLabel: "Upper Day 1",
                                     cycleNumber: 3, isDeload: true, isBonusSession: true)
        session.phase = phase
        session.durationSeconds = 3720
        ctx.insert(session)
        let log = ExerciseLog(exerciseName: "Bench Press", targetReps: [5, 5, 5], order: 0)
        log.session = session
        log.achievedRank = 2
        log.missedTarget = true
        log.selectedWeightAdjustment = -5
        ctx.insert(log)
        for i in 0..<3 {
            let set = SetLog(index: i, weight: 185, reps: 5)
            set.exerciseLog = log
            ctx.insert(set)
        }
        let bwLog = ExerciseLog(exerciseName: "Pull-Up", targetReps: [8], order: 1, isBodyweight: true)
        bwLog.session = session
        ctx.insert(bwLog)
        let bwSet = SetLog(index: 0, weight: 196.5, reps: 8, addedWeight: 15, bodyweightAtLog: 181.5)
        bwSet.exerciseLog = bwLog
        ctx.insert(bwSet)

        // A walk in KILOMETRES — the unit that used to be assumed "mi".
        let activity = RestDayActivity(date: d(2026, 9, 2), name: "Walk",
                                       distance: 5.0, distanceUnit: "km")
        ctx.insert(activity)
        let walkSession = WorkoutSession(date: d(2026, 9, 2), dayLabel: "Rest", cycleNumber: 0)
        ctx.insert(walkSession)
        let walkLog = ExerciseLog(exerciseName: "Walk", targetReps: [], order: 0)
        walkLog.session = walkSession
        walkLog.restDayActivity = activity
        ctx.insert(walkLog)
        let walkSet = SetLog(index: 0, weight: 5.0, reps: 1)
        walkSet.exerciseLog = walkLog
        ctx.insert(walkSet)

        // A walk with NO distance recorded, on the SECOND Rest day. Both
        // halves used to break: the distance came back as 0 (the mirror
        // SetLog stores `distance ?? 0`, and reading that back can't tell
        // "none" from "zero"), and the session landed on Rest slot 2
        // because the Day column carried only the name.
        let restSlot2 = phase.orderedDays.last { $0.isRest }!
        let noDistance = RestDayActivity(date: d(2026, 9, 5), name: "Walk", distance: nil)
        ctx.insert(noDistance)
        let session2 = WorkoutSession(date: d(2026, 9, 5), day: restSlot2, dayLabel: "Rest",
                                      cycleNumber: 3)
        session2.phase = phase
        ctx.insert(session2)
        let log2 = ExerciseLog(exerciseName: "Walk", targetReps: [], order: 0)
        log2.session = session2
        log2.restDayActivity = noDistance
        ctx.insert(log2)
        let set2 = SetLog(index: 0, weight: 0, reps: 1)
        set2.exerciseLog = log2
        ctx.insert(set2)

        ctx.insert(BodyWeightEntry(date: d(2026, 9, 3), weight: 181.5))
        ctx.insert(ActiveRecovery(date: d(2026, 9, 4), type: .mobility))
        ctx.insert(TrainingDaysPerWeekChange(date: d(2026, 8, 1), trainingDaysPerWeek: 5))

        let template = TimerTemplate(name: "HIIT Sprints", order: 0, continuous: true)
        ctx.insert(template)
        for (i, spec) in [("Work", 30.0, false), ("Rest", 90.0, true)].enumerated() {
            let preset = TimerPreset(name: spec.0, seconds: spec.1, repeatCount: 4,
                                     order: i, isRest: spec.2)
            preset.template = template
            ctx.insert(preset)
        }
        try? ctx.save()
    }

    // MARK: - The diff

    func testFullRoundTripDiff() async {
        let source = makeContext()
        buildSource(source)

        let data = ExportBuilder.workbook(from: source)
        let target = makeContext()
        target.insert(AppSettings())
        try? target.save()

        guard let wb = ImportEngine.parseWorkbook(xlsxData: data, restActivityNames: ["walk"]) else {
            return XCTFail("workbook didn't parse")
        }
        ImportEngine.restoreProgram(wb.program, context: target)
        ImportEngine.restoreLibraryAndEquipment(wb, context: target)
        _ = await ImportEngine.importIntoStore(wb.historyRows, context: target)
        try? target.save()

        var diffs: [String] = []
        func check(_ field: String, _ before: String, _ after: String) {
            if before != after { diffs.append("\(field): \(before) -> \(after)") }
        }

        // --- ExerciseDef
        let sDef = (try! source.fetch(FetchDescriptor<ExerciseDef>())).first { $0.name == "Bench Press" }!
        let tDef = (try! target.fetch(FetchDescriptor<ExerciseDef>())).first { $0.name == "Bench Press" }
        check("ExerciseDef.isBigLift", "\(sDef.isBigLift)", "\(tDef?.isBigLift ?? false)")
        check("ExerciseDef.notes", sDef.notes, tDef?.notes ?? "")
        check("ExerciseDef.additionalNotes", sDef.additionalNotes, tDef?.additionalNotes ?? "")
        check("ExerciseDef.repSchemes", "\(sDef.repSchemes)", "\(tDef?.repSchemes ?? [])")
        check("ExerciseDef.repSchemeCeilings", "\(sDef.repSchemeCeilings)", "\(tDef?.repSchemeCeilings ?? [])")
        check("ExerciseDef.repTotalTargets", "\(sDef.repTotalTargets)", "\(tDef?.repTotalTargets ?? [])")
        check("ExerciseDef.equipment", sDef.equipment?.name ?? "", tDef?.equipment?.name ?? "")
        check("ExerciseDef.dateAdded",
              Formatters.exportDate.string(from: sDef.dateAdded),
              tDef.map { Formatters.exportDate.string(from: $0.dateAdded) } ?? "")

        // --- Bar
        let sBar = (try! source.fetch(FetchDescriptor<Bar>())).first { $0.name == "Trap Bar" }!
        let tBar = (try! target.fetch(FetchDescriptor<Bar>())).first { $0.name == "Trap Bar" }
        check("Bar.weight", "\(sBar.weight)", "\(tBar?.weight ?? -1)")
        check("Bar.loadableSides", "\(sBar.loadableSides)", "\(tBar?.loadableSides ?? -1)")
        let sDB = (try! source.fetch(FetchDescriptor<Bar>())).first { $0.isDumbbell }!
        let tDB = (try! target.fetch(FetchDescriptor<Bar>())).first { $0.isDumbbell }
        check("Bar.dumbbellWeights", "\(sDB.dumbbellWeights)", "\(tDB?.dumbbellWeights ?? [])")

        // --- Phase / PhaseDay / PlannedExercise
        let sPhase = (try! source.fetch(FetchDescriptor<Phase>())).first!
        let tPhase = (try! target.fetch(FetchDescriptor<Phase>())).first
        check("Phase.number", "\(sPhase.number)", "\(tPhase?.number ?? -1)")
        check("Phase.totalCycles", "\(sPhase.totalCycles)", "\(tPhase?.totalCycles ?? -1)")
        check("Phase.isActive", "\(sPhase.isActive)", "\(tPhase?.isActive ?? false)")
        check("Phase.deloadCycle", "\(sPhase.deloadCycle)", "\(tPhase?.deloadCycle ?? -1)")
        check("Phase.manualDeloadCycles", "\(sPhase.manualDeloadCycles)", "\(tPhase?.manualDeloadCycles ?? [])")
        check("PhaseDay names", "\(sPhase.orderedDays.map(\.name))", "\(tPhase?.orderedDays.map(\.name) ?? [])")

        // The per-cycle override, compared as the PLAN the app trains —
        // the thing an override exists to change, and the only check that
        // catches a link rebuilt onto the wrong base slot.
        for day in sPhase.orderedDays {
            guard let tDay = tPhase?.orderedDays.first(where: { $0.order == day.order }) else {
                check("PhaseDay \(day.order)", day.name, "<absent>")
                continue
            }
            for cycle in 1...sPhase.totalCycles {
                check("plan(day \(day.order), cycle \(cycle))",
                      sPhase.plan(for: day, cycle: cycle)
                        .map { "\($0.exerciseName)\($0.targetReps)" }.joined(separator: "|"),
                      tPhase!.plan(for: tDay, cycle: cycle)
                        .map { "\($0.exerciseName)\($0.targetReps)" }.joined(separator: "|"))
            }
        }
        // Keyed by (day, order, cycleOverride) and sorted — `plannedExercises`
        // is an unordered relationship, so comparing it positionally
        // compared two different orderings of the same rows.
        func progressFlags(_ phase: Phase?) -> String {
            (phase?.orderedDays ?? []).flatMap { day in
                day.plannedExercises.map {
                    (day.order, $0.order, $0.cycleOverride, $0.repTotalProgressesReps)
                }
            }
            .sorted { ($0.0, $0.1, $0.2) < ($1.0, $1.1, $1.2) }
            .map { "\($0.0)/\($0.1)/\($0.2)=\($0.3)" }
            .joined(separator: " ")
        }
        check("PlannedExercise.repTotalProgressesReps",
              progressFlags(sPhase), progressFlags(tPhase))

        // The no-distance walk on the SECOND Rest slot.
        let sNoDist = (try! source.fetch(FetchDescriptor<RestDayActivity>()))
            .first { $0.distance == nil }
        let tNoDist = (try! target.fetch(FetchDescriptor<RestDayActivity>()))
            .first { cal.isDate($0.date, inSameDayAs: self.d(2026, 9, 5)) }
        check("RestDayActivity.distance (none recorded)",
              "\(sNoDist?.distance == nil)", "\(tNoDist?.distance == nil)")
        let sRest2 = (try! source.fetch(FetchDescriptor<WorkoutSession>()))
            .first { cal.isDate($0.date, inSameDayAs: self.d(2026, 9, 5)) }
        let tRest2 = (try! target.fetch(FetchDescriptor<WorkoutSession>()))
            .first { cal.isDate($0.date, inSameDayAs: self.d(2026, 9, 5)) }
        check("rest session's PhaseDay order",
              "\(sRest2?.day?.order ?? -1)", "\(tRest2?.day?.order ?? -1)")
        check("rest session's phase",
              "\(sRest2?.phase?.number ?? -1)", "\(tRest2?.phase?.number ?? -1)")
        check("rest session's cycleNumber",
              "\(sRest2?.cycleNumber ?? -1)", "\(tRest2?.cycleNumber ?? -1)")

        // The two fields that matched only because they equal their defaults.
        let sAI = (try! source.fetch(FetchDescriptor<AppSettings>())).first!
        let tAI = (try! target.fetch(FetchDescriptor<AppSettings>())).first
        check("AppSettings.aiAssistantEnabled",
              "\(sAI.aiAssistantEnabled)", "\(tAI?.aiAssistantEnabled ?? true)")
        check("AppSettings.useGeminiForPhasePlanning",
              "\(sAI.useGeminiForPhasePlanning)", "\(tAI?.useGeminiForPhasePlanning ?? false)")
        let sPE = sPhase.orderedDays.flatMap(\.plannedExercises).first!
        let tPE = tPhase?.orderedDays.flatMap(\.plannedExercises).first
        check("PlannedExercise.targetReps", "\(sPE.targetReps)", "\(tPE?.targetReps ?? [])")
        check("PlannedExercise.suggestedWeights", "\(sPE.suggestedWeights)", "\(tPE?.suggestedWeights ?? [])")
        check("PlannedExercise.restTimeSeconds", "\(sPE.restTimeSeconds ?? -1)", "\(tPE?.restTimeSeconds ?? -1)")

        // --- WorkoutSession
        let sSession = (try! source.fetch(FetchDescriptor<WorkoutSession>()))
            .first { $0.durationSeconds != nil }!
        let tSession = (try! target.fetch(FetchDescriptor<WorkoutSession>()))
            .first { cal.isDate($0.date, inSameDayAs: self.d(2026, 9, 1)) }
        check("WorkoutSession.durationSeconds", "\(sSession.durationSeconds ?? -1)", "\(tSession?.durationSeconds ?? -1)")
        check("WorkoutSession.isDeload", "\(sSession.isDeload)", "\(tSession?.isDeload ?? false)")
        check("WorkoutSession.isBonusSession", "\(sSession.isBonusSession)", "\(tSession?.isBonusSession ?? false)")
        check("WorkoutSession.cycleNumber", "\(sSession.cycleNumber)", "\(tSession?.cycleNumber ?? -1)")
        check("WorkoutSession.dayLabel", sSession.dayLabel, tSession?.dayLabel ?? "")
        check("WorkoutSession.phase", "\(sSession.phase?.number ?? -1)", "\(tSession?.phase?.number ?? -1)")
        check("WorkoutSession.day", sSession.day?.name ?? "", tSession?.day?.name ?? "")

        // --- ExerciseLog
        let sLog = sSession.exerciseLogs.first { $0.exerciseName == "Bench Press" }!
        let tLog = tSession?.exerciseLogs.first { $0.exerciseName == "Bench Press" }
        check("ExerciseLog.targetReps", "\(sLog.targetReps)", "\(tLog?.targetReps ?? [])")
        check("ExerciseLog.achievedRank", "\(sLog.achievedRank ?? -1)", "\(tLog?.achievedRank ?? -1)")
        check("ExerciseLog.missedTarget", "\(sLog.missedTarget)", "\(tLog?.missedTarget ?? false)")
        check("ExerciseLog.selectedWeightAdjustment",
              "\(sLog.selectedWeightAdjustment ?? 0)", "\(tLog?.selectedWeightAdjustment ?? 0)")
        let sBW = sSession.exerciseLogs.first { $0.exerciseName == "Pull-Up" }!
        let tBW = tSession?.exerciseLogs.first { $0.exerciseName == "Pull-Up" }
        check("ExerciseLog.isBodyweight", "\(sBW.isBodyweight)", "\(tBW?.isBodyweight ?? false)")
        check("SetLog.bodyweightAtLog", "\(sBW.sortedSets[0].bodyweightAtLog ?? -1)",
              "\(tBW?.sortedSets.first?.bodyweightAtLog ?? -1)")
        check("SetLog.addedWeight", "\(sBW.sortedSets[0].addedWeight ?? -1)",
              "\(tBW?.sortedSets.first?.addedWeight ?? -1)")
        check("SetLog.weight", "\(sLog.sortedSets[0].weight)", "\(tLog?.sortedSets.first?.weight ?? -1)")
        check("SetLog.reps", "\(sLog.sortedSets[0].reps)", "\(tLog?.sortedSets.first?.reps ?? -1)")

        // --- RestDayActivity (kilometres!)
        // Picked BY DATE. There are two activities now, and `.first` on an
        // unordered fetch picked a different one on each side.
        let sAct = (try! source.fetch(FetchDescriptor<RestDayActivity>()))
            .first { cal.isDate($0.date, inSameDayAs: self.d(2026, 9, 2)) }!
        let tAct = (try! target.fetch(FetchDescriptor<RestDayActivity>()))
            .first { cal.isDate($0.date, inSameDayAs: self.d(2026, 9, 2)) }
        check("RestDayActivity.distance", "\(sAct.distance ?? -1)", "\(tAct?.distance ?? -1)")
        check("RestDayActivity.distanceUnit", sAct.distanceUnit, tAct?.distanceUnit ?? "")
        check("RestDayActivity.name", sAct.name, tAct?.name ?? "")

        // --- the rest
        check("BodyWeightEntry.weight",
              "\((try! source.fetch(FetchDescriptor<BodyWeightEntry>())).first!.weight)",
              "\((try! target.fetch(FetchDescriptor<BodyWeightEntry>())).first?.weight ?? -1)")
        check("ActiveRecovery.type",
              "\((try! source.fetch(FetchDescriptor<ActiveRecovery>())).first!.typeRaw)",
              "\((try! target.fetch(FetchDescriptor<ActiveRecovery>())).first?.typeRaw ?? -1)")
        check("TrainingDaysPerWeekChange",
              "\((try! source.fetch(FetchDescriptor<TrainingDaysPerWeekChange>())).first!.trainingDaysPerWeek)",
              "\((try! target.fetch(FetchDescriptor<TrainingDaysPerWeekChange>())).first?.trainingDaysPerWeek ?? -1)")

        let sT = (try! source.fetch(FetchDescriptor<TimerTemplate>())).first!
        let tT = (try! target.fetch(FetchDescriptor<TimerTemplate>())).first
        check("TimerTemplate.name", sT.name, tT?.name ?? "")
        check("TimerTemplate.continuous", "\(sT.continuous)", "\(tT?.continuous ?? false)")
        check("TimerPreset count", "\(sT.presets.count)", "\(tT?.presets.count ?? 0)")
        check("TimerPreset.seconds", "\(sT.orderedPresets.first?.seconds ?? -1)",
              "\(tT?.orderedPresets.first?.seconds ?? -1)")
        check("TimerPreset.repeatCount", "\(sT.orderedPresets.first?.repeatCount ?? -1)",
              "\(tT?.orderedPresets.first?.repeatCount ?? -1)")

        let sSet = (try! source.fetch(FetchDescriptor<AppSettings>())).first!
        let tSet = (try! target.fetch(FetchDescriptor<AppSettings>())).first
        check("AppSettings.trainingStartDate",
              Formatters.exportDate.string(from: sSet.trainingStartDate),
              tSet.map { Formatters.exportDate.string(from: $0.trainingStartDate) } ?? "")
        check("AppSettings.trainingDaysPerWeek", "\(sSet.trainingDaysPerWeek)", "\(tSet?.trainingDaysPerWeek ?? -1)")
        check("AppSettings.availablePlateSizes", "\(sSet.availablePlateSizes)", "\(tSet?.availablePlateSizes ?? [])")
        check("AppSettings.customWeightIncreaseAmount",
              "\(sSet.customWeightIncreaseAmount)", "\(tSet?.customWeightIncreaseAmount ?? -1)")
        check("AppSettings.hasDumbbell125Attachment",
              "\(sSet.hasDumbbell125Attachment)", "\(tSet?.hasDumbbell125Attachment ?? false)")

        print("\n==== ROUND-TRIP DIFF: \(diffs.count) field(s) do NOT survive ====")
        for diff in diffs { print("  \(diff)") }
        print("====\n")

        // Asserted, not just printed. Every field here is now carried, so a
        // new stored property that nothing exports fails this the moment
        // it's added to the fixture — which is the point of setting them
        // all to non-default values.
        XCTAssertEqual(diffs, [], "fields lost in the round trip")
    }
}
