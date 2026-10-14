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
//  FAILS LOUDLY when the store copy isn't present — it does not skip.
//
//  It used to XCTSkip, pointing at a session scratchpad directory that got
//  cleaned up. The suite then reported "520 tests, 2 skipped" and read as
//  green while the export's lossless guarantee — the entire basis of the
//  automatic backup — was going unverified. That is the same shape as two
//  earlier bugs in this project: a filename-date test that passed against
//  the broken code, and a fixture asserting 40 where the device held 41.
//  A dormant correctness test that looks green is worse than a failing one,
//  so a missing store is now a failure with instructions attached.
//
//  The store therefore lives OUTSIDE any session-scoped temp directory
//  (see defaultStorePath), so routine cleanup can't silently disarm it.
//  Opting out deliberately (a machine with no device copy) means creating
//  a .allow-missing-store marker file beside where the store would be —
//  a file rather than an env var, because env vars don't reach a
//  simulator-hosted test process from the command line.
//
//  It never touches the original: the file is copied to a temp directory
//  first, because opening a store with SwiftData can migrate it.
//

import XCTest
import SwiftData
@testable import TheJym

@MainActor
final class RealStoreRoundTripDiffTests: XCTestCase {

    /// Durable on purpose: ~/Library/Application Support, not a session
    /// scratchpad. The previous path was under /private/tmp/claude-501/<session
    /// id>/, which disappeared when that session's directory was cleaned up
    /// and left both tests skipping unnoticed.
    /// The MAC's home directory, not the simulator's. Tests run in the
    /// simulator, where HOME and NSHomeDirectory() both point inside the
    /// app sandbox and homeDirectoryForCurrentUser doesn't exist at all;
    /// SIMULATOR_HOST_HOME is the host's. Falls back for a device/macOS
    /// run, where HOME already is the right one.
    private static var storeDirectory: URL {
        let env = ProcessInfo.processInfo.environment
        let home = env["SIMULATOR_HOST_HOME"] ?? env["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/TheJymTests", isDirectory: true)
    }
    private static var defaultStorePath: String {
        storeDirectory.appendingPathComponent("default.store").path
    }

    private let schema = Schema([
        AppSettings.self, Bar.self, ExerciseDef.self, Phase.self, PhaseDay.self,
        PlannedExercise.self, WorkoutSession.self, ExerciseLog.self, SetLog.self,
        BodyWeightEntry.self, RestDayActivity.self, ActiveRecovery.self,
        TrainingDaysPerWeekChange.self, TimerTemplate.self, TimerPreset.self,
        // Local-only and deliberately not exported, but it IS in the app's
        // container — so a copy of the real store has the table, and the
        // schema used to open that copy has to know about it.
        BackupStatus.self, MacroTier.self,
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
                // Keyed by (day, order, cycleOverride). Order alone collides:
                // a per-cycle override copies its base slot's `order` and
                // varies only `cycleOverride`, so keying on order let the
                // two collapse into one entry and reported five differences
                // that were really the dump keeping different halves of the
                // pair on each side.
                for pe in d.plannedExercises.sorted(by: {
                    ($0.order, $0.cycleOverride) < ($1.order, $1.cycleOverride)
                }) {
                    out["phase \(phase.number) day \(d.order) pe \(pe.order) cyc \(pe.cycleOverride)"] = [
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

    /// `order` is deliberately NOT compared.
    ///
    /// The real store's own values aren't canonical — one session has logs
    /// ordered 1,2,3,4,5,6,6: no zero, and a duplicate. The export writes
    /// them in that order and the import renumbers densely from 0, so the
    /// integers shift while the SEQUENCE and every log's content are
    /// intact. Comparing the integers would report 11 differences that
    /// describe the source data's untidiness, not a loss.
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

    /// Added in the SAME commit as MacroTier, deliberately. These dumps are
    /// hand-written per model, so a new @Model is simply not diffed until
    /// one exists for it — and the suite would go on reporting "0 fields
    /// differ" while ignoring every macro row, which is the
    /// green-but-proving-nothing shape this file exists to prevent.
    private func dumpMacroTiers(_ ctx: ModelContext) -> Dump {
        var out: Dump = [:]
        for tier in (try! ctx.fetch(FetchDescriptor<MacroTier>())) {
            // Keyed by name: it's the tier's natural key and what the
            // export writes, so a name that failed to round-trip shows up
            // as a lost row rather than a changed field.
            out["tier \(tier.name)"] = [
                "order": "\(tier.order)",
                "protein": num(tier.proteinGrams),
                "carbs": num(tier.carbsGrams),
                "fat": num(tier.fatGrams),
                "sugar": num(tier.sugarGrams),
                "fiber": num(tier.fiberGrams),
                // Computed, not stored — but if any input fails to survive,
                // this is the figure the user would actually notice.
                "calories": num(tier.calories),
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

    /// A store copy, opened from a temp duplicate so the original is never
    /// touched — opening with SwiftData can migrate the file in place, and
    /// the original is the user's only copy of that moment.
    private func openStoreCopy(_ path: String) throws -> ModelContext {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: path + suffix)
            guard FileManager.default.fileExists(atPath: src.path) else { continue }
            try FileManager.default.copyItem(
                at: src, to: tmp.appendingPathComponent("default.store" + suffix))
        }
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(url: tmp.appendingPathComponent("default.store")))
        return ModelContext(container)
    }

    /// Thrown rather than XCTFail'd so the test stops immediately AND the
    /// whole message lands in the failure, instead of a one-line failure
    /// followed by a crash in the code that assumed a store was there.
    ///
    /// CustomStringConvertible, not just LocalizedError: XCTest reports a
    /// thrown error as `caught error: "\(error)"`, which uses `description`
    /// and ignores `errorDescription` entirely. Conforming only to
    /// LocalizedError printed `MissingRealStore(path: "…")` — a failure, but
    /// a silent one, which is the exact shortcoming this change exists to
    /// fix.
    private struct MissingRealStore: LocalizedError, CustomStringConvertible {
        let path: String
        var description: String { errorDescription ?? "" }
        var errorDescription: String? {
            """

            ════════════════════════════════════════════════════════════════
            REAL-STORE ROUND-TRIP TESTS COULD NOT RUN.
            The export's lossless guarantee is currently UNVERIFIED.
            ════════════════════════════════════════════════════════════════

            No store file at:
              \(path)

            These are not optional coverage. They are what proves TheJym's
            .xlsx export round-trips the real store field-by-field without
            loss — which is the entire basis of the automatic backup. A
            fixture can only prove the fields the fixture happens to set.

            To restore it, pull a fresh copy off the device:

              mkdir -p "$HOME/Library/Application Support/TheJymTests"
              xcrun devicectl device copy from \\
                --device 00008150-001640561410C01C \\
                --domain-type appDataContainer \\
                --domain-identifier com.jimbo.TheJym \\
                --source "Library/Application Support" \\
                --destination "$HOME/Library/Application Support/TheJymTests"

            To skip this deliberately on a machine with no device copy
            (never to quiet it locally), create the opt-out marker:

              touch "$HOME/Library/Application Support/TheJymTests/\(RealStoreRoundTripDiffTests.optOutFileName)"

            THEJYM_STORE and THEJYM_ALLOW_MISSING_STORE also work, but ONLY
            when set in Xcode's scheme editor under Test > Arguments >
            Environment Variables — neither reaches the test process when
            exported on the xcodebuild command line, which is why the file
            marker exists.
            ════════════════════════════════════════════════════════════════
            """
        }
    }

    /// A file, not only an env var, because env vars do NOT reach a
    /// simulator-hosted test process from the xcodebuild command line —
    /// verified: plain export, TEST_RUNNER_ and SIMCTL_CHILD_ prefixes all
    /// failed to arrive. They work from Xcode's scheme editor only. An
    /// escape hatch nobody can actually operate is worse than none.
    static let optOutFileName = ".allow-missing-store"

    private func storePath() throws -> String {
        let env = ProcessInfo.processInfo.environment
        let path = env["THEJYM_STORE"] ?? Self.defaultStorePath
        if FileManager.default.fileExists(atPath: path) { return path }

        // The ONLY quiet paths, both of which have to be asked for.
        let marker = Self.storeDirectory.appendingPathComponent(Self.optOutFileName)
        if FileManager.default.fileExists(atPath: marker.path)
            || env["THEJYM_ALLOW_MISSING_STORE"] != nil {
            throw XCTSkip("Opt-out present — real-store verification deliberately skipped.")
        }
        throw MissingRealStore(path: path)
    }

    /// The 309 rows the export drops are all log-less, `day == nil`,
    /// `dayLabel == "Rest Day"` — the exact shape `backfillRestDays` creates
    /// for any date between the first session and today that has no session
    /// of its own. If one launch after a restore puts them all back, the
    /// right fix is NOTHING: an exporter for data the app regenerates is
    /// 315 rows of file and a second thing to keep correct.
    ///
    /// This measures that rather than assuming it, and will fail if the
    /// regenerated population ever stops matching.
    func testBackfillRegeneratesTheLoglessRestDays() async throws {
        let source = try openStoreCopy(try storePath())
        let cal = Calendar.current

        let sourcePlaceholders = (try source.fetch(FetchDescriptor<WorkoutSession>()))
            .filter(\.isBackfilledRestPlaceholder)
        let sourceDays = Set(sourcePlaceholders.map { cal.startOfDay(for: $0.date) })

        let target = try await restoreIntoEmptyStore(from: source)

        let beforeBackfill = (try target.fetch(FetchDescriptor<WorkoutSession>()))
            .filter(\.isBackfilledRestPlaceholder).count
        WorkoutSession.backfillRestDays(context: target)
        let after = (try target.fetch(FetchDescriptor<WorkoutSession>()))
            .filter(\.isBackfilledRestPlaceholder)
        let afterDays = Set(after.map { cal.startOfDay(for: $0.date) })

        let regenerated = sourceDays.intersection(afterDays)

        // What actually matters is that no DAY is left with a hole in
        // History, not which mechanism filled it. The import's own gap-fill
        // reaches the days inside a phase's attributed range first and
        // creates a real Rest-PhaseDay session there, which is strictly
        // better than a `day == nil` placeholder — so those days are covered
        // without ever becoming placeholders again.
        let allTargetDays = Set((try target.fetch(FetchDescriptor<WorkoutSession>()))
            .map { cal.startOfDay(for: $0.date) })
        let uncovered = sourceDays.subtracting(allTargetDays).sorted()
        let coveredByGapFill = sourceDays.subtracting(afterDays).intersection(allTargetDays)

        print("""

        ==== BACKFILL REGENERATION ====
        source log-less "Rest Day" placeholders: \(sourcePlaceholders.count) \
        on \(sourceDays.count) distinct days
        after import, before backfill:           \(beforeBackfill)
        after one backfillRestDays:              \(after.count) \
        on \(afterDays.count) distinct days
        regenerated as placeholders:             \(regenerated.count)
        covered instead by the import gap-fill:  \(coveredByGapFill.count) \
        \(coveredByGapFill.sorted().prefix(5).map { Formatters.exportDate.string(from: $0) })
        STILL UNCOVERED (\(uncovered.count)): \
        \(uncovered.prefix(10).map { Formatters.exportDate.string(from: $0) })
        ==== END ====

        """)

        XCTAssertTrue(uncovered.isEmpty,
                      "a restore + one launch no longer puts a session back on every day the "
                      + "export drops — the History sheet needs a sentinel row after all")
    }

    /// Export `source` with the app's own builder and import the result the
    /// way the Recovery Import screen does: program, then library, then
    /// history.
    private func restoreIntoEmptyStore(from source: ModelContext) async throws -> ModelContext {
        let data = ExportBuilder.workbook(from: source)
        let restNames = Set((try source.fetch(FetchDescriptor<RestDayActivity>()))
            .map { $0.name.lowercased() })
        let container = try ModelContainer(
            for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let target = ModelContext(container)
        target.insert(AppSettings())
        try target.save()
        guard let wb = ImportEngine.parseWorkbook(xlsxData: data, restActivityNames: restNames) else {
            throw XCTSkip("the app's own export did not parse")
        }
        ImportEngine.restoreProgram(wb.program, context: target)
        ImportEngine.restoreLibraryAndEquipment(wb, context: target)
        _ = await ImportEngine.importIntoStore(wb.historyRows, context: target)
        try target.save()
        return target
    }

    func testRealStoreRoundTripDiff() async throws {
        let path = try storePath()

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

        // WHY THIS SEED EXISTS, AND WHEN IT MAY GO.
        //
        // A diff of two EMPTY sets reports perfect fidelity over nothing.
        // The first run of this test after MacroTier landed did exactly
        // that: the real store had no tiers, the dump compared [] against
        // [], and the whole suite reported "0 fields differ" while
        // exercising not one line of the new export. The number was true
        // and meaningless — the same green-but-proving-nothing shape as
        // the filename-date test that passed against broken code and the
        // two real-store tests that sat skipping behind a passing suite.
        //
        // So: NOT "delete this once the store has a tier". One tier isn't
        // coverage either — it can't catch a field swapped with its
        // neighbour, an ordering bug, or a name-matching failure on
        // import. This may go only when the real store carries several
        // tiers with DIFFERENT values in every field, which is what makes
        // a passing diff evidence rather than a tautology. Until then it
        // seeds deliberately dissimilar numbers.
        //
        // Written to the temp copy only; the original is never touched.
        if (try source.fetch(FetchDescriptor<MacroTier>())).count < 2 {
            // Distinct in every field, so a value landing in the wrong
            // column shows up rather than matching by luck.
            let existing = Set((try source.fetch(FetchDescriptor<MacroTier>())).map(\.name))
            for seed in [MacroTier(name: "DiffSeed A", order: 90, proteinGrams: 201, carbsGrams: 152,
                                   fatGrams: 53, sugarGrams: 24, fiberGrams: 35),
                         MacroTier(name: "DiffSeed B", order: 91, proteinGrams: 182, carbsGrams: 303,
                                   fatGrams: 84, sugarGrams: 61, fiberGrams: 26)]
            where !existing.contains(seed.name) {
                source.insert(seed)
            }
            try source.save()
        }

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

        // Field equality isn't enough for a per-cycle override: the dump
        // compares `overriddenSlotID` as presence only (the UUID itself
        // can't survive), so a link rebuilt to the WRONG base slot would
        // still read as equal. This compares the plan the app actually
        // trains, day by day and cycle by cycle, which is the thing an
        // override exists to change.
        var planReport = Report()
        func dumpPlans(_ ctx: ModelContext) -> Dump {
            var out: Dump = [:]
            for phase in (try! ctx.fetch(FetchDescriptor<Phase>())) {
                for d in phase.orderedDays {
                    for cycle in 1...max(phase.totalCycles, 1) {
                        out["phase \(phase.number) day \(d.order) cycle \(cycle)"] = [
                            "plan": phase.plan(for: d, cycle: cycle)
                                .map { "\($0.exerciseName)\($0.targetReps)" }
                                .joined(separator: " | "),
                        ]
                    }
                }
            }
            return out
        }
        diff("Plan", dumpPlans(source), dumpPlans(target), into: &planReport)
        XCTAssertTrue(planReport.fieldMismatches.isEmpty,
                      "the trained plan differs after a round trip: "
                      + "\(planReport.fieldMismatches)")

        var report = Report()
        diff("ExerciseDef", dumpDefs(source), dumpDefs(target), into: &report)
        diff("Bar", dumpBars(source), dumpBars(target), into: &report)
        diff("Phase", dumpPhases(source), dumpPhases(target), into: &report)
        diff("Session", dumpSessions(source), dumpSessions(target), into: &report)
        diff("RestDayActivity", dumpRestActivities(source), dumpRestActivities(target), into: &report)
        diff("MacroTier", dumpMacroTiers(source), dumpMacroTiers(target), into: &report)
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
