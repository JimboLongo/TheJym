//
//  ImportEngine.swift
//  TheJym
//
//  Bulk-import historical workouts from a CSV or Excel (.xlsx) file (e.g. a
//  Google Sheet exported/shared as either). One row = one exercise logged on
//  one day, with Date, Exercise, Sets, Weights, and Reps columns (any order,
//  header matched case-insensitively), plus two optional columns, Phase and
//  Day, to attribute the row to a real Phase/PhaseDay instead of a generic
//  "Imported" entry:
//
//    Date       | Phase | Day    | Exercise    | Sets      | Weights              | Reps
//    2026-01-05 | 2     | Push A | Back Squat  | 5/5/5/3/3 | 135/135/135/145/145 | 6/5/5/5/3
//
//  Sets is the target rep scheme for that exercise (becomes a saved "Set" on
//  it in the Exercises tab); Weights and Reps are what was actually lifted,
//  one slash-separated value per set, in the same order. Weights and Reps
//  must have the same count; Sets may have a different count or be left
//  blank if there was no real target.
//
//  For a rep-total exercise (e.g. Pull-Up, 40 total reps), write Sets as
//  "40 total" instead of a rep scheme — Weights and Reps still list one
//  value per set actually done, in order:
//
//    2026-01-05 | 2     | Pull A | Pull-Up     | 40 total  | 0/0/0/0/0/0/0        | 6/5/5/4/4/3/3
//
//  This becomes a saved rep-total target on the exercise (alongside its
//  saved rep schemes), matching however it's set up in the Exercises tab.
//
//  For a bodyweight exercise, Weights means ADDED weight, same as live
//  logging: each set's weight is resolved as the most recent BodyWeightEntry
//  on or before that row's date, plus the added weight given. Write 0 for no
//  added weight beyond bodyweight.
//
//  An optional Equipment column tags the exercise: write "Bodyweight" to
//  flag it bodyweight (same effect as the Exercises-tab toggle — this is
//  what makes Weights mean added weight per above), or any other name to tag
//  it with that equipment, e.g. "Trap Bar" or "Cable Machine". A name that
//  doesn't already exist in the Equipment tab still imports fine — it
//  creates a new placeholder there (weight TBD, 2-sided) instead of being
//  dropped, so just fill in its real weight afterward.
//
//  An optional Notes column is imported as plain text onto that exercise's
//  own Notes field (Exercises tab) — only applies to real exercise rows,
//  since rest-day activities and body weight logs have no notes field.
//
//  For a rest-day activity (a walk, yoga, etc. — not a logged exercise),
//  write Day as "Rest" (requires a Day column). Exercise becomes the
//  activity's name; Reps optionally holds a distance (e.g. "3.1mi", "5 km"
//  — plain "mi" if left as just a number); Sets/Weights are unused:
//
//    2026-01-06 |       | Rest   | Walk        |           |                      | 3.1mi
//
//  This creates both a standalone rest-day activity entry and a matching
//  History entry, and counts toward the rest-bank streak, same as logging
//  it live from a Rest day.
//
//  For a body weight log (not a real exercise), write Exercise as "Weight"
//  — the weight itself goes in Reps, not Weights; Sets/Weights are unused:
//
//    2026-01-06 |       |        | Weight      |           |                      | 172.5
//
//  Creates a BodyWeightEntry for that date — same one the Weight tab and
//  live logging both read/write. A date that already has an entry (from
//  before this import, or an earlier "Weight" row in the same file) is
//  skipped rather than duplicated.
//
//  Phase is that phase's number; Day is the day's name (e.g. "Push A"),
//  matched case-insensitively against that phase's days. If either is
//  missing or doesn't match an existing Phase/PhaseDay, the row still
//  imports — it just falls back to an unattributed "Imported" entry (or
//  keeps whatever Day text was given as the label, if only the phase match
//  failed).
//
//  If the file's Day column shows a repeating pattern (e.g. Push A / Pull A
//  / Legs A / Rest, over and over), the importer detects the most recently
//  completed cycle and drafts a whole Phase from it — HistoryView presents
//  that draft (in the normal Phase Builder screen) for review/editing
//  before anything is actually imported. Saving it retroactively attributes
//  every exercise row whose Day matches one of that Phase's days, not just
//  the last cycle's — so a consistently-labeled import ends up as one
//  continuous Phase covering its whole history, not just its tail end.
//  Rest-day activity rows are attributed the same way, but only from
//  whichever date is the earliest exercise row this import actually
//  attributed to that Phase — a "Rest" row logged before the Phase's own
//  history begins (per this import) isn't swept in just because its label
//  happens to match too. A file with no Day column, or no repeated
//  pattern, just imports the old way.
//

import Foundation
import SwiftData

enum ImportEngine {
    enum ImportedRowKind {
        case exercise(goalType: GoalType, targetReps: [Int], weights: [Double], reps: [Int])
        /// Sets == "rest" — Weights holds an optional distance (e.g. "3.1mi").
        case restActivity(distance: Double?, distanceUnit: String)
        /// Exercise == "Weight" — a body weight log, not a real exercise.
        /// The weight itself is read from the Reps column (Sets/Weights are
        /// unused), so a body-weight-only row doesn't need real Sets data.
        case bodyWeight(weight: Double)
    }

    struct ImportedEntry {
        let date: Date
        let exerciseName: String   // exercise name, or the activity's name for a rest row
        let kind: ImportedRowKind
        let phaseNumber: Int?      // optional "Phase" column
        let dayLabel: String?      // optional "Day" column, e.g. "Push A"
        let equipmentName: String? // optional "Equipment" column — "Bodyweight" or a Bar name
        /// Optional "Notes" column, imported as plain text onto the matching
        /// exercise's ExerciseDef.notes — there's no per-log notes field, so
        /// this only applies to real exercise rows, not rest/weight rows.
        let notes: String?

        init(date: Date, exerciseName: String, kind: ImportedRowKind, phaseNumber: Int?,
             dayLabel: String?, equipmentName: String?, notes: String? = nil) {
            self.date = date
            self.exerciseName = exerciseName
            self.kind = kind
            self.phaseNumber = phaseNumber
            self.dayLabel = dayLabel
            self.equipmentName = equipmentName
            self.notes = notes
        }
    }

    /// "Rest" and "Rest Day" both mark a rest-day row — the app's own
    /// backfilled no-activity sessions are labeled "Rest Day"
    /// (TheJymApp.backfillRestDays), so a user filling in history by hand
    /// naturally types that instead of the bare "Rest" the import docs ask
    /// for.
    private static func isRestLabel(_ label: String) -> Bool {
        let lower = label.lowercased()
        return lower == "rest" || lower == "rest day"
    }

    struct ImportResult {
        var sessionsCreated: Int
        var setsImported: Int
        var bodyWeightEntriesCreated: Int = 0
    }

    // MARK: - Last-cycle pattern detection (import -> auto-drafted Phase)

    struct DetectedExercise {
        let name: String
        let goalType: GoalType
        let targetReps: [Int]      // fixedSets only
        let weights: [Double]      // that occurrence's actual weights, seeded as the starting suggestion
    }

    struct DetectedDay {
        let name: String
        let isRest: Bool
        let exercises: [DetectedExercise]   // empty for a rest day
    }

    /// Reconstructs the day-by-day training pattern from imported rows and
    /// returns the most recently completed cycle's day template, in
    /// chronological order (e.g. [Push A, Pull A, Legs A, Rest]) — each
    /// day's exercises are exactly what was logged the last time that day
    /// was trained, mirroring how Phase.cycleWalk finds cycle boundaries but
    /// walking backward from the newest date instead of forward.
    ///
    /// Requires a Day column with real values on at least one row (that's
    /// the only signal that identifies "which day is this") — returns nil
    /// if none of the rows carry a usable label, since there's nothing to
    /// detect a pattern from.
    static func detectLastCyclePattern(from rows: [ImportedEntry]) -> [DetectedDay]? {
        let labeled = rows.filter { $0.dayLabel != nil && !$0.dayLabel!.isEmpty }
        guard !labeled.isEmpty else { return nil }

        let cal = Calendar.current
        struct Key: Hashable { let day: Date; let label: String }
        var grouped: [Key: [ImportedEntry]] = [:]
        var order: [Key] = []
        for row in labeled {
            guard let label = row.dayLabel else { continue }
            let key = Key(day: cal.startOfDay(for: row.date), label: label)
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(row)
        }

        struct Occurrence { let date: Date; let label: String; let rows: [ImportedEntry] }
        let occurrences = order.map { key in Occurrence(date: key.day, label: key.label, rows: grouped[key] ?? []) }
            .sorted { $0.date < $1.date }
        guard !occurrences.isEmpty else { return nil }

        // Walk backward from the most recent occurrence until a TRAINING day
        // label repeats — that trailing run (put back in chronological
        // order) is the last full cycle. Rest is exempt from the repeat
        // check: a real split can (and often does) have more than one rest
        // day per cycle, so treating a second "Rest" as a cycle boundary
        // would truncate the pattern after the first training day pair.
        var lastCycle: [Occurrence] = []
        var seenLabels = Set<String>()
        for occurrence in occurrences.reversed() {
            let key = occurrence.label.lowercased()
            let isRest = isRestLabel(occurrence.label)
            if !isRest {
                if seenLabels.contains(key) { break }
                seenLabels.insert(key)
            }
            lastCycle.insert(occurrence, at: 0)
        }
        // A leading Rest run is left over from wrapping past the cycle
        // boundary (the rest day that followed the PREVIOUS cycle's last
        // training day) rather than part of this one — trim it so the
        // template starts on a real training day. A cyclic pattern has no
        // true "start", so beginning at whichever training day comes first
        // is just as valid as the original order.
        while let first = lastCycle.first, isRestLabel(first.label) {
            lastCycle.removeFirst()
        }
        guard !lastCycle.isEmpty else { return nil }

        return lastCycle.map { occurrence in
            let isRest = isRestLabel(occurrence.label)
            let exercises: [DetectedExercise] = occurrence.rows.compactMap { row in
                guard case .exercise(let goalType, let targetReps, let weights, _) = row.kind else { return nil }
                return DetectedExercise(name: row.exerciseName, goalType: goalType, targetReps: targetReps, weights: weights)
            }
            return DetectedDay(name: occurrence.label, isRest: isRest, exercises: exercises)
        }
    }

    /// Parses CSV (or tab-delimited — pasting straight out of a spreadsheet
    /// often carries tabs, not commas) text into rows, matching the header
    /// case-insensitively. Returns the parsed rows plus a count of data rows
    /// that didn't parse.
    static func parseRows(csv: String) -> (rows: [ImportedEntry], skipped: Int) {
        let lines = csv.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }).map(String.init)
        guard let headerLine = lines.first else { return ([], 0) }
        let delimiter: Character = headerLine.contains("\t") ? "\t" : ","
        let header = splitDelimitedLine(headerLine, delimiter: delimiter)
        let dataRows = lines.dropFirst()
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { splitDelimitedLine($0, delimiter: delimiter) }
        return parseFields(header: header, rows: Array(dataRows))
    }

    /// Parses an .xlsx workbook's first sheet the same way. Returns nil only
    /// if the file itself couldn't be read as a valid .xlsx at all.
    static func parseRows(xlsxData: Data) -> (rows: [ImportedEntry], skipped: Int)? {
        guard let grid = XLSXReader.readFirstSheetAsRows(data: xlsxData), let header = grid.first else { return nil }
        let dataRows = grid.dropFirst().filter { row in
            !row.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        return parseFields(header: header, rows: Array(dataRows))
    }

    /// Shared row-processing logic once a CSV/xlsx source has been reduced to
    /// a plain header row + data rows of string fields.
    private static func parseFields(header rawHeader: [String], rows: [[String]]) -> (rows: [ImportedEntry], skipped: Int) {
        let header = rawHeader.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let dateIdx = header.firstIndex(where: { $0.hasPrefix("date") }),
              let exerciseIdx = header.firstIndex(where: { $0.hasPrefix("exercise") }),
              let setsIdx = header.firstIndex(where: { $0.hasPrefix("set") }),
              let weightsIdx = header.firstIndex(where: { $0.hasPrefix("weight") }),
              let repsIdx = header.firstIndex(where: { $0.hasPrefix("rep") })
        else { return ([], 0) }
        // Optional — the import still works fine without any of these.
        let phaseIdx = header.firstIndex(where: { $0.hasPrefix("phase") })
        let dayIdx = header.firstIndex(where: { $0.hasPrefix("day") })
        let equipmentIdx = header.firstIndex(where: { $0.hasPrefix("equipment") })
        let notesIdx = header.firstIndex(where: { $0.hasPrefix("note") })

        var out: [ImportedEntry] = []
        var skipped = 0
        for fields in rows {
            guard fields.count > max(dateIdx, exerciseIdx, setsIdx, weightsIdx, repsIdx) else { skipped += 1; continue }
            let name = fields[exerciseIdx].trimmingCharacters(in: .whitespaces)
            let dateStr = fields[dateIdx].trimmingCharacters(in: .whitespaces)
            let setsStr = fields[setsIdx].trimmingCharacters(in: .whitespaces)
            let weightsStr = fields[weightsIdx].trimmingCharacters(in: .whitespaces)
            let repsStr = fields[repsIdx].trimmingCharacters(in: .whitespaces)

            guard !name.isEmpty, let date = parseDate(dateStr) else { skipped += 1; continue }

            let phaseStr = phaseIdx.flatMap { fields[safe: $0] }?.trimmingCharacters(in: .whitespaces)
            let dayStr = dayIdx.flatMap { fields[safe: $0] }?.trimmingCharacters(in: .whitespaces)
            let equipmentStr = equipmentIdx.flatMap { fields[safe: $0] }?.trimmingCharacters(in: .whitespaces)
            let notesStr = notesIdx.flatMap { fields[safe: $0] }?.trimmingCharacters(in: .whitespaces)
            let phaseNumber = phaseStr.flatMap { Int($0) }
            let matchedDayLabel = (dayStr?.isEmpty == false) ? dayStr : nil
            let matchedEquipment = (equipmentStr?.isEmpty == false) ? equipmentStr : nil
            let matchedNotes = (notesStr?.isEmpty == false) ? notesStr : nil

            // Exercise == "Weight" (case-insensitive) marks a body weight
            // log instead of a real exercise — the weight itself is read
            // from Reps (Sets/Weights are unused), so it can share the file
            // with real exercise rows without needing its own columns.
            if name.lowercased() == "weight" {
                if let weight = Double(repsStr) {
                    out.append(ImportedEntry(date: date, exerciseName: name,
                                             kind: .bodyWeight(weight: weight),
                                             phaseNumber: nil, dayLabel: nil, equipmentName: nil))
                } else {
                    skipped += 1
                }
                continue
            }

            // "Rest" or "Rest Day" (case-insensitive) in Day marks a rest-day
            // activity row instead of an exercise — Exercise is the
            // activity's name, Reps optionally holds a distance (e.g.
            // "3.1mi"), Sets/Weights are unused. Requires a Day column.
            if let dayStr, isRestLabel(dayStr) {
                let (distance, unit) = parseDistance(repsStr)
                out.append(ImportedEntry(date: date, exerciseName: name,
                                         kind: .restActivity(distance: distance, distanceUnit: unit),
                                         phaseNumber: phaseNumber, dayLabel: matchedDayLabel,
                                         equipmentName: nil))
                continue
            }

            // "40 total" (case-insensitive) marks this row as a rep-total
            // goal instead of a fixed rep scheme — everything else about
            // the row (Weights/Reps per set) works exactly the same.
            let goalType: GoalType
            let targetReps: [Int]
            if let target = parseRepTotalTarget(setsStr) {
                goalType = .repTotal(target: target)
                targetReps = []
            } else {
                goalType = .fixedSets
                targetReps = setsStr.split(separator: "/").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            }
            let weights = weightsStr.split(separator: "/").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            let reps = repsStr.split(separator: "/").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard !weights.isEmpty, weights.count == reps.count else { skipped += 1; continue }

            out.append(ImportedEntry(date: date, exerciseName: name,
                                     kind: .exercise(goalType: goalType, targetReps: targetReps, weights: weights, reps: reps),
                                     phaseNumber: phaseNumber, dayLabel: matchedDayLabel,
                                     equipmentName: matchedEquipment, notes: matchedNotes))
        }
        return (out, skipped)
    }

    /// Groups rows into one WorkoutSession per calendar day (further split if
    /// rows disagree on Phase/Day), one ExerciseLog per row, sets built from
    /// the row's Weights/Reps pairs in order. A row's Phase/Day, if given and
    /// matched, links the session to that real Phase/PhaseDay; otherwise it
    /// falls back to an unattributed "Imported" entry.
    /// `forcedPhase`, when given, overrides normal Phase-number matching for
    /// exercise rows — every exercise row is matched against `forcedPhase`'s
    /// own days by Day label alone (case-insensitive), regardless of what's
    /// in the row's Phase column, and attributed there whenever it matches.
    /// Used to retroactively attribute imported historical days to a Phase
    /// auto-drafted from the import itself, which obviously can't already
    /// appear in the file's Phase column. Rest-day activity rows get the
    /// same Day-label matching, but only from whichever date is the
    /// earliest exercise row this same import actually attributed to
    /// forcedPhase — a "Rest" row logged before that Phase's own history
    /// begins (per this import) isn't swept in just because its label
    /// happens to match too. Rows whose Day doesn't match any of
    /// forcedPhase's days (or, for rest rows, that fall before that
    /// earliest date) fall back to an unattributed "Imported" entry, same
    /// as always.
    /// A big historical import (hundreds of sessions, thousands of sets) run
    /// as one giant unbroken block risked the main thread going unresponsive
    /// long enough for iOS to background the app mid-import — since nothing
    /// was saved until one final `context.save()` at the very end, an
    /// interruption at any point lost the *entire* run, not just the tail.
    /// Saving and yielding every `checkpointInterval` day-groups keeps the
    /// run loop breathing (so the app is never seen as unresponsive) and
    /// makes partial progress durable if it's ever interrupted anyway.
    private static let checkpointInterval = 25

    @MainActor
    static func importIntoStore(_ rows: [ImportedEntry], context: ModelContext,
                                attributeTo forcedPhase: Phase? = nil) async -> ImportResult {
        let cal = Calendar.current
        let existingDefs = (try? context.fetch(FetchDescriptor<ExerciseDef>())) ?? []
        var knownDefs = Dictionary(uniqueKeysWithValues: existingDefs.map { ($0.name, $0) })
        let existingBars = (try? context.fetch(FetchDescriptor<Bar>())) ?? []
        var knownBars = Dictionary(uniqueKeysWithValues: existingBars.map { ($0.name.lowercased(), $0) })
        let existingPhases = (try? context.fetch(FetchDescriptor<Phase>())) ?? []
        var bodyWeights = ((try? context.fetch(FetchDescriptor<BodyWeightEntry>())) ?? [])
            .sorted { $0.date < $1.date }

        /// "Bodyweight" flags the exercise bodyweight; any other non-blank
        /// value names equipment to tag it with — an unrecognized name
        /// creates a new placeholder Bar (weight 0/"TBD", 2-sided) rather
        /// than being dropped, so the row still imports and the equipment
        /// just needs its real weight filled in later.
        func applyEquipment(_ equipmentName: String?, to exerciseName: String) {
            guard let equipmentName, !equipmentName.isEmpty else { return }
            let def = knownDefs[exerciseName] ?? {
                let newDef = ExerciseDef(name: exerciseName)
                context.insert(newDef)
                knownDefs[exerciseName] = newDef
                return newDef
            }()
            if equipmentName.lowercased() == "bodyweight" {
                def.isBodyweight = true
                return
            }
            let key = equipmentName.lowercased()
            if let bar = knownBars[key] {
                def.equipment = bar
            } else {
                let newBar = Bar(name: equipmentName, weight: 0, loadableSides: 2)
                context.insert(newBar)
                knownBars[key] = newBar
                def.equipment = newBar
            }
        }

        /// Most recent BodyWeightEntry on or before `date` — same resolution
        /// rule live logging uses, so an imported bodyweight row lines up
        /// with whatever was actually logged as of that date.
        func resolvedBodyweight(asOf date: Date) -> Double? {
            bodyWeights.last { $0.date <= date }?.weight
        }

        func matchPhaseDay(phaseNumber: Int?, dayLabel: String?) -> (Phase?, PhaseDay?) {
            if let forcedPhase {
                let day = dayLabel.flatMap { label in
                    forcedPhase.orderedDays.first { $0.name.localizedCaseInsensitiveCompare(label) == .orderedSame }
                }
                return day != nil ? (forcedPhase, day) : (nil, nil)
            }
            let phase = phaseNumber.flatMap { num in existingPhases.first { $0.number == num } }
            let day = phase.flatMap { p in
                dayLabel.flatMap { label in
                    p.orderedDays.first { $0.name.localizedCaseInsensitiveCompare(label) == .orderedSame }
                }
            }
            return (phase, day)
        }

        struct GroupKey: Hashable {
            let day: Date
            let phaseNumber: Int?
            let dayLabel: String?
        }
        let exerciseRows = rows.filter { if case .exercise = $0.kind { return true }; return false }
        let restRows = rows.filter { if case .restActivity = $0.kind { return true }; return false }
        let bodyWeightRows = rows.filter { if case .bodyWeight = $0.kind { return true }; return false }
        let grouped = Dictionary(grouping: exerciseRows) { row in
            GroupKey(day: cal.startOfDay(for: row.date), phaseNumber: row.phaseNumber, dayLabel: row.dayLabel)
        }

        var sessionsCreated = 0
        var setsImported = 0
        var bodyWeightEntriesCreated = 0

        // Processed before the exercise-row loop below (not just before it
        // in insertion order, but into the same `bodyWeights` array
        // resolvedBodyweight reads) so a "Weight" row earlier in the file
        // than a bodyweight exercise row it should back is actually visible
        // to that lookup. Skips a date that already has an entry (from
        // before this import, or an earlier "Weight" row in the same file)
        // rather than creating a duplicate for the same day.
        var knownBodyWeightDays = Set(bodyWeights.map { cal.startOfDay(for: $0.date) })
        for entry in bodyWeightRows.sorted(by: { $0.date < $1.date }) {
            guard case .bodyWeight(let weight) = entry.kind else { continue }
            let day = cal.startOfDay(for: entry.date)
            guard !knownBodyWeightDays.contains(day) else { continue }
            let bwEntry = BodyWeightEntry(date: entry.date, weight: weight)
            context.insert(bwEntry)
            bodyWeights.append(bwEntry)
            knownBodyWeightDays.insert(day)
            bodyWeightEntriesCreated += 1
        }
        bodyWeights.sort { $0.date < $1.date }

        for (groupIndex, (key, dayRows)) in grouped.sorted(by: { $0.key.day < $1.key.day }).enumerated() {
            if groupIndex > 0, groupIndex % checkpointInterval == 0 {
                try? context.save()
                await Task.yield()
            }
            let (matchedPhase, matchedDay) = matchPhaseDay(phaseNumber: key.phaseNumber, dayLabel: key.dayLabel)
            // An imported workout overrides a gap-filled "nothing happened"
            // Rest Day placeholder for this same date.
            WorkoutSession.removeBackfilledRestPlaceholder(on: key.day, context: context)
            let session = WorkoutSession(date: key.day, day: matchedDay,
                                         dayLabel: key.dayLabel ?? "Imported", cycleNumber: 0)
            session.phase = matchedPhase
            context.insert(session)
            sessionsCreated += 1

            for (order, entry) in dayRows.enumerated() {
                guard case .exercise(let goalType, let targetReps, let weights, let reps) = entry.kind else { continue }
                applyEquipment(entry.equipmentName, to: entry.exerciseName)
                // isBodyweight comes from an already-existing exercise, or
                // this row's own Equipment column if it said "Bodyweight".
                let isBW = knownDefs[entry.exerciseName]?.isBodyweight ?? false
                let log = ExerciseLog(exerciseName: entry.exerciseName, targetReps: targetReps,
                                      order: order, isBodyweight: isBW, goalType: goalType)
                log.session = session
                context.insert(log)

                // For a bodyweight exercise, Weights is ADDED weight (same
                // convention as live logging) — resolved against whatever
                // BodyWeightEntry was on record as of this row's date.
                let bw = isBW ? resolvedBodyweight(asOf: key.day) : nil
                for (i, pair) in zip(weights, reps).enumerated() {
                    let set: SetLog
                    if isBW {
                        set = SetLog(index: i, weight: pair.0 + (bw ?? 0), reps: pair.1,
                                    addedWeight: pair.0, bodyweightAtLog: bw)
                    } else {
                        set = SetLog(index: i, weight: pair.0, reps: pair.1)
                    }
                    set.exerciseLog = log
                    context.insert(set)
                    setsImported += 1
                }

                switch goalType {
                case .repTotal(let target):
                    if let def = knownDefs[entry.exerciseName] {
                        def.addRepTotalTarget(target)
                    } else {
                        let def = ExerciseDef(name: entry.exerciseName, repTotalTargets: [target])
                        context.insert(def)
                        knownDefs[entry.exerciseName] = def
                    }
                case .fixedSets:
                    if targetReps.isEmpty {
                        ExerciseDef.ensureAnyVariantExists(name: entry.exerciseName, knownDefs: &knownDefs, context: context)
                    } else {
                        ExerciseDef.ensureVariantExists(name: entry.exerciseName, targetReps: targetReps,
                                                        knownDefs: &knownDefs, context: context)
                    }
                }
                // Plain text onto the exercise's own Notes field — there's
                // no per-log notes field, so this is the closest match.
                if let notes = entry.notes, let def = knownDefs[entry.exerciseName] {
                    def.notes = notes
                }
            }
        }

        // "The first date in the importer with a phase" — earliest date
        // among this import's own exercise rows that actually match one of
        // forcedPhase's days by label (the same matching an exercise row
        // gets). Rest rows below are only retroactively attributed to
        // forcedPhase from that point forward — a "Rest" row logged before
        // this phase's own history actually begins (per this import)
        // shouldn't get swept in just because its label happens to match
        // the phase's Rest day too. Nil (so nothing qualifies) if no
        // exercise row here ends up attributed to forcedPhase at all.
        let earliestAttributedExerciseDate: Date? = forcedPhase.flatMap { phase in
            exerciseRows
                .filter { row in
                    guard let label = row.dayLabel else { return false }
                    return phase.orderedDays.contains { $0.name.localizedCaseInsensitiveCompare(label) == .orderedSame }
                }
                .map(\.date)
                .min()
        }

        // Rest-day activities: each row becomes both a standalone
        // RestDayActivity record and a matching WorkoutSession/ExerciseLog/
        // SetLog, so it shows up in History and counts toward the rest-bank
        // streak — mirrors live logging (RestDayLogView.logActivity()).
        // Phase is left nil (same as live logging, so it never shifts the
        // training cycle) UNLESS forcedPhase is retroactively attributing
        // this whole import to a Phase AND this row's date is on/after
        // earliestAttributedExerciseDate — rest days don't participate in
        // cycle-slot math either way, so attributing them there too is safe
        // once there's actual attributed history for them to belong
        // alongside. Deliberately does NOT touch the Exercises tab — a rest
        // activity isn't an exercise in the import file, so it shouldn't
        // show up as one there.
        for (restIndex, entry) in restRows.enumerated() {
            if restIndex > 0, restIndex % checkpointInterval == 0 {
                try? context.save()
                await Task.yield()
            }
            guard case .restActivity(let distance, let unit) = entry.kind else { continue }
            context.insert(RestDayActivity(date: entry.date, name: entry.exerciseName,
                                           distance: distance, distanceUnit: unit))

            let (matchedRestPhase, matchedDay) = matchPhaseDay(phaseNumber: entry.phaseNumber, dayLabel: entry.dayLabel)
            let displayName = distance.map { "\(entry.exerciseName) (\(Formatters.trim($0)) \(unit))" } ?? entry.exerciseName
            // A logged rest-day activity overrides a gap-filled no-activity
            // Rest Day placeholder for this same date.
            WorkoutSession.removeBackfilledRestPlaceholder(on: entry.date, context: context)
            let session = WorkoutSession(date: entry.date, day: matchedDay,
                                         dayLabel: entry.dayLabel ?? "Rest Day", cycleNumber: 0)
            let restRowQualifiesForForcedPhase = forcedPhase != nil
                && earliestAttributedExerciseDate.map { entry.date >= $0 } == true
            session.phase = restRowQualifiesForForcedPhase ? matchedRestPhase : nil
            context.insert(session)
            sessionsCreated += 1
            let log = ExerciseLog(exerciseName: displayName, targetReps: [], order: 0)
            log.session = session
            context.insert(log)
            let set = SetLog(index: 0, weight: 0, reps: 1)
            set.exerciseLog = log
            context.insert(set)
            setsImported += 1
        }

        try? context.save()
        return ImportResult(sessionsCreated: sessionsCreated, setsImported: setsImported,
                           bodyWeightEntriesCreated: bodyWeightEntriesCreated)
    }

    // MARK: - Delimited line splitting (quote-aware, handles embedded
    // delimiters + "" escapes; delimiter is comma for real CSV, tab for
    // spreadsheet-paste-style text)

    private static func splitDelimitedLine(_ line: String, delimiter: Character) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        current.append("\"")
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    current.append(c)
                }
            } else if c == "\"" {
                inQuotes = true
            } else if c == delimiter {
                fields.append(current)
                current = ""
            } else {
                current.append(c)
            }
            i += 1
        }
        fields.append(current)
        return fields
    }

    // MARK: - Date parsing (tries several common spreadsheet export formats)

    private static let dateFormatters: [DateFormatter] = {
        ["yyyy-MM-dd", "M/d/yyyy", "MM/dd/yyyy", "M/d/yy", "MMM d, yyyy", "MMMM d, yyyy", "d MMM yyyy"]
            .map { fmt in
                let f = DateFormatter()
                f.dateFormat = fmt
                f.locale = Locale(identifier: "en_US_POSIX")
                f.timeZone = .current
                return f
            }
    }()

    /// Recognizes a "Sets" field written as a rep-total goal, e.g. "40
    /// total" or "40 Total" — anything else (a slash-separated scheme, or
    /// blank) isn't a rep total.
    private static func parseRepTotalTarget(_ raw: String) -> Int? {
        let lower = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard lower.hasSuffix("total") else { return nil }
        let numberPart = lower.dropLast("total".count).trimmingCharacters(in: .whitespaces)
        guard let target = Int(numberPart), target > 0 else { return nil }
        return target
    }

    /// Parses a rest-activity row's optional Reps-column distance, e.g.
    /// "3", "3.1mi", "5 km" — a leading number plus an optional unit suffix
    /// (defaults to "mi" if no unit, or if the whole field is blank).
    private static func parseDistance(_ raw: String) -> (Double?, String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return (nil, "mi") }
        let numberPart = trimmed.prefix { $0.isNumber || $0 == "." }
        let unitPart = trimmed.dropFirst(numberPart.count).trimmingCharacters(in: .whitespaces)
        return (Double(numberPart), unitPart.isEmpty ? "mi" : unitPart)
    }

    private static func parseDate(_ s: String) -> Date? {
        if let iso = ISO8601DateFormatter().date(from: s) { return iso }
        for f in dateFormatters {
            if let d = f.date(from: s) { return d }
        }
        // .xlsx stores dates as day-count serials (no formatting info
        // survives once we've read just the cell value) — usually a bare
        // integer, but some exporters write it as a float like "45700.0".
        // excelSerialDate resolves the day count in UTC (deliberately —
        // it's a timezone-agnostic count), but everything downstream groups
        // sessions by Calendar.current (local) day. West of Greenwich, a
        // UTC-midnight Date falls in the LOCAL calendar on the day before,
        // shifting every serial-dated row back a day — re-anchor to the
        // same Y/M/D as a local-midnight Date so it survives that grouping.
        if let serial = serialInt(from: s), let utcDate = excelSerialDate(serial) {
            let comps = utcCalendar.dateComponents([.year, .month, .day], from: utcDate)
            return Calendar.current.date(from: comps)
        }
        return nil
    }

    /// Parses a spreadsheet numeric cell value as a whole-number serial,
    /// accepting both a bare integer ("45700") and the float form some
    /// exporters use ("45700.0").
    private static func serialInt(from s: String) -> Int? {
        if let i = Int(s) { return i }
        if let d = Double(s) { return Int(d.rounded()) }
        return nil
    }

    private static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    /// Excel/Sheets store dates as days since Dec 30, 1899. Only treats
    /// plausible date-range numbers this way — real rep/weight values never
    /// reach this range.
    private static func excelSerialDate(_ serial: Int) -> Date? {
        guard serial > 20_000, serial < 60_000 else { return nil }
        guard let epoch = utcCalendar.date(from: DateComponents(year: 1899, month: 12, day: 30)) else { return nil }
        return utcCalendar.date(byAdding: .day, value: serial, to: epoch)
    }
}
