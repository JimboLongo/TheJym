//
//  ExportBuilder.swift
//  TheJym
//
//  The export workbook, lifted out of SettingsView so the round-trip can
//  be TESTED against the real exporter rather than a transcription of it.
//
//  That distinction has already cost real data: a sheet's columns were
//  asserted to carry isBigLift, repSchemeCeilings and distanceUnit when
//  they didn't, and the only thing that settled it was running the actual
//  writer into the actual reader and diffing. A copy of this logic inside
//  a test can agree with itself while disagreeing with the app.
//

import Foundation
import SwiftData

@MainActor
enum ExportBuilder {

    /// Every exportable row in the store, as a 4-tab .xlsx.
    ///
    /// - "History": every logged workout plus every body-weight entry,
    ///   interleaved chronologically as "Body Weight" pseudo-exercise rows.
    /// - "Exercises": the library — name, equipment, bodyweight flag, saved
    ///   sets, notes, big-lift flag, rep ceilings, dateAdded.
    /// - "Equipment": every Bar (barbells, dumbbell sets, bands) + plates.
    /// - "Program": phases, days, planned exercises, recoveries, timer
    ///   templates/presets and settings, one row per record tagged by type.
    static func workbook(from context: ModelContext) -> Data {
        XLSXWriter.makeWorkbook(sheets: [
            ("History", historyRows(from: context)),
            ("Exercises", exercisesRows(from: context)),
            ("Equipment", equipmentRows(from: context)),
            ("Program", programRows(from: context)),
        ])
    }

    static func isEmpty(_ context: ModelContext) -> Bool {
        fetch(WorkoutSession.self, context).isEmpty
            && fetch(ExerciseDef.self, context).isEmpty
            && fetch(Bar.self, context).isEmpty
    }

    private static func fetch<T: PersistentModel>(_ type: T.Type, _ context: ModelContext) -> [T] {
        (try? context.fetch(FetchDescriptor<T>())) ?? []
    }

    /// Columns after Reps are what makes this a round trip rather than a
    /// one-way dump. Phase/Day/Cycle restore a session's attribution (an
    /// import without them lands everything as "Imported" with no phase,
    /// which is exactly what the Oct 2026 recovery hit); Duration, Deload
    /// and Bonus are per-session facts nothing else carries; AddedWeight
    /// and BodyweightAtLog are what let a bodyweight set be rebuilt
    /// instead of guessed at.
    ///
    /// BodyweightAtLog is exported rather than re-resolved on import
    /// because it's FROZEN at log time by design (SetLog's own doc) — a
    /// later weigh-in edit must not retroactively change an old set, and
    /// re-resolving on import would do precisely that.
    static func historyRows(from context: ModelContext) -> [[XLSXCell]] {
        var rows: [[XLSXCell]] = [[.string("Date"), .string("Exercise"), .string("Sets"),
                                   .string("Weights"), .string("Reps"),
                                   .string("Phase"), .string("Day"), .string("Cycle"),
                                   .string("Duration"), .string("Deload"), .string("Bonus"),
                                   .string("AddedWeight"), .string("BodyweightAtLog"),
                                   .string("Rank"), .string("Missed"), .string("WeightAdj"),
                                   .string("LogBodyweight"), .string("Unit")]]
        var dated: [(date: Date, row: [XLSXCell])] = []
        for session in fetch(WorkoutSession.self, context) {
            let dateStr = Formatters.exportDate.string(from: session.date)
            for log in session.exerciseLogs.sorted(by: { $0.order < $1.order }) {
                let sortedSets = log.sortedSets
                guard !sortedSets.isEmpty else { continue }
                let weights = sortedSets.map { Formatters.trim($0.weight) }.joined(separator: "/")
                let reps = sortedSets.map { String($0.reps) }.joined(separator: "/")
                // Per-set, slash-joined like Weights/Reps so they line up
                // index for index. Blank when no set carries one.
                let added = sortedSets.map { $0.addedWeight.map(Formatters.trim) ?? "" }.joined(separator: "/")
                let bwAt = sortedSets.map { $0.bodyweightAtLog.map(Formatters.trim) ?? "" }.joined(separator: "/")
                dated.append((session.date, [
                    .string(dateStr), .string(log.exerciseName),
                    .string(log.setsSummaryText), .string(weights), .string(reps),
                    session.phase.map { .number(Double($0.number)) } ?? .blank,
                    .string(session.dayLabel),
                    session.cycleNumber > 0 ? .number(Double(session.cycleNumber)) : .blank,
                    session.durationSeconds.map { .number(Double($0)) } ?? .blank,
                    session.isDeload ? .string("Yes") : .blank,
                    session.isBonusSession ? .string("Yes") : .blank,
                    added.replacingOccurrences(of: "/", with: "").isEmpty ? .blank : .string(added),
                    bwAt.replacingOccurrences(of: "/", with: "").isEmpty ? .blank : .string(bwAt),
                    log.achievedRank.map { .number(Double($0)) } ?? .blank,
                    log.missedTarget ? .string("Yes") : .blank,
                    log.selectedWeightAdjustment.map { .number($0) } ?? .blank,
                    log.isBodyweight ? .string("Yes") : .blank,
                    // The rest activity's own unit — previously assumed
                    // "mi" on import, which silently dropped a km walk
                    // from every miles figure.
                    .string(log.restDayActivity?.distanceUnit ?? ""),
                ]))
            }
        }
        for entry in fetch(BodyWeightEntry.self, context) {
            let dateStr = Formatters.exportDate.string(from: entry.date)
            dated.append((entry.date, [.string(dateStr), .string("Body Weight"), .blank,
                                       .number(entry.weight), .blank]))
        }
        rows.append(contentsOf: dated.sorted { $0.date < $1.date }.map(\.row))
        return rows
    }

    /// Everything the three original sheets drop: the program itself.
    ///
    /// One row per record, tagged by Type in column A, because these are
    /// several different shapes and a sheet each would be several more tabs
    /// to keep in sync. The importer dispatches on that tag and ignores a
    /// type it doesn't know, so adding a row type later doesn't break an
    /// older build reading a newer file.
    static func programRows(from context: ModelContext) -> [[XLSXCell]] {
        var rows: [[XLSXCell]] = [[.string("Type"), .string("A"), .string("B"), .string("C"),
                                   .string("D"), .string("E"), .string("F"), .string("G"),
                                   .string("H"), .string("I"), .string("J"), .string("K"), .string("L")]]
        for phase in fetch(Phase.self, context).sorted(by: { $0.number < $1.number }) {
            rows.append([.string("Phase"), .number(Double(phase.number)),
                         .number(Double(phase.totalCycles)),
                         .string(Formatters.exportDate.string(from: phase.startDate)),
                         .string(phase.isActive ? "Yes" : "No"),
                         .number(Double(phase.deloadCycle)),
                         .string(phase.manualDeloadCycles.map(String.init).joined(separator: ",")),
                         phase.legacyCompletedCycles.map { .number(Double($0)) } ?? .blank])
            for day in phase.orderedDays {
                rows.append([.string("PhaseDay"), .number(Double(phase.number)),
                             .number(Double(day.order)), .string(day.name),
                             .string(day.isRest ? "Yes" : "No")])
                for pe in day.plannedExercises.sorted(by: { $0.order < $1.order }) {
                    // Built in steps: as one literal this exceeded the
                    // type checker's budget for a single expression.
                    let targets = pe.targetReps.map(String.init).joined(separator: "/")
                    let weights = pe.suggestedWeights.map { Formatters.trim($0) }.joined(separator: "/")
                    let rest: XLSXCell = pe.restTimeSeconds.map { .number(Double($0)) } ?? .blank
                    var row: [XLSXCell] = [.string("PlannedExercise")]
                    row.append(.number(Double(phase.number)))
                    row.append(.string(day.name))
                    row.append(.number(Double(pe.order)))
                    row.append(.string(pe.exerciseName))
                    row.append(.string(targets))
                    row.append(.string(weights))
                    row.append(.string(pe.isBodyweight ? "Yes" : "No"))
                    row.append(.number(Double(pe.goalKindRaw)))
                    row.append(.number(Double(pe.repTotalTarget)))
                    row.append(rest)
                    row.append(.number(Double(pe.cycleOverride)))
                    // Column L — the owning day's order, because "Rest"
                    // is not a unique day name within a phase.
                    row.append(.number(Double(day.order)))
                    rows.append(row)
                }
            }
        }
        for recovery in fetch(ActiveRecovery.self, context).sorted(by: { $0.date < $1.date }) {
            rows.append([.string("ActiveRecovery"),
                         .string(Formatters.exportDate.string(from: recovery.date)),
                         .number(Double(recovery.typeRaw))])
        }
        for change in fetch(TrainingDaysPerWeekChange.self, context).sorted(by: { $0.date < $1.date }) {
            rows.append([.string("TrainingDaysPerWeek"),
                         .string(Formatters.exportDate.string(from: change.date)),
                         .number(Double(change.trainingDaysPerWeek))])
        }
        for template in fetch(TimerTemplate.self, context).sorted(by: { $0.order < $1.order }) {
            rows.append([.string("TimerTemplate"), .string(template.name),
                         .number(Double(template.order)),
                         .string(template.continuous ? "Yes" : "No")])
            for preset in template.orderedPresets {
                rows.append([.string("TimerPreset"), .string(template.name),
                             .string(preset.name), .number(preset.seconds),
                             .number(Double(preset.repeatCount)),
                             .number(Double(preset.order)),
                             .string(preset.isRest ? "Yes" : "No")])
            }
        }
        if let s = fetch(AppSettings.self, context).first {
            func setting(_ key: String, _ value: XLSXCell) {
                rows.append([.string("Setting"), .string(key), value])
            }
            setting("trainingStartDate", .string(Formatters.exportDate.string(from: s.trainingStartDate)))
            setting("trainingDaysPerWeek", .number(Double(s.trainingDaysPerWeek)))
            setting("aiAggressivenessRaw", .number(Double(s.aiAggressivenessRaw)))
            setting("deloadWeeksEnabled", .string(s.deloadWeeksEnabled ? "Yes" : "No"))
            setting("hasDumbbell125Attachment", .string(s.hasDumbbell125Attachment ? "Yes" : "No"))
            setting("hasDumbbell25Attachment", .string(s.hasDumbbell25Attachment ? "Yes" : "No"))
            setting("customWeightIncreaseEnabled", .string(s.customWeightIncreaseEnabled ? "Yes" : "No"))
            setting("customWeightIncreaseStreak", .number(Double(s.customWeightIncreaseStreak)))
            setting("customWeightIncreaseAmount", .number(s.customWeightIncreaseAmount))
            setting("streakRemindersEnabled", .string(s.streakRemindersEnabled ? "Yes" : "No"))
            setting("streakReminderHour", .number(Double(s.streakReminderHour)))
            setting("weightRemindersEnabled", .string(s.weightRemindersEnabled ? "Yes" : "No"))
            setting("weightReminderHour", .number(Double(s.weightReminderHour)))
            setting("includeDefaultExercises", .string(s.includeDefaultExercises ? "Yes" : "No"))
        }
        return rows
    }

    static func exercisesRows(from context: ModelContext) -> [[XLSXCell]] {
        var rows: [[XLSXCell]] = [[.string("Exercise"), .string("Equipment"), .string("Bodyweight"),
                                   .string("Sets"), .string("Notes"), .string("BigLift"),
                                   .string("Ceilings"), .string("MoreNotes"), .string("Added")]]
        for def in fetch(ExerciseDef.self, context).sorted(by: { $0.name < $1.name }) {
            let sets = (def.repSchemes.map { $0.map(String.init).joined(separator: "/") }
                        + def.repTotalTargets.map { "\($0) total" }).joined(separator: "; ")
            // "5/5/5>8/8/8@5" — base reps, upper targets, increase amount.
            // Drives the rep-ceiling progression, so losing it changed how
            // weights advance, not just what a screen displayed.
            let ceilings = def.repSchemeCeilings.map { c in
                "\(c.reps.map(String.init).joined(separator: "/"))>"
                + "\(c.upperTargetReps.map(String.init).joined(separator: "/"))"
                + "@\(Formatters.trim(c.weightIncreaseAmount))"
            }.joined(separator: "; ")
            rows.append([.string(def.name), .string(def.equipment?.name ?? ""),
                        .string(def.isBodyweight ? "Yes" : "No"), .string(sets), .string(def.notes),
                        .string(def.isBigLift ? "Yes" : "No"), .string(ceilings),
                        .string(def.additionalNotes),
                        .string(Formatters.exportDate.string(from: def.dateAdded))])
        }
        return rows
    }

    static func equipmentRows(from context: ModelContext) -> [[XLSXCell]] {
        var rows: [[XLSXCell]] = [[.string("Name"), .string("Type"), .string("Weight"),
                                   .string("Sides"), .string("Dumbbell/Band Weights")]]
        for bar in fetch(Bar.self, context).sorted(by: { $0.name < $1.name }) {
            rows.append([.string(bar.name), .string(bar.isDumbbell ? "Dumbbell/Band" : "Barbell"),
                        bar.isDumbbell ? .blank : .number(bar.weight),
                        bar.isDumbbell ? .blank : .int(bar.loadableSides),
                        .string(bar.dumbbellWeights.map { Formatters.trim($0) }.joined(separator: ", "))])
        }
        if let plates = fetch(AppSettings.self, context).first?.availablePlateSizes, !plates.isEmpty {
            rows.append([.blank])
            rows.append([.string("Plates Owned"),
                         .string(plates.map { Formatters.trim($0) }.joined(separator: ", "))])
        }
        return rows
    }
}
