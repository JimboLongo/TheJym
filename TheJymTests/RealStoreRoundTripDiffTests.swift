//
//  RealStoreRoundTripDiffTests.swift
//  TheJymTests
//
//  The definitive export test, run against the REAL store rather than a
//  fixture: open a copy of the live store file, export it with the app's
//  own ExportBuilder, import that workbook into an empty store, then dump
//  every row of every table to a canonical per-field form and diff.
//
//  A fixture can only prove the fields the fixture happens to set. This
//  proves what survives for 659 sessions, 1,415 logs, 4,754 sets, 98
//  exercises and 119 rest activities of actual history, which is the only
//  number that answers "can I restore from this file".
//
//  Skips cleanly when the store copy isn't present, so the suite stays
//  green on any machine but this one. Point THEJYM_STORE at a store copy
//  to re-run it. It never touches the original: the file is copied to a
//  temp directory first, because opening a store with SwiftData can
//  migrate it.
//

import XCTest
import SwiftData
@testable import TheJym

@MainActor
final class RealStoreRoundTripDiffTests: XCTestCase {

    private static let defaultStorePath =
        "/private/tmp/claude-501/-Users-jimmylong-Desktop-TheJym/"
        + "bb409c73-535f-4744-b8cd-e21f1c342575/scratchpad/post4/default.store"

    private let schema = Schema([
        AppSettings.self, Bar.self, ExerciseDef.self, Phase.self, PhaseDay.self,
        PlannedExercise.self, WorkoutSession.self, ExerciseLog.self, SetLog.self,
        BodyWeightEntry.self, RestDayActivity.self, ActiveRecovery.self,
        TrainingDaysPerWeekChange.self, TimerTemplate.self, TimerPreset.self,
    ])

    // MARK: - Canonical dumps
    //
    // Each model becomes [naturalKey: [field: value]]. The key has to come
    // from the DATA, not from a persistent ID, because the imported rows
    // are new objects — so a key that isn't unique silently merges rows and
    // hides a difference. Each key below is the tuple the app itself treats
    // as identifying (name, or date + label, or parent + order).

    private typealias Dump = [String: [String: String]]

    private func num(_ d: Double) -> String { Formatters.trim(d) }
    private func day(_ d: Date) -> String { Formatters.exportDate.string(from: d) }

    private func dumpDefs(_ ctx: ModelContext) -> Dump {
        var out: Dump = [:]
        for def in (try! ctx.fetch(FetchDescriptor<ExerciseDef>())) {
            out[def.name] = [
                "isBodyweight": "\(def.isBodyweight)",
                "isBigLift": "\(def.isBigLift)",
                "notes": def.notes,
                "additionalNotes": def.additionalNotes,
                "equipment": def.equipment?.name ?? "",
                "repSchemes": "\(def.repSchemes)",
                "repTotalTargets": "\(def.repTotalTargets)",
                "dateAdded": day(def.dateAdded),
                "ceilings": def.repSchemeCeilings
                    .map { "\($0.reps)>\($0.upperTargetReps)@\(num($0.weightIncreaseAmount))" }
                    .joined(separator: ";"),
            ]
        }
        return out
    }

    private func dumpBars(_ ctx: ModelContext) -> Dump {
        var out: Dump = [:]
        for bar in (try! ctx.fetch(FetchDescriptor<Bar>())) {
            out[bar.name] = [
                "isDumbbell": "\(bar.isDumbbell)",
                "weight": num(bar.weight),
                "loadableSides": "\(bar.loadableSides)",
                "dumbbellWeights": bar.dumbbellWeights.map(num).joined(separator: ","),
            ]
        }
        return out
    }

    private func dumpPhases(_ ctx: ModelContext) -> Dump {
        var out: Dump = [:]
        for phase in (try! ctx.fetch(FetchDescriptor<Phase>())) {
            out["phase \(phase.number)"] = [
                "totalCycles": "\(phase.totalCycles)",
                "startDate": day(phase.startDate),
                "isActive": "\(phase.isActive)",
                "deloadCycle": "\(phase.deloadCycle)",
                "manualDeloadCycles": "\(phase.manualDeloadCycles.sorted())",
                "legacyCompletedCycles": phase.legacyCompletedCycles.map(String.init) ?? "",
                "dayCount": "\(phase.orderedDays.count)",
            ]
            for d in phase.orderedDays {
                out["phase \(phase.number) day \(d.order)"] = [
                    "name": d.name,
                    "isRest": "\(d.isRest)",
                    "plannedCount": "\(d.plannedExercises.count)",
                ]
                for pe in d.plannedExercises.sorted(by: { $0.order < $1.order }) {
                    out["phase \(phase.number) day \(d.order) pe \(pe.order)"] = [
                        "exerciseName": pe.exerciseName,
                        "targetReps": "\(pe.targetReps)",
                        "suggestedWeights": pe.suggestedWeights.map(num).joined(separator: "/"),
                        "isBodyweight": "\(pe.isBodyweight)",
                        "goalKindRaw": "\(pe.goalKindRaw)",
                        "repTotalTarget": "\(pe.repTotalTarget)",
                        "restTimeSeconds": pe.restTimeSeconds.map(String.init) ?? "",
                        "cycleOverride": "\(pe.cycleOverride)",
                        "repTotalProgressesReps": "\(pe.repTotalProgressesReps)",
                        // slotID/overriddenSlotID are identity, not data —
                        // compared as "was one set at all", since the value
                        // itself can't survive a new object.
                        "hasOverriddenSlotID": "\(pe.overriddenSlotID != nil)",
                    ]
                }
            }
        }
        return out
    }

    /// Session key: day + dayLabel + the logged exercise names. Date alone
    /// isn't unique (a walk and a lift share a day), and day + label isn't
    /// either in this store.
    private func sessionKey(_ s: WorkoutSession) -> String {
        let names = s.exerciseLogs.map(\.exerciseName).sorted().joined(separator: "+")
        return "\(day(s.date))|\(s.dayLabel)|\(names)"
    }

    private func dumpSessions(_ ctx: ModelContext) -> Dump {
        var out: Dump = [:]
        for s in (try! ctx.fetch(FetchDescriptor<WorkoutSession>())) {
            let key = sessionKey(s)
            out[key] = [
                "phase": s.phase.map { "\($0.number)" } ?? "",
                "day": s.day.map { "\($0.order):\($0.name)" } ?? "",
                "dayLabel": s.dayLabel,
                "cycleNumber": "\(s.cycleNumber)",
                "isDeload": "\(s.isDeload)",
                "isBonusSession": "\(s.isBonusSession)",
                "durationSeconds": s.durationSeconds.map(String.init) ?? "",
                "logCount": "\(s.exerciseLogs.count)",
            ]
            for log in s.exerciseLogs.sorted(by: { $0.order < $1.order }) {
                let lk = "\(key)|log \(log.exerciseName)"
                out[lk] = [
                    "order": "\(log.order)",
                    "targetReps": "\(log.targetReps)",
                    "isBodyweight": "\(log.isBodyweight)",
                    "achievedRank": log.achievedRank.map(String.init) ?? "",
                    "missedTarget": "\(log.missedTarget)",
                    "selectedWeightAdjustment": log.selectedWeightAdjustment.map(num) ?? "",
                    "goalKindRaw": "\(log.goalKindRaw)",
                    "repTotalTarget": "\(log.repTotalTarget)",
                    "restActivity": log.restDayActivity.map { "\($0.name)" } ?? "",
                    "setCount": "\(log.sortedSets.count)",
                    "weights": log.sortedSets.map { num($0.weight) }.joined(separator: "/"),
                    "reps": log.sortedSets.map { "\($0.reps)" }.joined(separator: "/"),
                    "addedWeight": log.sortedSets.map { $0.addedWeight.map(num) ?? "" }
                        .joined(separator: "/"),
                    "bodyweightAtLog": log.sortedSets.map { $0.bodyweightAtLog.map(num) ?? "" }
                        .joined(separator: "/"),
                ]
            }
        }
        return out
    }

    private func dumpRestActivities(_ ctx: ModelContext) -> Dump {
        var out: Dump = [:]
        for a in (try! ctx.fetch(FetchDescriptor<RestDayActivity>())) {
            out["\(day(a.date))|\(a.name)"] = [
                "distance": a.distance.map(num) ?? "",
                "distanceUnit": a.distanceUnit,
            ]
        }
        return out
    }

    private func dumpMisc(_ ctx: ModelContext) -> Dump {
        var out: Dump = [:]
        for e in (try! ctx.fetch(FetchDescriptor<BodyWeightEntry>())) {
            out["bodyweight \(day(e.date))"] = ["weight": num(e.weight)]
        }
        for r in (try! ctx.fetch(FetchDescriptor<ActiveRecovery>())) {
            out["recovery \(day(r.date))"] = ["typeRaw": "\(r.typeRaw)"]
        }
        for c in (try! ctx.fetch(FetchDescriptor<TrainingDaysPerWeekChange>())) {
            out["tdpw \(day(c.date))"] = ["days": "\(c.trainingDaysPerWeek)"]
        }
        for t in (try! ctx.fetch(FetchDescriptor<TimerTemplate>())) {
            out["template \(t.name)"] = [
                "order": "\(t.order)",
                "continuous": "\(t.continuous)",
                "presetCount": "\(t.presets.count)",
            ]
            for p in t.orderedPresets {
                out["template \(t.name) preset \(p.order)"] = [
                    "name": p.name,
                    "seconds": num(p.seconds),
                    "repeatCount": "\(p.repeatCount)",
                    "isRest": "\(p.isRest)",
                ]
            }
        }
        if let s = (try! ctx.fetch(FetchDescriptor<AppSettings>())).first {
            out["settings"] = [
                "trainingStartDate": day(s.trainingStartDate),
                "trainingDaysPerWeek": "\(s.trainingDaysPerWeek)",
                "aiAggressivenessRaw": "\(s.aiAggressivenessRaw)",
                "deloadWeeksEnabled": "\(s.deloadWeeksEnabled)",
                "hasDumbbell125Attachment": "\(s.hasDumbbell125Attachment)",
                "hasDumbbell25Attachment": "\(s.hasDumbbell25Attachment)",
                "customWeightIncreaseEnabled": "\(s.customWeightIncreaseEnabled)",
                "customWeightIncreaseStreak": "\(s.customWeightIncreaseStreak)",
                "customWeightIncreaseAmount": num(s.customWeightIncreaseAmount),
                "streakRemindersEnabled": "\(s.streakRemindersEnabled)",
                "streakReminderHour": "\(s.streakReminderHour)",
                "weightRemindersEnabled": "\(s.weightRemindersEnabled)",
                "weightReminderHour": "\(s.weightReminderHour)",
                "includeDefaultExercises": "\(s.includeDefaultExercises)",
                "availablePlateSizes": s.availablePlateSizes.map(num).joined(separator: ","),
                "aiAssistantEnabled": "\(s.aiAssistantEnabled)",
                "useGeminiForPhasePlanning": "\(s.useGeminiForPhasePlanning)",
                // geminiAPIKey is deliberately NOT exported — a shared
                // workbook would carry the key. Compared as presence only.
                "hasGeminiAPIKey": "\(!s.geminiAPIKey.isEmpty)",
            ]
        }
        return out
    }

    // MARK: - The diff

    private struct Report {
        var missingKeys: [String] = []       // in source, absent after import
        var extraKeys: [String] = []         // created by import, not in source
        var fieldMismatches: [String: [(String, String, String)]] = [:]  // field -> [(key, before, after)]
    }

    private func diff(_ table: String, _ before: Dump, _ after: Dump,
                      into report: inout Report) {
        for (key, fields) in before {
            guard let got = after[key] else {
                report.missingKeys.append("\(table): \(key)")
                continue
            }
            for (field, value) in fields where got[field] != value {
                report.fieldMismatches["\(table).\(field)", default: []]
                    .append((key, value, got[field] ?? "<absent>"))
            }
        }
        for key in after.keys where before[key] == nil {
            report.extraKeys.append("\(table): \(key)")
        }
    }

    func testRealStoreRoundTripDiff() async throws {
        let path = ProcessInfo.processInfo.environment["THEJYM_STORE"] ?? Self.defaultStorePath
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("No store at \(path) — set THEJYM_STORE to run this.")
        }

        // Copy before opening: SwiftData may migrate the file in place and
        // the original is the user's only copy of that moment.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let working = tmp.appendingPathComponent("default.store")
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: path + suffix)
            guard FileManager.default.fileExists(atPath: src.path) else { continue }
            try FileManager.default.copyItem(
                at: src, to: tmp.appendingPathComponent("default.store" + suffix))
        }

        let sourceContainer = try ModelContainer(
            for: schema, configurations: ModelConfiguration(url: working))
        let source = ModelContext(sourceContainer)

        let counts = [
            "WorkoutSession": (try source.fetch(FetchDescriptor<WorkoutSession>())).count,
            "ExerciseLog": (try source.fetch(FetchDescriptor<ExerciseLog>())).count,
            "SetLog": (try source.fetch(FetchDescriptor<SetLog>())).count,
            "ExerciseDef": (try source.fetch(FetchDescriptor<ExerciseDef>())).count,
            "RestDayActivity": (try source.fetch(FetchDescriptor<RestDayActivity>())).count,
            "BodyWeightEntry": (try source.fetch(FetchDescriptor<BodyWeightEntry>())).count,
            "TimerPreset": (try source.fetch(FetchDescriptor<TimerPreset>())).count,
            "Bar": (try source.fetch(FetchDescriptor<Bar>())).count,
            "PlannedExercise": (try source.fetch(FetchDescriptor<PlannedExercise>())).count,
        ]

        // Export with the app's own builder, then import the way the
        // Recovery Import screen does: program, then library, then history.
        let data = ExportBuilder.workbook(from: source)
        let restNames = Set((try source.fetch(FetchDescriptor<RestDayActivity>()))
            .map { $0.name.lowercased() })

        let targetContainer = try ModelContainer(
            for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let target = ModelContext(targetContainer)
        target.insert(AppSettings())
        try target.save()

        guard let wb = ImportEngine.parseWorkbook(xlsxData: data, restActivityNames: restNames) else {
            return XCTFail("the app's own export did not parse")
        }
        ImportEngine.restoreProgram(wb.program, context: target)
        ImportEngine.restoreLibraryAndEquipment(wb, context: target)
        _ = await ImportEngine.importIntoStore(wb.historyRows, context: target)
        try target.save()

        var report = Report()
        diff("ExerciseDef", dumpDefs(source), dumpDefs(target), into: &report)
        diff("Bar", dumpBars(source), dumpBars(target), into: &report)
        diff("Phase", dumpPhases(source), dumpPhases(target), into: &report)
        diff("Session", dumpSessions(source), dumpSessions(target), into: &report)
        diff("RestDayActivity", dumpRestActivities(source), dumpRestActivities(target), into: &report)
        diff("Misc", dumpMisc(source), dumpMisc(target), into: &report)

        // --- report
        var lines: [String] = []
        lines.append("==== REAL-STORE ROUND TRIP ====")
        lines.append("source rows: " + counts.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: "  "))
        lines.append("workbook bytes: \(data.count)")
        lines.append("history rows parsed: \(wb.historyRows.count) of \(wb.sourceRowCount) "
                     + "(skipped \(wb.skipped.total))")
        lines.append("")
        lines.append("ROWS LOST (\(report.missingKeys.count)):")
        for key in report.missingKeys.sorted().prefix(25) { lines.append("  - \(key)") }
        if report.missingKeys.count > 25 {
            lines.append("  … \(report.missingKeys.count - 25) more")
        }
        lines.append("")
        lines.append("ROWS INVENTED (\(report.extraKeys.count)):")
        for key in report.extraKeys.sorted().prefix(25) { lines.append("  + \(key)") }
        if report.extraKeys.count > 25 {
            lines.append("  … \(report.extraKeys.count - 25) more")
        }
        lines.append("")
        lines.append("FIELDS THAT DO NOT ROUND-TRIP (\(report.fieldMismatches.count) fields):")
        if report.fieldMismatches.isEmpty { lines.append("  (none)") }
        for (field, hits) in report.fieldMismatches.sorted(by: { $0.value.count > $1.value.count }) {
            lines.append("  \(field): \(hits.count) row(s) differ")
            for (key, before, after) in hits.prefix(3) {
                lines.append("      \(key)")
                lines.append("        before: \(before.prefix(120))")
                lines.append("        after:  \(after.prefix(120))")
            }
        }
        lines.append("==== END ====")
        print(lines.joined(separator: "\n"))

        try? FileManager.default.removeItem(at: tmp)
    }
}
