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
//  what makes Weights mean added weight per above); "Dumbbell"/"Dumbbells"
//  or "Band"/"Bands" route to the Equipment tab's own Dumbbell/Bands weight
//  tables instead of creating a bar; or any other name to tag it with that
//  equipment, e.g. "Trap Bar" or "Cable Machine". A name that doesn't
//  already exist in the Equipment tab still imports fine — it creates a new
//  placeholder there (weight TBD, 2-sided) instead of being dropped, so just
//  fill in its real weight afterward.
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
//  An optional Cycle column says which pass of the phase's template this
//  row belongs to (e.g. 3 for the third time through) — nothing about it is
//  ever auto-detected or counted by walking the file's pattern. Leave it
//  blank and the row still attributes to its Phase/Day (as long as that
//  Day name isn't ambiguous — see below), but its cycle number stays
//  untagged (0, invisible to cycle tracking) until corrected, e.g. by
//  editing Cycle # for that day in History. Stating it explicitly is the
//  only way to fill a slot on a split with more than one same-named day a
//  cycle (most often two separate Rest days), since there's no other way to
//  tell which occurrence a given row belongs to.
//
//  If the file's Day column shows a repeating pattern (e.g. Push A / Pull A
//  / Legs A / Rest, over and over), the importer detects the most recently
//  completed cycle and drafts a whole Phase from it — HistoryView presents
//  that draft (in the normal Phase Builder screen) for review/editing
//  before anything is actually imported. Saving it retroactively attributes
//  every row whose OWN Phase column names that Phase's actual number (e.g.
//  a first-ever Phase, auto-numbered 1, only picks up rows that already say
//  "1"), matched to that Phase's days by Day label — a file with no Phase
//  column, or numbers that don't happen to match the number the new Phase
//  gets assigned, still drafts the Phase template fine, it just won't have
//  any history attributed to it. Rest-day activity rows are attributed the
//  same way, but only from whichever date is the earliest exercise row this
//  import actually attributed to that Phase — a "Rest" row logged before
//  the Phase's own history begins (per this import) isn't swept in just
//  because its own Phase number matches too. A file with no Day column, or
//  no repeated pattern, just imports the old way.
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
        /// Optional "Cycle" column — which pass of the phase's template this
        /// row belongs to. When given, overrides importIntoStore's own
        /// auto-computed cycle number for this row's session; when nil, the
        /// auto-computed value is used, same as before this column existed.
        let cycleNumber: Int?
        /// Optional "Notes" column, imported as plain text onto the matching
        /// exercise's ExerciseDef.notes — there's no per-log notes field, so
        /// this only applies to real exercise rows, not rest/weight rows.
        let notes: String?
        /// Per-session facts the enriched export carries and nothing else
        /// can reconstruct. nil from an older file, which is why every one
        /// is optional rather than defaulted.
        var durationSeconds: Int?
        var isDeload = false
        var isBonusSession = false
        /// Per-set, index-aligned with the row's weights. Empty from an
        /// older file, in which case bodyweightAtLog is resolved from
        /// weigh-ins as before.
        var addedWeights: [Double?] = []
        var bodyweightAtLogs: [Double?] = []
        var achievedRank: Int?
        var missedTarget = false
        var selectedWeightAdjustment: Double?
        /// The LOG's own bodyweight flag. Previously inferred from the
        /// ExerciseDef, which is right for a fresh log but wrong for one
        /// recorded before the exercise was flagged.
        var logIsBodyweight: Bool?

        init(date: Date, exerciseName: String, kind: ImportedRowKind, phaseNumber: Int?,
             dayLabel: String?, equipmentName: String?, cycleNumber: Int? = nil, notes: String? = nil,
             durationSeconds: Int? = nil, isDeload: Bool = false, isBonusSession: Bool = false,
             addedWeights: [Double?] = [], bodyweightAtLogs: [Double?] = [],
             achievedRank: Int? = nil, missedTarget: Bool = false,
             selectedWeightAdjustment: Double? = nil, logIsBodyweight: Bool? = nil) {
            self.achievedRank = achievedRank
            self.missedTarget = missedTarget
            self.selectedWeightAdjustment = selectedWeightAdjustment
            self.logIsBodyweight = logIsBodyweight
            self.durationSeconds = durationSeconds
            self.isDeload = isDeload
            self.isBonusSession = isBonusSession
            self.addedWeights = addedWeights
            self.bodyweightAtLogs = bodyweightAtLogs
            self.date = date
            self.exerciseName = exerciseName
            self.kind = kind
            self.phaseNumber = phaseNumber
            self.dayLabel = dayLabel
            self.equipmentName = equipmentName
            self.cycleNumber = cycleNumber
            self.notes = notes
        }
    }

    /// "Rest" and "Rest Day" both mark a rest-day row — the app's own
    /// backfilled no-activity sessions are labeled "Rest Day"
    /// (TheJymApp.backfillRestDays), so a user filling in history by hand
    /// naturally types that instead of the bare "Rest" the import docs ask
    /// for.
    /// "Weight", "Body Weight", "Bodyweight", "Body weight (lbs)" — any of
    /// the spellings the app or a hand-made file has used for a weigh-in
    /// row. Deliberately tolerant: a false positive here needs the word
    /// "weight" to be the WHOLE exercise name, which no real exercise is.
    static func isBodyWeightLabel(_ name: String) -> Bool {
        let n = name.lowercased().trimmingCharacters(in: .whitespaces)
        return n == "weight" || n == "body weight" || n == "bodyweight"
            || n.hasPrefix("body weight") || n.hasPrefix("bodyweight")
    }

    private static func isRestLabel(_ label: String) -> Bool {
        let lower = label.lowercased()
        return lower == "rest" || lower == "rest day"
    }

    /// Why rows didn't import. A bare total is what let 24 silently-dropped
    /// weigh-ins look like a rounding detail instead of a bug.
    struct SkipReasons: Equatable {
        var shortRow = 0          // no Date or Exercise cell at all
        var missingName = 0
        var unparseableDate = 0
        var unreadableBodyWeight = 0
        /// An exercise row whose Weights/Reps don't line up — no weights,
        /// or a different count of each.
        var unusableSets = 0
        /// Parsed fine, but dated outside the requested range. Counted
        /// rather than silently dropped: these are the rows a date floor
        /// is deliberately excluding, and leaving them out of the
        /// accounting made 20 pre-floor weigh-ins look like data loss.
        var outOfRange = 0
        var total: Int {
            shortRow + missingName + unparseableDate + unreadableBodyWeight
                + unusableSets + outOfRange
        }
        /// Human-readable, non-zero reasons only.
        var breakdown: [(String, Int)] {
            [("Row too short", shortRow), ("No exercise name", missingName),
             ("Unreadable date", unparseableDate),
             ("Unreadable body weight", unreadableBodyWeight),
             ("Weights/reps don't match", unusableSets),
             ("Outside the date range", outOfRange)].filter { $0.1 > 0 }
        }
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

    // MARK: - Plain template parsing (Day/Exercise/Set -> day drafts, no history)

    /// Parses a plain phase-template file — just Day, Exercise, and Set
    /// columns (any order, header matched case-insensitively; an optional
    /// Weight column seeds starting weights). No Date/Weights/Reps needed,
    /// since this describes what a cycle SHOULD look like rather than being
    /// reconstructed from logged history:
    ///
    ///   Day     | Exercise    | Set
    ///   Upper A | Bench Press | 5/5/5/3/3/3
    ///   Upper A | Barbell Row | 8/8/8/8
    ///   Rest    |             |
    ///   Lower A | Back Squat  | 5/5/5/3/3
    ///
    /// Set works the same as the full format's Sets column: a slash-
    /// separated rep scheme, or "40 total" for a rep-total goal. "Rest" (or
    /// "Rest Day") in Day marks a rest day — Exercise/Set are ignored.
    ///
    /// Rows are grouped into days by walking the file in order: a run of
    /// consecutive rows sharing the same Day label becomes that day's
    /// exercise list; a different (or repeated) label starts a new day —
    /// this is what lets the same label recur later in the file (e.g. a
    /// second, separate Rest day) without merging into an earlier
    /// occurrence, something date-based detectLastCyclePattern gets from
    /// chronological order but this format has no dates to offer.
    ///
    /// Returns nil if the file doesn't have this shape — no Day/Exercise/Set
    /// columns, or it also has a Date column (that's the full historical
    /// format instead, handled by parseRows/detectLastCyclePattern).
    static func parseTemplateRows(csv: String) -> [DetectedDay]? {
        let lines = csv.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }).map(String.init)
        guard let headerLine = lines.first else { return nil }
        let delimiter: Character = headerLine.contains("\t") ? "\t" : ","
        let header = splitDelimitedLine(headerLine, delimiter: delimiter)
        let dataRows = lines.dropFirst()
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { splitDelimitedLine($0, delimiter: delimiter) }
        return parseTemplateFields(header: header, rows: Array(dataRows))
    }

    /// Parses an .xlsx workbook's first sheet the same way. Returns nil both
    /// when the file itself can't be read as a valid .xlsx AND when it
    /// doesn't have this format's shape — callers that need to tell those
    /// apart should fall back to parseRows(xlsxData:) and inspect its own
    /// nil/empty-rows result instead.
    static func parseTemplateRows(xlsxData: Data) -> [DetectedDay]? {
        guard let grid = XLSXReader.readFirstSheetAsRows(data: xlsxData), let header = grid.first else { return nil }
        let dataRows = grid.dropFirst().filter { row in
            !row.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        return parseTemplateFields(header: header, rows: Array(dataRows))
    }

    private static func parseTemplateFields(header rawHeader: [String], rows: [[String]]) -> [DetectedDay]? {
        let header = rawHeader.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let dayIdx = header.firstIndex(where: { $0.hasPrefix("day") }),
              let exerciseIdx = header.firstIndex(where: { $0.hasPrefix("exercise") }),
              let setIdx = header.firstIndex(where: { $0.hasPrefix("set") }),
              !header.contains(where: { $0.hasPrefix("date") })
        else { return nil }
        let weightIdx = header.firstIndex(where: { $0.hasPrefix("weight") })

        struct TemplateRow { let dayLabel: String; let exercise: DetectedExercise? }
        var parsedRows: [TemplateRow] = []
        for fields in rows {
            guard fields.count > max(dayIdx, exerciseIdx, setIdx) else { continue }
            let dayLabel = fields[dayIdx].trimmingCharacters(in: .whitespaces)
            guard !dayLabel.isEmpty else { continue }

            if isRestLabel(dayLabel) {
                parsedRows.append(TemplateRow(dayLabel: "Rest", exercise: nil))
                continue
            }

            let exerciseName = fields[exerciseIdx].trimmingCharacters(in: .whitespaces)
            guard !exerciseName.isEmpty else { continue }
            let setStr = fields[setIdx].trimmingCharacters(in: .whitespaces)

            let goalType: GoalType
            let targetReps: [Int]
            if let target = parseRepTotalTarget(setStr) {
                goalType = .repTotal(target: target)
                targetReps = []
            } else {
                targetReps = setStr.split(separator: "/").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                guard !targetReps.isEmpty else { continue }
                goalType = .fixedSets
            }
            let weights = weightIdx.flatMap { fields[safe: $0] }?
                .split(separator: "/").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) } ?? []

            parsedRows.append(TemplateRow(
                dayLabel: dayLabel,
                exercise: DetectedExercise(name: exerciseName, goalType: goalType, targetReps: targetReps, weights: weights)))
        }
        guard !parsedRows.isEmpty else { return nil }

        var days: [DetectedDay] = []
        for row in parsedRows {
            guard let exercise = row.exercise else {
                days.append(DetectedDay(name: "Rest", isRest: true, exercises: []))
                continue
            }
            if let last = days.last, !last.isRest, last.name.localizedCaseInsensitiveCompare(row.dayLabel) == .orderedSame {
                days[days.count - 1] = DetectedDay(name: last.name, isRest: false, exercises: last.exercises + [exercise])
            } else {
                days.append(DetectedDay(name: row.dayLabel, isRest: false, exercises: [exercise]))
            }
        }
        return days
    }

    // MARK: - Full historical parsing (Date/Exercise/Sets/Weights/Reps -> logged history)

    /// Parses CSV (or tab-delimited — pasting straight out of a spreadsheet
    /// often carries tabs, not commas) text into rows, matching the header
    /// case-insensitively. Returns the parsed rows plus a count of data rows
    /// that didn't parse.
    static func parseRows(csv: String) -> (rows: [ImportedEntry], skipped: SkipReasons) {
        let lines = csv.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }).map(String.init)
        guard let headerLine = lines.first else { return ([], SkipReasons()) }
        let delimiter: Character = headerLine.contains("\t") ? "\t" : ","
        let header = splitDelimitedLine(headerLine, delimiter: delimiter)
        let dataRows = lines.dropFirst()
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { splitDelimitedLine($0, delimiter: delimiter) }
        return parseFields(header: header, rows: Array(dataRows))
    }

    /// Parses an .xlsx workbook's first sheet the same way. Returns nil only
    /// if the file itself couldn't be read as a valid .xlsx at all.
    static func parseRows(xlsxData: Data) -> (rows: [ImportedEntry], skipped: SkipReasons)? {
        guard let grid = XLSXReader.readFirstSheetAsRows(data: xlsxData), let header = grid.first else { return nil }
        let dataRows = grid.dropFirst().filter { row in
            !row.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        return parseFields(header: header, rows: Array(dataRows))
    }

    /// Shared row-processing logic once a CSV/xlsx source has been reduced to
    /// a plain header row + data rows of string fields.
    private static func parseFields(header rawHeader: [String], rows: [[String]],
                                    restActivityNames: Set<String> = [],
                                    from: Date? = nil, through: Date? = nil,
                                    cal: Calendar = .current) -> (rows: [ImportedEntry], skipped: SkipReasons) {
        let header = rawHeader.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let dateIdx = header.firstIndex(where: { $0.hasPrefix("date") }),
              let exerciseIdx = header.firstIndex(where: { $0.hasPrefix("exercise") }),
              let setsIdx = header.firstIndex(where: { $0.hasPrefix("set") }),
              let weightsIdx = header.firstIndex(where: { $0.hasPrefix("weight") }),
              let repsIdx = header.firstIndex(where: { $0.hasPrefix("rep") })
        else { return ([], SkipReasons()) }
        // Optional — the import still works fine without any of these.
        let phaseIdx = header.firstIndex(where: { $0.hasPrefix("phase") })
        let dayIdx = header.firstIndex(where: { $0.hasPrefix("day") })
        let equipmentIdx = header.firstIndex(where: { $0.hasPrefix("equipment") })
        let cycleIdx = header.firstIndex(where: { $0.hasPrefix("cycle") })
        let notesIdx = header.firstIndex(where: { $0.hasPrefix("note") })
        // Enriched-export columns. All optional: a file without them
        // imports exactly as before.
        let durationIdx = header.firstIndex(where: { $0.hasPrefix("duration") })
        let deloadIdx = header.firstIndex(where: { $0.hasPrefix("deload") })
        let bonusIdx = header.firstIndex(where: { $0.hasPrefix("bonus") })
        let addedIdx = header.firstIndex(where: { $0.hasPrefix("addedweight") })
        let bwAtIdx = header.firstIndex(where: { $0.hasPrefix("bodyweightatlog") })
        let rankIdx = header.firstIndex(where: { $0.hasPrefix("rank") })
        let missedIdx = header.firstIndex(where: { $0.hasPrefix("missed") })
        let weightAdjIdx = header.firstIndex(where: { $0.hasPrefix("weightadj") })
        let logBWIdx = header.firstIndex(where: { $0.hasPrefix("logbodyweight") })
        let unitIdx = header.firstIndex(where: { $0 == "unit" })

        var out: [ImportedEntry] = []
        var reasons = SkipReasons()
        for fields in rows {
            // Only DATE and EXERCISE are structurally required. Sets,
            // Weights and Reps are read positionally if present and
            // treated as blank if not.
            //
            // This used to demand a cell for every declared column, which
            // silently dropped every weigh-in the app itself exports:
            // XLSXExport omits .blank cells entirely (`case .blank:
            // continue`), and XLSXReader sizes a row to its last populated
            // column — so "Body Weight" rows, which leave Sets and Reps
            // blank, come back as 4 cells against a 5-column header and
            // failed `count > repsIdx` before the body-weight branch below
            // could ever run.
            guard fields.count > max(dateIdx, exerciseIdx) else { reasons.shortRow += 1; continue }
            func cell(_ idx: Int) -> String {
                (fields[safe: idx] ?? "").trimmingCharacters(in: .whitespaces)
            }
            let name = cell(exerciseIdx)
            let dateStr = cell(dateIdx)
            let setsStr = cell(setsIdx)
            let weightsStr = cell(weightsIdx)
            let repsStr = cell(repsIdx)

            guard !name.isEmpty else { reasons.missingName += 1; continue }
            guard let date = parseDate(dateStr) else { reasons.unparseableDate += 1; continue }
            // Range-filtered HERE, not by the caller afterwards, so the
            // skip tally and the imported tally describe the same
            // population. Filtering later made a whole-file skip count sit
            // next to an in-range import count, and the two didn't foot.
            let dayOf = cal.startOfDay(for: date)
            if let from, dayOf < cal.startOfDay(for: from) { reasons.outOfRange += 1; continue }
            if let through, dayOf > cal.startOfDay(for: through) { reasons.outOfRange += 1; continue }

            let phaseStr = phaseIdx.flatMap { fields[safe: $0] }?.trimmingCharacters(in: .whitespaces)
            let dayStr = dayIdx.flatMap { fields[safe: $0] }?.trimmingCharacters(in: .whitespaces)
            let equipmentStr = equipmentIdx.flatMap { fields[safe: $0] }?.trimmingCharacters(in: .whitespaces)
            let cycleStr = cycleIdx.flatMap { fields[safe: $0] }?.trimmingCharacters(in: .whitespaces)
            let notesStr = notesIdx.flatMap { fields[safe: $0] }?.trimmingCharacters(in: .whitespaces)
            let phaseNumber = phaseStr.flatMap { parseFlexibleInt($0) }
            let matchedDayLabel = (dayStr?.isEmpty == false) ? dayStr : nil
            let matchedEquipment = (equipmentStr?.isEmpty == false) ? equipmentStr : nil
            let explicitCycleNumber = cycleStr.flatMap { parseFlexibleInt($0) }
            let matchedNotes = (notesStr?.isEmpty == false) ? notesStr : nil

            // A body-weight row instead of a real exercise. Two spellings
            // and two column positions, because the app's own export and
            // the older hand-made files disagree on both:
            //
            //   name   "Weight" (the old CSV convention) or "Body Weight"
            //          (what SettingsView.historySheetRows actually writes)
            //   value  Weights (where the export puts it) falling back to
            //          Reps (where the old convention put it)
            //
            // Matching only "weight" exactly sent every exported weigh-in
            // down the exercise path; fixing the name alone would then have
            // made them SKIP, since the export leaves Reps blank. Both
            // halves have to move together.
            if isBodyWeightLabel(name) {
                if let weight = Double(weightsStr) ?? Double(repsStr) {
                    out.append(ImportedEntry(date: date, exerciseName: name,
                                             kind: .bodyWeight(weight: weight),
                                             phaseNumber: nil, dayLabel: nil, equipmentName: nil))
                } else {
                    reasons.unreadableBodyWeight += 1
                }
                continue
            }

            // A row the user has confirmed is really a rest-day activity.
            // The Day-column test below can't fire on an exported History
            // sheet (it has no Day column), so a walk would otherwise
            // import as a lifting log and contaminate hasLiftingLog, both
            // streaks, the Walk column and the rest bank. Distance comes
            // from Weights, which is where TodayView.logActivity puts it
            // (one SetLog, weight = distance, reps = 1).
            if restActivityNames.contains(name.lowercased()) {
                var (distance, unit) = parseDistance(weightsStr.isEmpty ? repsStr : weightsStr)
                // An explicit Unit column wins. Without it every activity
                // was assumed "mi", which silently dropped a km walk from
                // every miles figure on the Stats page.
                if let unitIdx, case let u = cell(unitIdx), !u.isEmpty { unit = u }
                out.append(ImportedEntry(date: date, exerciseName: name,
                                         kind: .restActivity(distance: distance, distanceUnit: unit),
                                         phaseNumber: phaseNumber, dayLabel: matchedDayLabel,
                                         equipmentName: nil))
                continue
            }

            // "Rest" or "Rest Day" (case-insensitive) in Day marks a rest-day
            // activity row instead of an exercise — Exercise is the
            // activity's name, Reps optionally holds a distance (e.g.
            // "3.1mi"), Sets/Weights are unused. Requires a Day column.
            if let dayStr, isRestLabel(dayStr) {
                let (distance, unit) = parseDistance(repsStr)
                // Normalized to the canonical "Rest" regardless of which
                // isRestLabel spelling the file used — a built/matched
                // Phase's Rest day is always named exactly "Rest"
                // (PhaseBuilderView, HistoryView.dayDrafts), so matchPhaseDay's
                // exact-name comparison needs this row's label to match that,
                // not whatever variant ("Rest Day", etc.) the file wrote.
                // Otherwise the row still imports and still shows as a rest
                // activity, but never fills the Phase's Rest slot — silently
                // stalling its cycle count at "Cycle 1" no matter how much
                // history comes in.
                out.append(ImportedEntry(date: date, exerciseName: name,
                                         kind: .restActivity(distance: distance, distanceUnit: unit),
                                         phaseNumber: phaseNumber, dayLabel: "Rest",
                                         equipmentName: nil, cycleNumber: explicitCycleNumber))
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
            guard !weights.isEmpty, weights.count == reps.count else { reasons.unusableSets += 1; continue }

            /// "12//15" -> [12, nil, 15]: an empty slot means that set had
            /// no value, which is different from zero.
            func optionalDoubles(_ idx: Int?) -> [Double?] {
                guard let idx, case let text = cell(idx), !text.isEmpty else { return [] }
                return text.split(separator: "/", omittingEmptySubsequences: false)
                    .map { Double($0.trimmingCharacters(in: .whitespaces)) }
            }
            out.append(ImportedEntry(date: date, exerciseName: name,
                                     kind: .exercise(goalType: goalType, targetReps: targetReps, weights: weights, reps: reps),
                                     phaseNumber: phaseNumber, dayLabel: matchedDayLabel,
                                     equipmentName: matchedEquipment, cycleNumber: explicitCycleNumber, notes: matchedNotes,
                                     durationSeconds: durationIdx.flatMap { Int(cell($0)) },
                                     isDeload: deloadIdx.map { cell($0).lowercased().hasPrefix("y") } ?? false,
                                     isBonusSession: bonusIdx.map { cell($0).lowercased().hasPrefix("y") } ?? false,
                                     addedWeights: optionalDoubles(addedIdx),
                                     bodyweightAtLogs: optionalDoubles(bwAtIdx),
                                     achievedRank: rankIdx.flatMap { Int(cell($0)) },
                                     missedTarget: missedIdx.map { cell($0).lowercased().hasPrefix("y") } ?? false,
                                     selectedWeightAdjustment: weightAdjIdx.flatMap { Double(cell($0)) },
                                     logIsBodyweight: logBWIdx.map { cell($0).lowercased().hasPrefix("y") }))
        }
        return (out, reasons)
    }

    /// Groups rows into one WorkoutSession per calendar day (further split if
    /// rows disagree on Phase/Day), one ExerciseLog per row, sets built from
    /// the row's Weights/Reps pairs in order. A row's Phase/Day, if given and
    /// matched, links the session to that real Phase/PhaseDay; otherwise it
    /// falls back to an unattributed "Imported" entry.
    /// `forcedPhase`, when given, is the only phase a row can attribute to
    /// — but same as any other phase (see resolvePhase), only a row whose
    /// own Phase column explicitly names its number actually does, then
    /// matched against its days by Day label (case-insensitive). Used to
    /// retroactively attribute imported historical days to a Phase
    /// auto-drafted from the import itself, once the file's own Phase
    /// numbers happen to line up with whatever number that Phase is
    /// actually assigned (e.g. a first-ever Phase, auto-numbered 1, only
    /// picks up rows that say "1") — a file with no Phase column, or
    /// numbers that don't line up, attributes nothing to it. Rest-day
    /// activity rows get the same matching, but only from whichever date is
    /// the earliest exercise row this same import actually attributed to
    /// forcedPhase — a "Rest" row logged before that Phase's own history
    /// begins (per this import) isn't swept in just because its own Phase
    /// number matches too. A row whose Phase doesn't resolve, or whose Day
    /// doesn't match any of that phase's days, falls back to an
    /// unattributed "Imported" entry, same as always.
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

        /// A row only ever attributes to a phase it explicitly names — its
        /// own Phase column has to say so, every time, even when this whole
        /// import is being retroactively attributed to a `forcedPhase`
        /// freshly built from the file's own detected pattern: that only
        /// sweeps in a row whose Phase column names `forcedPhase`'s actual
        /// number (e.g. a first-ever Phase, auto-numbered 1, only picks up
        /// rows that say "1"). A file with no Phase column, or numbers that
        /// don't line up, attributes nothing — same as any other
        /// unattributed row, just never guessed at from a Day-label match
        /// alone.
        func resolvePhase(phaseNumber: Int?) -> Phase? {
            guard let phaseNumber else { return nil }
            if let forcedPhase {
                return phaseNumber == forcedPhase.number ? forcedPhase : nil
            }
            return existingPhases.first { $0.number == phaseNumber }
        }

        /// "Bodyweight" flags the exercise bodyweight; "Dumbbell"/"Dumbbells"
        /// ("Dumbell"/"Dumbells" too — common misspelling) or "Band"/"Bands"
        /// route to the Equipment tab's special Dumbbell/Bands weight tables
        /// (isDumbbell Bar rows named exactly "Dumbbells"/"Bands", the same
        /// ones EquipmentView.ensureDumbbellBar/ensureBandsBar create) rather
        /// than a plain weight+sides Bar — those two tables are keyed by
        /// name, not a physical bar, so a generic Bar entry there would be
        /// meaningless and would clutter the Bars section. Any other
        /// non-blank value names equipment to tag it with — an unrecognized
        /// name creates a new placeholder Bar (weight 0/"TBD", 2-sided)
        /// rather than being dropped, so the row still imports and the
        /// equipment just needs its real weight filled in later.
        func applyEquipment(_ equipmentName: String?, to exerciseName: String) {
            guard let equipmentName, !equipmentName.isEmpty else { return }
            let def = knownDefs[exerciseName] ?? {
                let newDef = ExerciseDef(name: exerciseName)
                context.insert(newDef)
                knownDefs[exerciseName] = newDef
                return newDef
            }()
            let key = equipmentName.lowercased()
            if key == "bodyweight" {
                def.isBodyweight = true
                return
            }
            func specialWeightTable(named canonicalName: String) -> Bar {
                let tableKey = canonicalName.lowercased()
                if let bar = knownBars[tableKey] { return bar }
                let bar = Bar(name: canonicalName, weight: 0, isDumbbell: true)
                context.insert(bar)
                knownBars[tableKey] = bar
                return bar
            }
            if ["dumbbell", "dumbbells", "dumbell", "dumbells"].contains(key) {
                def.equipment = specialWeightTable(named: "Dumbbells")
                return
            }
            if ["band", "bands"].contains(key) {
                def.equipment = specialWeightTable(named: "Bands")
                return
            }
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

        struct GroupKey: Hashable {
            let day: Date
            let phaseNumber: Int?
            let dayLabel: String?
            /// True for a synthetic gap-fill request (see gapFillRequests
            /// below) — keeps it from colliding in the lookup with a real
            /// row that happens to carry a nil/blank Day label.
            var isGapFill: Bool = false
        }
        let exerciseRows = rows.filter { if case .exercise = $0.kind { return true }; return false }
        let restRows = rows.filter { if case .restActivity = $0.kind { return true }; return false }
        let bodyWeightRows = rows.filter { if case .bodyWeight = $0.kind { return true }; return false }
        let grouped = Dictionary(grouping: exerciseRows) { row in
            GroupKey(day: cal.startOfDay(for: row.date), phaseNumber: row.phaseNumber, dayLabel: row.dayLabel)
        }

        // Any calendar day within a phase's own attributed date range (this
        // import's earliest to latest date actually matched to it, plus
        // whatever it already had logged before this import) that ends up
        // with no request of its own — no exercise, no rest activity — gets
        // filled in as a plain Rest day, same shape logPlainRestDay() uses
        // live (an ActiveRecovery credit + a no-activity WorkoutSession).
        // It counts toward that cycle's Rest slot exactly like an explicit
        // Rest Day log or a Rest Day activity do — a gap in an imported
        // history is you actively telling the app nothing else happened
        // that day, not a passive "the app wasn't opened" guess the way
        // WorkoutSession.backfillRestDays/creditYesterdayAsRestIfNothingLogged
        // are (those stay excluded from slot-filling on purpose — see
        // a8702ad's doc on Phase.cycleWalk).
        var gapFillRequests: [GroupKey] = []

        // Precomputes which exact PhaseDay each request (real or gap-fill)
        // resolves to, and its cycle number, for every (date, phase, label)
        // this import will ask about below. Neither is ever guessed: a real
        // row's cycle number is whatever its own explicit "Cycle" column
        // says — nothing is auto-detected/counted from walking the split's
        // pattern — and a row with no Cycle column stays untagged
        // (cycleNumber 0, invisible to Phase.cycleWalk, same as any other
        // unattributed data). A gap-fill (a calendar day with no row of its
        // own) can't state a cycle either way, so it inherits whichever
        // cycle number was most recently explicitly stated for that phase,
        // carried forward chronologically — "the day is missing, so tag it
        // Rest for the most recent cycle."
        //
        // Day resolution still needs *some* disambiguation when a phase has
        // more than one PhaseDay sharing a name (common: PhaseBuilderView
        // lets you add as many "Rest" days as the split needs) — a plain
        // by-name match always picks the same candidate (Swift's `first`),
        // so the SECOND same-named PhaseDay's slot could never be reached.
        // Resolved per (phase, cycle number) only — whichever same-named
        // candidate isn't yet used within that exact cycle — never by
        // walking the whole file's pattern; with no cycle number to key by
        // (no explicit Cycle, or a gap-fill inheriting none), or only one
        // candidate to begin with, it's just `first`.
        var resolvedAmbiguousDay: [GroupKey: PhaseDay] = [:]
        var resolvedCycleNumber: [GroupKey: Int] = [:]
        do {
            var requests: [GroupKey] = []
            var explicitCycleByRequest: [GroupKey: Int] = [:]
            var seenKeys = Set<GroupKey>()
            for row in exerciseRows + restRows {
                guard let label = row.dayLabel else { continue }
                let key = GroupKey(day: cal.startOfDay(for: row.date), phaseNumber: row.phaseNumber, dayLabel: label)
                guard !seenKeys.contains(key) else { continue }
                seenKeys.insert(key)
                requests.append(key)
                if let cycle = row.cycleNumber, cycle > 0 { explicitCycleByRequest[key] = cycle }
            }

            // Bounded to [phase's earliest EXERCISE date, latest attributed
            // date] — a Rest day/activity, gap-filled or real, is only ever
            // eligible once a phase already has real training behind it,
            // never before it: a Rest day should never be the first thing
            // logged for a phase. The lower bound comes strictly from
            // exerciseRows (mirrors earliestAttributedExerciseDate below,
            // generalized to every phase this import touches, not just
            // forcedPhase) — a Rest row's own date is never allowed to
            // pull the range earlier, even if it's chronologically first
            // among this phase's matched rows. The upper bound and
            // "already has something" check DO consider every matched row
            // (exercise or rest) plus that phase's pre-existing sessions,
            // so re-importing more rows into an already-populated phase
            // can't double up a day that already has real history, and a
            // trailing Rest row can still legitimately extend the range.
            var earliestExerciseDateByPhaseID: [PersistentIdentifier: Date] = [:]
            for row in exerciseRows {
                guard let label = row.dayLabel,
                      let phase = resolvePhase(phaseNumber: row.phaseNumber),
                      phase.orderedDays.contains(where: { $0.name.localizedCaseInsensitiveCompare(label) == .orderedSame })
                else { continue }
                let day = cal.startOfDay(for: row.date)
                let id = phase.persistentModelID
                if let existing = earliestExerciseDateByPhaseID[id], existing <= day { continue }
                earliestExerciseDateByPhaseID[id] = day
            }
            var fileDatesByPhaseID: [PersistentIdentifier: (phase: Phase, dates: Set<Date>)] = [:]
            for request in requests {
                guard let label = request.dayLabel,
                      let phase = resolvePhase(phaseNumber: request.phaseNumber),
                      phase.orderedDays.contains(where: { $0.name.localizedCaseInsensitiveCompare(label) == .orderedSame })
                else { continue }
                fileDatesByPhaseID[phase.persistentModelID, default: (phase, [])].dates.insert(request.day)
            }
            for (phaseID, entry) in fileDatesByPhaseID {
                let phase = entry.phase
                guard phase.orderedDays.contains(where: \.isRest),
                      let minDate = earliestExerciseDateByPhaseID[phaseID],
                      let maxDate = entry.dates.max(), minDate <= maxDate
                else { continue }
                let alreadyCovered = entry.dates.union(phase.sessions.map { cal.startOfDay(for: $0.date) })
                var day = minDate
                while day <= maxDate {
                    if !alreadyCovered.contains(day) {
                        gapFillRequests.append(GroupKey(day: day, phaseNumber: phase.number, dayLabel: nil, isGapFill: true))
                    }
                    guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
                    day = next
                }
            }

            requests.append(contentsOf: gapFillRequests)
            requests.sort { $0.day < $1.day }

            // Which same-named PhaseDay a cycle has already used, and the
            // most recent explicit cycle number seen — both per phase, both
            // updated only by a cycle number that's actually known (never
            // 0), so an untagged row/gap-fill can still inherit whatever
            // was most recently stated without itself resetting that state.
            var usedByCycle: [PersistentIdentifier: [Int: Set<PersistentIdentifier>]] = [:]
            var lastKnownCycle: [PersistentIdentifier: Int] = [:]
            for request in requests {
                guard let phase = resolvePhase(phaseNumber: request.phaseNumber) else { continue }
                let candidates: [PhaseDay]
                if request.isGapFill {
                    candidates = phase.orderedDays.filter(\.isRest)
                } else {
                    guard let label = request.dayLabel else { continue }
                    candidates = phase.orderedDays.filter { $0.name.localizedCaseInsensitiveCompare(label) == .orderedSame }
                }
                guard let firstCandidate = candidates.first else { continue }

                let cycle = request.isGapFill
                    ? (lastKnownCycle[phase.persistentModelID] ?? 0)
                    : (explicitCycleByRequest[request] ?? 0)
                resolvedCycleNumber[request] = cycle
                if cycle > 0 { lastKnownCycle[phase.persistentModelID] = cycle }

                let chosen: PhaseDay
                if candidates.count > 1, cycle > 0 {
                    let used = usedByCycle[phase.persistentModelID]?[cycle] ?? []
                    chosen = candidates.first { !used.contains($0.persistentModelID) } ?? firstCandidate
                } else {
                    chosen = firstCandidate
                }
                resolvedAmbiguousDay[request] = chosen
                if cycle > 0 {
                    usedByCycle[phase.persistentModelID, default: [:]][cycle, default: []].insert(chosen.persistentModelID)
                }
            }
        }

        /// Resolves a row's Phase/Day columns to a real (Phase, PhaseDay) —
        /// the day itself always comes from resolvedAmbiguousDay above
        /// (which already picked the right same-named candidate, if there
        /// was more than one) rather than re-doing a plain by-name lookup
        /// here. The phase itself only ever resolves via resolvePhase — a
        /// row attributes to a phase (forcedPhase or otherwise) only when
        /// its own Phase column explicitly names it.
        func matchPhaseDay(date: Date, phaseNumber: Int?, dayLabel: String?) -> (Phase?, PhaseDay?) {
            func lookupDay() -> PhaseDay? {
                guard let dayLabel else { return nil }
                let key = GroupKey(day: cal.startOfDay(for: date), phaseNumber: phaseNumber, dayLabel: dayLabel)
                return resolvedAmbiguousDay[key]
            }
            guard let phase = resolvePhase(phaseNumber: phaseNumber) else { return (nil, nil) }
            return (phase, lookupDay())
        }

        /// The cycle number to stamp on a session for this row — whatever
        /// the precompute above already resolved for this exact (date,
        /// phase, label) request: the row's own explicit "Cycle" column
        /// value, or 0 if it never had one (never guessed at).
        func resolvedCycle(date: Date, phaseNumber: Int?, dayLabel: String?) -> Int {
            guard let dayLabel else { return 0 }
            let key = GroupKey(day: cal.startOfDay(for: date), phaseNumber: phaseNumber, dayLabel: dayLabel)
            return resolvedCycleNumber[key] ?? 0
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
            let (matchedPhase, matchedDay) = matchPhaseDay(date: key.day, phaseNumber: key.phaseNumber, dayLabel: key.dayLabel)
            let cycle = resolvedCycle(date: key.day, phaseNumber: key.phaseNumber, dayLabel: key.dayLabel)
            // An imported workout overrides a gap-filled "nothing happened"
            // Rest Day placeholder for this same date.
            WorkoutSession.removeBackfilledRestPlaceholder(on: key.day, context: context)
            let session = WorkoutSession(date: key.day, day: matchedDay,
                                         dayLabel: key.dayLabel ?? "Imported", cycleNumber: cycle)
            session.phase = matchedPhase
            // Per-session facts from the enriched export. Taken from the
            // first row that carries one, since every row of a session
            // writes the same value.
            if let d = dayRows.compactMap(\.durationSeconds).first { session.durationSeconds = d }
            if dayRows.contains(where: \.isDeload) { session.isDeload = true }
            if dayRows.contains(where: \.isBonusSession) { session.isBonusSession = true }
            context.insert(session)
            sessionsCreated += 1

            for (order, entry) in dayRows.enumerated() {
                guard case .exercise(let goalType, let targetReps, let weights, let reps) = entry.kind else { continue }
                applyEquipment(entry.equipmentName, to: entry.exerciseName)
                // isBodyweight comes from an already-existing exercise, or
                // this row's own Equipment column if it said "Bodyweight".
                let isBW = entry.logIsBodyweight ?? (knownDefs[entry.exerciseName]?.isBodyweight ?? false)
                let log = ExerciseLog(exerciseName: entry.exerciseName, targetReps: targetReps,
                                      order: order, isBodyweight: isBW, goalType: goalType)
                log.session = session
                log.achievedRank = entry.achievedRank
                log.missedTarget = entry.missedTarget
                log.selectedWeightAdjustment = entry.selectedWeightAdjustment
                context.insert(log)

                // For a bodyweight exercise, Weights is ADDED weight (same
                // convention as live logging) — resolved against whatever
                // BodyWeightEntry was on record as of this row's date.
                let bw = isBW ? resolvedBodyweight(asOf: key.day) : nil
                for (i, pair) in zip(weights, reps).enumerated() {
                    let set: SetLog
                    // An exported bodyweightAtLog WINS over re-resolution.
                    // It was frozen at log time by design (SetLog's doc),
                    // and re-resolving would let a later weigh-in edit
                    // retroactively rewrite an old set's weight.
                    let exportedBW = entry.bodyweightAtLogs[safe: i] ?? nil
                    let exportedAdded = entry.addedWeights[safe: i] ?? nil
                    if let exportedBW {
                        set = SetLog(index: i, weight: pair.0, reps: pair.1,
                                     addedWeight: exportedAdded ?? (pair.0 - exportedBW),
                                     bodyweightAtLog: exportedBW)
                    } else if isBW {
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
        // among this import's own exercise rows that actually attribute to
        // forcedPhase (same resolvePhase + Day-label matching an exercise
        // row gets). Rest rows below are only retroactively attributed to
        // forcedPhase from that point forward — a "Rest" row logged before
        // this phase's own history actually begins (per this import)
        // shouldn't get swept in just because its label happens to match
        // the phase's Rest day too. Nil (so nothing qualifies) if no
        // exercise row here ends up attributed to forcedPhase at all.
        let earliestAttributedExerciseDate: Date? = forcedPhase.flatMap { phase in
            exerciseRows
                .filter { row in
                    guard let label = row.dayLabel, resolvePhase(phaseNumber: row.phaseNumber)?.persistentModelID == phase.persistentModelID
                    else { return false }
                    return phase.orderedDays.contains { $0.name.localizedCaseInsensitiveCompare(label) == .orderedSame }
                }
                .map(\.date)
                .min()
        }

        // Rest-day activities: each row becomes both a standalone
        // RestDayActivity record and a matching WorkoutSession/ExerciseLog/
        // SetLog, so it shows up in History and counts toward the rest-bank
        // streak — mirrors live logging (RestDayLogView.logActivity()).
        // Phase is left nil UNLESS forcedPhase is retroactively attributing
        // this whole import to a Phase AND this row's date is on/after
        // earliestAttributedExerciseDate — a Rest row logged before the
        // phase's own history begins (per this import) shouldn't be swept
        // in just because its label happens to match too (see
        // import_rest_day_phase_attribution: a Rest day/activity should
        // never be the first thing attributed to a phase). Once it does
        // qualify, it fills that cycle's Rest slot exactly like a training
        // day fills its own (a8702ad). Deliberately does NOT touch the
        // Exercises tab — a rest activity isn't an exercise in the import
        // file, so it shouldn't show up as one there.
        for (restIndex, entry) in restRows.enumerated() {
            if restIndex > 0, restIndex % checkpointInterval == 0 {
                try? context.save()
                await Task.yield()
            }
            guard case .restActivity(let distance, let unit) = entry.kind else { continue }
            let restActivity = RestDayActivity(date: entry.date, name: entry.exerciseName,
                                               distance: distance, distanceUnit: unit)
            context.insert(restActivity)

            let (matchedRestPhase, matchedDay) = matchPhaseDay(date: entry.date, phaseNumber: entry.phaseNumber, dayLabel: entry.dayLabel)
            let cycle = resolvedCycle(date: entry.date, phaseNumber: entry.phaseNumber, dayLabel: entry.dayLabel)
            // A logged rest-day activity overrides a gap-filled no-activity
            // Rest Day placeholder for this same date.
            WorkoutSession.removeBackfilledRestPlaceholder(on: entry.date, context: context)
            let session = WorkoutSession(date: entry.date, day: matchedDay,
                                         dayLabel: entry.dayLabel ?? "Rest Day", cycleNumber: cycle)
            let restRowQualifiesForForcedPhase = forcedPhase != nil
                && earliestAttributedExerciseDate.map { entry.date >= $0 } == true
            session.phase = restRowQualifiesForForcedPhase ? matchedRestPhase : nil
            context.insert(session)
            sessionsCreated += 1
            // The distance lives in the SetLog's `weight` (linked via
            // ExerciseLog.restDayActivity), editable in History and kept in
            // sync with restActivity.distance — see TodayView.logActivity().
            let log = ExerciseLog(exerciseName: entry.exerciseName, targetReps: [], order: 0)
            log.session = session
            log.restDayActivity = restActivity
            context.insert(log)
            let set = SetLog(index: 0, weight: distance ?? 0, reps: 1)
            set.exerciseLog = log
            context.insert(set)
            setsImported += 1
        }

        // Actually create the gap-fill Rest sessions computed above — one
        // per calendar day within a phase's attributed range that had no
        // data of its own, same shape logPlainRestDay() uses live (an
        // ActiveRecovery credit + a no-activity WorkoutSession, tied to
        // both the resolved Rest PhaseDay and the phase itself), so History
        // and the rest-bank streak read it exactly as if "Log Rest Day" had
        // been tapped that day.
        for (gapIndex, gapRequest) in gapFillRequests.enumerated() {
            if gapIndex > 0, gapIndex % checkpointInterval == 0 {
                try? context.save()
                await Task.yield()
            }
            guard let matchedDay = resolvedAmbiguousDay[gapRequest] else { continue }
            let phase = resolvePhase(phaseNumber: gapRequest.phaseNumber)
            let cycle = resolvedCycleNumber[gapRequest] ?? 0
            WorkoutSession.removeBackfilledRestPlaceholder(on: gapRequest.day, context: context)
            context.insert(ActiveRecovery(date: gapRequest.day, type: .rest))
            let session = WorkoutSession(date: gapRequest.day, day: matchedDay, dayLabel: matchedDay.name, cycleNumber: cycle)
            session.phase = phase
            context.insert(session)
            sessionsCreated += 1
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
        if let serial = parseFlexibleInt(s), let utcDate = excelSerialDate(serial) {
            let comps = utcCalendar.dateComponents([.year, .month, .day], from: utcDate)
            return Calendar.current.date(from: comps)
        }
        return nil
    }

    /// Parses a spreadsheet numeric cell's raw value as a whole number,
    /// accepting both a bare integer ("1") and the float form Excel's own
    /// XML actually stores an integer-valued numeric cell as ("1.0") — an
    /// .xlsx Phase/Cycle/date-serial column typed as a number, not text,
    /// round-trips through here as "N.0" even though nothing about the
    /// original value was ever fractional; `Int("1.0")` alone returns nil
    /// and would silently drop it. Used for date serials (see
    /// excelSerialDate below) and for the Phase/Cycle columns.
    private static func parseFlexibleInt(_ s: String) -> Int? {
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

// MARK: - Workbook recovery (all three sheets, preview before writing)

extension ImportEngine {
    /// What one TheJym-Export.xlsx holds, parsed but NOT written.
    struct Workbook {
        var historyRows: [ImportedEntry] = []
        var skipped = SkipReasons()
        var library: [LibraryEntry] = []
        var equipment: [EquipmentEntry] = []
        var platesOwned: [Double] = []
        /// The program half. Empty for any export older than this one,
        /// which is normal — restoreProgram is then a no-op.
        var program = Program()
        /// Distinct exercise names in History, for the rest-activity
        /// ticklist. Nothing is treated as a walk until the user says so.
        var candidateNames: [String] = []
        /// Every non-blank data row the History sheet held. The invariant
        /// is `historyRows.count + skipped.total == sourceRowCount` — no
        /// row may be neither imported nor named as skipped.
        var sourceRowCount = 0
        var isFullyAccounted: Bool { historyRows.count + skipped.total == sourceRowCount }
    }

    struct LibraryEntry {
        var name: String
        var equipmentName: String
        var isBodyweight: Bool
        /// "5/5/5; 100 total" — rep schemes and rep-total targets together,
        /// exactly as exercisesSheetRows writes them.
        var setsText: String
        var notes: String
        var isBigLift = false
        /// "5/5/5>8/8/8@5" per ceiling, semicolon-separated.
        var ceilingsText = ""
        var additionalNotes = ""
        var dateAdded: Date?
    }

    struct EquipmentEntry {
        var name: String
        var isDumbbell: Bool
        var weight: Double
        var loadableSides: Int
        var dumbbellWeights: [Double]
    }

    /// Counts for the confirm screen. Nothing is persisted to produce this.
    struct RecoveryPreview {
        var sessions = 0
        var exerciseLogs = 0
        var sets = 0
        var weighIns = 0
        var restActivities = 0
        var firstDate: Date?
        var lastDate: Date?
        /// Bodyweight sets that will get a frozen bodyweightAtLog from an
        /// earlier weigh-in, and those with no weigh-in on or before their
        /// date — the latter resolve to nil and are skipped by Big Lifts.
        var bodyweightSetsResolved = 0
        var bodyweightSetsUnresolved = 0
    }

    /// Reads History / Exercises / Equipment by sheet NAME, falling back to
    /// the first sheet for a foreign file that has no sheet called
    /// "History" (which is how every pre-existing import behaved).
    static func parseWorkbook(xlsxData: Data, restActivityNames: Set<String> = [],
                              from: Date? = nil, through: Date? = nil) -> Workbook? {
        guard let sheets = XLSXReader.readSheetsByName(data: xlsxData) else { return nil }

        func sheet(_ wanted: String) -> [[String]]? {
            sheets.first { $0.key.compare(wanted, options: .caseInsensitive) == .orderedSame }?.value
        }

        var wb = Workbook()
        let history = sheet("History") ?? sheets.sorted { $0.key < $1.key }.first?.value
        if let history, let header = history.first {
            let dataRows = history.dropFirst().filter { row in
                !row.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            }
            let parsed = parseFields(header: header, rows: Array(dataRows),
                                     restActivityNames: restActivityNames,
                                     from: from, through: through)
            wb.historyRows = parsed.rows
            wb.skipped = parsed.skipped
            wb.sourceRowCount = dataRows.count

            // Candidate names for the ticklist: distinct exercise names
            // that aren't weigh-ins. Taken from a NAME-ONLY re-read rather
            // than from parsed rows, so a name already ticked still appears
            // (it's now a restActivity entry, not an exercise one).
            if let exIdx = header.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() })
                .firstIndex(where: { $0.hasPrefix("exercise") }) {
                var seen = Set<String>(), names: [String] = []
                for row in dataRows {
                    guard let raw = row[safe: exIdx]?.trimmingCharacters(in: .whitespaces),
                          !raw.isEmpty, !isBodyWeightLabel(raw) else { continue }
                    if seen.insert(raw.lowercased()).inserted { names.append(raw) }
                }
                wb.candidateNames = names.sorted()
            }
        }

        if let rows = sheet("Program"), rows.count > 1 {
            wb.program = parseProgramSheet(rows)
        }

        if let rows = sheet("Exercises"), rows.count > 1 {
            for row in rows.dropFirst() {
                let name = (row[safe: 0] ?? "").trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                wb.library.append(LibraryEntry(
                    name: name,
                    equipmentName: (row[safe: 1] ?? "").trimmingCharacters(in: .whitespaces),
                    isBodyweight: (row[safe: 2] ?? "").lowercased().hasPrefix("y"),
                    setsText: (row[safe: 3] ?? "").trimmingCharacters(in: .whitespaces),
                    notes: (row[safe: 4] ?? "").trimmingCharacters(in: .whitespaces),
                    isBigLift: (row[safe: 5] ?? "").lowercased().hasPrefix("y"),
                    ceilingsText: (row[safe: 6] ?? "").trimmingCharacters(in: .whitespaces),
                    additionalNotes: (row[safe: 7] ?? "").trimmingCharacters(in: .whitespaces),
                    dateAdded: parseDate((row[safe: 8] ?? "").trimmingCharacters(in: .whitespaces))))
            }
        }

        if let rows = sheet("Equipment"), rows.count > 1 {
            for row in rows.dropFirst() {
                let name = (row[safe: 0] ?? "").trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                // The plates row is appended after a blank spacer as
                // ["Plates Owned", "45, 25, 10"] — same sheet, different
                // shape, so it's matched by name rather than by position.
                if name.compare("Plates Owned", options: .caseInsensitive) == .orderedSame {
                    wb.platesOwned = (row[safe: 1] ?? "").split(separator: ",")
                        .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                    continue
                }
                let isDumbbell = (row[safe: 1] ?? "").lowercased().contains("dumbbell")
                    || (row[safe: 1] ?? "").lowercased().contains("band")
                wb.equipment.append(EquipmentEntry(
                    name: name,
                    isDumbbell: isDumbbell,
                    weight: Double((row[safe: 2] ?? "").trimmingCharacters(in: .whitespaces)) ?? 0,
                    loadableSides: Int((row[safe: 3] ?? "").trimmingCharacters(in: .whitespaces)) ?? 2,
                    dumbbellWeights: (row[safe: 4] ?? "").split(separator: ",")
                        .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }))
            }
        }
        return wb
    }

    /// Test seam onto the private row parser, so the body-weight and
    /// rest-activity rules can be exercised on a literal sheet grid rather
    /// than by building an .xlsx.
    static func parseHistorySheetForTesting(_ grid: [[String]],
                                            restActivityNames: Set<String> = []) -> [ImportedEntry] {
        guard let header = grid.first else { return [] }
        return parseFields(header: header, rows: Array(grid.dropFirst()),
                           restActivityNames: restActivityNames).rows
    }

    static func parseHistorySheetWithReasonsForTesting(_ grid: [[String]],
                                                       restActivityNames: Set<String> = [])
    -> (rows: [ImportedEntry], skipped: SkipReasons) {
        guard let header = grid.first else { return ([], SkipReasons()) }
        return parseFields(header: header, rows: Array(grid.dropFirst()),
                           restActivityNames: restActivityNames)
    }

    /// Rows whose date falls inside [from, through], both inclusive and
    /// both optional.
    ///
    /// This is the duplicate guard as much as a filter: the import is
    /// additive with no dedup, so a floor one day after the last restored
    /// session is what keeps a re-run from doubling everything.
    static func rows(_ rows: [ImportedEntry], from: Date?, through: Date?,
                     cal: Calendar = .current) -> [ImportedEntry] {
        let lower = from.map { cal.startOfDay(for: $0) }
        let upper = through.map { cal.startOfDay(for: $0) }
        return rows.filter { row in
            let day = cal.startOfDay(for: row.date)
            if let lower, day < lower { return false }
            if let upper, day > upper { return false }
            return true
        }
    }

    /// Counts for the confirm screen, including how many bodyweight sets
    /// will find a frozen bodyweightAtLog. `existingWeighIns` is the store's
    /// current BodyWeightEntry dates+weights, since a restored store's
    /// earlier weigh-ins are legitimate sources for a later imported set.
    static func preview(_ rows: [ImportedEntry], existingWeighIns: [(date: Date, weight: Double)],
                        bodyweightExerciseNames: Set<String>,
                        cal: Calendar = .current) -> RecoveryPreview {
        var p = RecoveryPreview()
        var sessionDays = Set<Date>()

        // Every weigh-in available to resolve against: what's already in the
        // store plus the ones this import is about to add.
        var sources = existingWeighIns
        for row in rows {
            if case .bodyWeight(let w) = row.kind { sources.append((row.date, w)) }
        }
        sources.sort { $0.date < $1.date }

        for row in rows {
            switch row.kind {
            case .bodyWeight:
                p.weighIns += 1
            case .restActivity:
                p.restActivities += 1
                sessionDays.insert(cal.startOfDay(for: row.date))
            case .exercise(_, _, let weights, _):
                p.exerciseLogs += 1
                p.sets += weights.count
                sessionDays.insert(cal.startOfDay(for: row.date))
                if bodyweightExerciseNames.contains(row.exerciseName) {
                    let resolved = sources.last { $0.date <= row.date } != nil
                    if resolved { p.bodyweightSetsResolved += weights.count }
                    else { p.bodyweightSetsUnresolved += weights.count }
                }
            }
            p.firstDate = min(p.firstDate ?? row.date, row.date)
            p.lastDate = max(p.lastDate ?? row.date, row.date)
        }
        p.sessions = sessionDays.count
        return p
    }

    /// Writes the Exercises and Equipment sheets back into the store.
    /// Additive and idempotent by NAME — an exercise or bar that already
    /// exists is updated in place rather than duplicated, so re-running
    /// this half is safe even though the history half is not.
    @MainActor
    static func restoreLibraryAndEquipment(_ wb: Workbook, context: ModelContext) {
        let existingBars = (try? context.fetch(FetchDescriptor<Bar>())) ?? []
        var barsByName = Dictionary(existingBars.map { ($0.name.lowercased(), $0) },
                                    uniquingKeysWith: { a, _ in a })
        for e in wb.equipment {
            let bar = barsByName[e.name.lowercased()] ?? {
                let b = Bar(name: e.name, weight: 0)
                context.insert(b)
                barsByName[e.name.lowercased()] = b
                return b
            }()
            bar.isDumbbell = e.isDumbbell
            bar.weight = e.weight
            bar.loadableSides = e.loadableSides
            if !e.dumbbellWeights.isEmpty { bar.dumbbellWeights = e.dumbbellWeights }
        }

        let existingDefs = (try? context.fetch(FetchDescriptor<ExerciseDef>())) ?? []
        var defsByName = Dictionary(existingDefs.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for l in wb.library {
            let def = defsByName[l.name] ?? {
                let d = ExerciseDef(name: l.name)
                context.insert(d)
                defsByName[l.name] = d
                return d
            }()
            def.isBodyweight = l.isBodyweight
            def.isBigLift = l.isBigLift
            if !l.notes.isEmpty { def.notes = l.notes }
            if !l.additionalNotes.isEmpty { def.additionalNotes = l.additionalNotes }
            if let d = l.dateAdded { def.dateAdded = d }
            // "5/5/5>8/8/8@5" -> RepSchemeCeiling. Parsed strictly: a
            // malformed entry is skipped rather than half-built, since a
            // wrong ceiling changes how weights progress.
            for token in l.ceilingsText.split(separator: ";") {
                let t = token.trimmingCharacters(in: .whitespaces)
                guard let gt = t.firstIndex(of: ">"), let at = t.firstIndex(of: "@"), gt < at else { continue }
                let reps = t[t.startIndex..<gt].split(separator: "/").compactMap { Int($0) }
                let upper = t[t.index(after: gt)..<at].split(separator: "/").compactMap { Int($0) }
                guard let amount = Double(t[t.index(after: at)...]), !reps.isEmpty, !upper.isEmpty else { continue }
                let ceiling = RepSchemeCeiling(reps: reps, upperTargetReps: upper, weightIncreaseAmount: amount)
                if !def.repSchemeCeilings.contains(ceiling) { def.repSchemeCeilings.append(ceiling) }
            }
            if !l.equipmentName.isEmpty { def.equipment = barsByName[l.equipmentName.lowercased()] }
            // "5/5/5; 8/8/8; 100 total" -> two rep schemes and one rep-total
            for part in l.setsText.split(separator: ";") {
                let token = part.trimmingCharacters(in: .whitespaces)
                guard !token.isEmpty else { continue }
                if token.lowercased().hasSuffix("total") {
                    if let n = Int(token.split(separator: " ").first.map(String.init) ?? "") {
                        def.addRepTotalTarget(n)
                    }
                } else {
                    let reps = token.split(separator: "/").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                    if !reps.isEmpty, !def.repSchemes.contains(reps) { def.repSchemes.append(reps) }
                }
            }
        }

        if !wb.platesOwned.isEmpty,
           let settings = (try? context.fetch(FetchDescriptor<AppSettings>()))?.first {
            settings.availablePlateSizes = wb.platesOwned
        }
        try? context.save()
    }
}

// MARK: - Program sheet (Phase / PhaseDay / PlannedExercise / settings)

extension ImportEngine {
    /// The program half of an enriched export: everything the original
    /// three sheets dropped.
    ///
    /// A file WITHOUT a Program sheet is normal, not an error — every
    /// export before this one lacks it, including the one used for the
    /// Oct 2026 recovery. `isEmpty` is then true and restoreProgram is a
    /// no-op, so an older file imports exactly as it always did.
    struct Program {
        struct PhaseRow {
            var number = 0, totalCycles = 0, deloadCycle = 0
            var startDate = Date()
            var isActive = false
            var manualDeloadCycles: [Int] = []
            var legacyCompletedCycles: Int?
        }
        struct DayRow { var phaseNumber = 0, order = 0; var name = ""; var isRest = false }
        struct PlannedRow {
            var phaseNumber = 0, order = 0
            var dayName = "", exerciseName = ""
            var targetReps: [Int] = []
            var suggestedWeights: [Double] = []
            var isBodyweight = false
            var goalKindRaw = 0, repTotalTarget = 0, cycleOverride = 0
            var restTimeSeconds: Int?
            /// The owning day's order. Carried alongside dayName for the
            /// same reason days are matched by order: "Rest" is not a
            /// unique name within a phase. -1 means an older file that
            /// didn't carry it, which falls back to name matching.
            var dayOrder = -1
        }
        var phases: [PhaseRow] = []
        var days: [DayRow] = []
        var planned: [PlannedRow] = []
        var recoveries: [(date: Date, typeRaw: Int)] = []
        var tdpwChanges: [(date: Date, value: Int)] = []
        var settings: [String: String] = [:]
        var timerTemplates: [(name: String, order: Int, continuous: Bool)] = []
        var timerPresets: [(template: String, name: String, seconds: Double,
                            repeatCount: Int, order: Int, isRest: Bool)] = []

        var isEmpty: Bool {
            phases.isEmpty && days.isEmpty && planned.isEmpty
                && recoveries.isEmpty && tdpwChanges.isEmpty && settings.isEmpty
                && timerTemplates.isEmpty && timerPresets.isEmpty
        }
    }

    /// Row-type dispatch on column A. An unrecognised Type is SKIPPED
    /// rather than treated as an error, so a newer file adding a row kind
    /// still imports on an older build.
    static func parseProgramSheet(_ grid: [[String]]) -> Program {
        var p = Program()
        func str(_ r: [String], _ i: Int) -> String { (r[safe: i] ?? "").trimmingCharacters(in: .whitespaces) }
        func int(_ r: [String], _ i: Int) -> Int { parseFlexibleInt(str(r, i)) ?? 0 }
        func yes(_ r: [String], _ i: Int) -> Bool { str(r, i).lowercased().hasPrefix("y") }
        func ints(_ s: String) -> [Int] {
            s.split(whereSeparator: { $0 == "," || $0 == "/" })
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        }

        for row in grid.dropFirst() {
            switch str(row, 0).lowercased() {
            case "phase":
                guard let date = parseDate(str(row, 3)) else { continue }
                p.phases.append(.init(number: int(row, 1), totalCycles: int(row, 2),
                                      deloadCycle: int(row, 5), startDate: date,
                                      isActive: yes(row, 4),
                                      manualDeloadCycles: ints(str(row, 6)),
                                      legacyCompletedCycles: parseFlexibleInt(str(row, 7))))
            case "phaseday":
                p.days.append(.init(phaseNumber: int(row, 1), order: int(row, 2),
                                    name: str(row, 3), isRest: yes(row, 4)))
            case "plannedexercise":
                p.planned.append(.init(
                    phaseNumber: int(row, 1), order: int(row, 3),
                    dayName: str(row, 2), exerciseName: str(row, 4),
                    targetReps: ints(str(row, 5)),
                    suggestedWeights: str(row, 6).split(separator: "/")
                        .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) },
                    isBodyweight: yes(row, 7),
                    goalKindRaw: int(row, 8), repTotalTarget: int(row, 9),
                    cycleOverride: int(row, 11),
                    restTimeSeconds: parseFlexibleInt(str(row, 10)),
                    dayOrder: parseFlexibleInt(str(row, 12)) ?? -1))
            case "activerecovery":
                if let d = parseDate(str(row, 1)) { p.recoveries.append((d, int(row, 2))) }
            case "trainingdaysperweek":
                if let d = parseDate(str(row, 1)) { p.tdpwChanges.append((d, int(row, 2))) }
            case "timertemplate":
                p.timerTemplates.append((str(row, 1), int(row, 2), yes(row, 3)))
            case "timerpreset":
                p.timerPresets.append((str(row, 1), str(row, 2),
                                       Double(str(row, 3)) ?? 0, int(row, 4),
                                       int(row, 5), yes(row, 6)))
            case "setting":
                p.settings[str(row, 1)] = str(row, 2)
            default:
                continue
            }
        }
        return p
    }

    /// Writes the program back. Must run BEFORE importIntoStore so the
    /// history's Phase/Day/Cycle columns have phases to attach to —
    /// resolvePhase matches on an existing Phase by number, and a session
    /// imported before its phase exists would land unattributed with no
    /// second chance.
    ///
    /// Matches phases by NUMBER and days by name within a phase, updating
    /// in place rather than duplicating, so re-running is safe.
    @MainActor
    static func restoreProgram(_ p: Program, context: ModelContext) {
        guard !p.isEmpty else { return }
        var existingPhases = (try? context.fetch(FetchDescriptor<Phase>())) ?? []

        for row in p.phases {
            let phase = existingPhases.first { $0.number == row.number } ?? {
                let new = Phase(number: row.number, totalCycles: row.totalCycles,
                                startDate: row.startDate)
                context.insert(new)
                existingPhases.append(new)
                return new
            }()
            phase.totalCycles = row.totalCycles
            phase.startDate = row.startDate
            phase.isActive = row.isActive
            phase.deloadCycle = row.deloadCycle
            phase.manualDeloadCycles = row.manualDeloadCycles
            phase.legacyCompletedCycles = row.legacyCompletedCycles
        }

        for row in p.days {
            guard let phase = existingPhases.first(where: { $0.number == row.phaseNumber }) else { continue }
            // Matched by ORDER, not name. A six-day split has TWO days
            // called "Rest", so name-matching made the second Rest row
            // find the first and update it — silently collapsing every
            // split from six days to five. Order is unique within a phase
            // and is what orderedDays sorts on anyway.
            if let existing = phase.days.first(where: { $0.order == row.order }) {
                existing.name = row.name
                existing.isRest = row.isRest
            } else {
                let day = PhaseDay(order: row.order, name: row.name, isRest: row.isRest)
                day.phase = phase
                context.insert(day)
            }
        }

        for row in p.planned {
            guard let phase = existingPhases.first(where: { $0.number == row.phaseNumber }),
                  let day = phase.days.first(where: { $0.order == row.dayOrder })
                      ?? phase.days.first(where: {
                          $0.name.localizedCaseInsensitiveCompare(row.dayName) == .orderedSame
                      }) else { continue }
            // Keyed by (order, cycleOverride) within the day, which is
            // what makes a per-cycle override distinct from its base slot.
            if day.plannedExercises.contains(where: {
                $0.order == row.order && $0.cycleOverride == row.cycleOverride
                    && $0.exerciseName == row.exerciseName
            }) { continue }
            let goal: GoalType = row.goalKindRaw == 1
                ? .repTotal(target: row.repTotalTarget) : .fixedSets
            let pe = PlannedExercise(order: row.order, exerciseName: row.exerciseName,
                                     targetReps: row.targetReps,
                                     suggestedWeights: row.suggestedWeights,
                                     isBodyweight: row.isBodyweight, goalType: goal,
                                     restTimeSeconds: row.restTimeSeconds,
                                     cycleOverride: row.cycleOverride)
            pe.day = day
            context.insert(pe)
        }

        let existingRecoveryDays = Set(((try? context.fetch(FetchDescriptor<ActiveRecovery>())) ?? [])
            .map { Calendar.current.startOfDay(for: $0.date) })
        for row in p.recoveries where !existingRecoveryDays.contains(Calendar.current.startOfDay(for: row.date)) {
            context.insert(ActiveRecovery(date: row.date,
                                          type: ActiveRecoveryType(rawValue: row.typeRaw) ?? .rest))
        }

        let existingChangeDays = Set(((try? context.fetch(FetchDescriptor<TrainingDaysPerWeekChange>())) ?? [])
            .map { Calendar.current.startOfDay(for: $0.date) })
        for row in p.tdpwChanges where !existingChangeDays.contains(Calendar.current.startOfDay(for: row.date)) {
            context.insert(TrainingDaysPerWeekChange(date: row.date, trainingDaysPerWeek: row.value))
        }

        var templatesByName = Dictionary(
            ((try? context.fetch(FetchDescriptor<TimerTemplate>())) ?? []).map { ($0.name, $0) },
            uniquingKeysWith: { a, _ in a })
        for row in p.timerTemplates {
            let t = templatesByName[row.name] ?? {
                let new = TimerTemplate(name: row.name, order: row.order)
                context.insert(new)
                templatesByName[row.name] = new
                return new
            }()
            t.order = row.order
            t.continuous = row.continuous
        }
        for row in p.timerPresets {
            guard let template = templatesByName[row.template] else { continue }
            guard !template.presets.contains(where: { $0.name == row.name && $0.order == row.order }) else { continue }
            let preset = TimerPreset(name: row.name, seconds: row.seconds,
                                     repeatCount: row.repeatCount, order: row.order, isRest: row.isRest)
            preset.template = template
            context.insert(preset)
        }

        if let settings = (try? context.fetch(FetchDescriptor<AppSettings>()))?.first {
            func bool(_ k: String) -> Bool? { p.settings[k].map { $0.lowercased().hasPrefix("y") } }
            if let v = p.settings["trainingStartDate"].flatMap({ parseDate($0) }) { settings.trainingStartDate = v }
            if let v = p.settings["trainingDaysPerWeek"].flatMap({ Int($0) }) { settings.trainingDaysPerWeek = v }
            if let v = p.settings["aiAggressivenessRaw"].flatMap({ Int($0) }) { settings.aiAggressivenessRaw = v }
            if let v = bool("deloadWeeksEnabled") { settings.deloadWeeksEnabled = v }
            if let v = bool("hasDumbbell125Attachment") { settings.hasDumbbell125Attachment = v }
            if let v = bool("hasDumbbell25Attachment") { settings.hasDumbbell25Attachment = v }
            if let v = bool("customWeightIncreaseEnabled") { settings.customWeightIncreaseEnabled = v }
            if let v = p.settings["customWeightIncreaseStreak"].flatMap({ Int($0) }) { settings.customWeightIncreaseStreak = v }
            if let v = p.settings["customWeightIncreaseAmount"].flatMap({ Double($0) }) { settings.customWeightIncreaseAmount = v }
            if let v = bool("streakRemindersEnabled") { settings.streakRemindersEnabled = v }
            if let v = p.settings["streakReminderHour"].flatMap({ Int($0) }) { settings.streakReminderHour = v }
            if let v = bool("weightRemindersEnabled") { settings.weightRemindersEnabled = v }
            if let v = p.settings["weightReminderHour"].flatMap({ Int($0) }) { settings.weightReminderHour = v }
            if let v = bool("includeDefaultExercises") { settings.includeDefaultExercises = v }
        }
        try? context.save()
    }
}
