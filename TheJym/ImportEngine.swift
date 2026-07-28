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
//  Phase is that phase's number; Day is the day's name (e.g. "Push A"),
//  matched case-insensitively against that phase's days. If either is
//  missing or doesn't match an existing Phase/PhaseDay, the row still
//  imports — it just falls back to an unattributed "Imported" entry (or
//  keeps whatever Day text was given as the label, if only the phase match
//  failed).
//

import Foundation
import SwiftData

enum ImportEngine {
    struct ImportedEntry {
        let date: Date
        let exerciseName: String
        let goalType: GoalType     // .fixedSets (default) or .repTotal, from the "Sets" column
        let targetReps: [Int]      // "Sets" column, e.g. [5,5,5,3,3] — empty for repTotal
        let weights: [Double]      // "Weights" column
        let reps: [Int]            // "Reps" column — actual reps achieved
        let phaseNumber: Int?      // optional "Phase" column
        let dayLabel: String?      // optional "Day" column, e.g. "Push A"
    }

    struct ImportResult {
        var sessionsCreated: Int
        var setsImported: Int
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
        // Optional — the import still works fine without either of these.
        let phaseIdx = header.firstIndex(where: { $0.hasPrefix("phase") })
        let dayIdx = header.firstIndex(where: { $0.hasPrefix("day") })

        var out: [ImportedEntry] = []
        var skipped = 0
        for fields in rows {
            guard fields.count > max(dateIdx, exerciseIdx, setsIdx, weightsIdx, repsIdx) else { skipped += 1; continue }
            let name = fields[exerciseIdx].trimmingCharacters(in: .whitespaces)
            let dateStr = fields[dateIdx].trimmingCharacters(in: .whitespaces)
            let setsStr = recoverSlashValue(fields[setsIdx])
            let weightsStr = recoverSlashValue(fields[weightsIdx])
            let repsStr = recoverSlashValue(fields[repsIdx])

            guard !name.isEmpty, let date = parseDate(dateStr) else { skipped += 1; continue }

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

            let phaseStr = phaseIdx.flatMap { fields[safe: $0] }?.trimmingCharacters(in: .whitespaces)
            let dayStr = dayIdx.flatMap { fields[safe: $0] }?.trimmingCharacters(in: .whitespaces)

            out.append(ImportedEntry(date: date, exerciseName: name, goalType: goalType,
                                     targetReps: targetReps, weights: weights, reps: reps,
                                     phaseNumber: phaseStr.flatMap { Int($0) },
                                     dayLabel: (dayStr?.isEmpty == false) ? dayStr : nil))
        }
        return (out, skipped)
    }

    /// Groups rows into one WorkoutSession per calendar day (further split if
    /// rows disagree on Phase/Day), one ExerciseLog per row, sets built from
    /// the row's Weights/Reps pairs in order. A row's Phase/Day, if given and
    /// matched, links the session to that real Phase/PhaseDay; otherwise it
    /// falls back to an unattributed "Imported" entry.
    @MainActor
    static func importIntoStore(_ rows: [ImportedEntry], context: ModelContext) -> ImportResult {
        let cal = Calendar.current
        let existingDefs = (try? context.fetch(FetchDescriptor<ExerciseDef>())) ?? []
        var knownDefs = Dictionary(uniqueKeysWithValues: existingDefs.map { ($0.name, $0) })
        let existingPhases = (try? context.fetch(FetchDescriptor<Phase>())) ?? []

        struct GroupKey: Hashable {
            let day: Date
            let phaseNumber: Int?
            let dayLabel: String?
        }
        let grouped = Dictionary(grouping: rows) { row in
            GroupKey(day: cal.startOfDay(for: row.date), phaseNumber: row.phaseNumber, dayLabel: row.dayLabel)
        }

        var sessionsCreated = 0
        var setsImported = 0

        for (key, dayRows) in grouped.sorted(by: { $0.key.day < $1.key.day }) {
            let matchedPhase = key.phaseNumber.flatMap { num in existingPhases.first { $0.number == num } }
            let matchedDay = matchedPhase.flatMap { phase in
                key.dayLabel.flatMap { label in
                    phase.orderedDays.first { $0.name.localizedCaseInsensitiveCompare(label) == .orderedSame }
                }
            }
            let session = WorkoutSession(date: key.day, day: matchedDay,
                                         dayLabel: key.dayLabel ?? "Imported", cycleNumber: 0)
            session.phase = matchedPhase
            context.insert(session)
            sessionsCreated += 1

            for (order, entry) in dayRows.enumerated() {
                let log = ExerciseLog(exerciseName: entry.exerciseName, targetReps: entry.targetReps,
                                      order: order, goalType: entry.goalType)
                log.session = session
                context.insert(log)

                for (i, pair) in zip(entry.weights, entry.reps).enumerated() {
                    let set = SetLog(index: i, weight: pair.0, reps: pair.1)
                    set.exerciseLog = log
                    context.insert(set)
                    setsImported += 1
                }

                switch entry.goalType {
                case .repTotal(let target):
                    if let def = knownDefs[entry.exerciseName] {
                        def.addRepTotalTarget(target)
                    } else {
                        let def = ExerciseDef(name: entry.exerciseName, repTotalTargets: [target])
                        context.insert(def)
                        knownDefs[entry.exerciseName] = def
                    }
                case .fixedSets:
                    if entry.targetReps.isEmpty {
                        ExerciseDef.ensureAnyVariantExists(name: entry.exerciseName, knownDefs: &knownDefs, context: context)
                    } else {
                        ExerciseDef.ensureVariantExists(name: entry.exerciseName, targetReps: entry.targetReps,
                                                        knownDefs: &knownDefs, context: context)
                    }
                }
            }
        }

        try? context.save()
        return ImportResult(sessionsCreated: sessionsCreated, setsImported: setsImported)
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

    private static func parseDate(_ s: String) -> Date? {
        if let iso = ISO8601DateFormatter().date(from: s) { return iso }
        for f in dateFormatters {
            if let d = f.date(from: s) { return d }
        }
        // .xlsx stores dates as day-count serials (no formatting info
        // survives once we've read just the cell value) — usually a bare
        // integer, but some exporters write it as a float like "45700.0".
        if let serial = serialInt(from: s) { return excelSerialDate(serial) }
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

    // MARK: - Sets/Weights/Reps recovery
    //
    // Spreadsheets love "fixing" a slash value like "12/12/12" by treating it
    // as a date. Recover the intended value from whatever shape that mangling
    // took: a leading apostrophe some sheets add to force literal text
    // ('12/12/12), a fully-expanded date (12/12/2012), or a raw date serial
    // number some exporters dump instead (41255) — all become "12/12/12".

    private static func recoverSlashValue(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("'") { s.removeFirst() }

        // Most common case: a spreadsheet "fixed" e.g. "8/8/8" into a plain
        // slash- or dash-separated M/D/Y string like "8/8/2008" or "8-8-08".
        // Pull the three numbers straight out of the string — no need to
        // round-trip through an actual Date, which sidesteps any
        // DateFormatter matching-order/leniency ambiguity entirely.
        if let recovered = monthDaySlashYearFromComponents(s) {
            return recovered
        }
        // A bare number might be a spreadsheet date serial rather than an
        // actual rep/weight value — real reps/weights never get this large.
        // Serials are timezone-agnostic day counts, so extract in UTC.
        if let serial = serialInt(from: s), let date = excelSerialDate(serial) {
            return monthDaySlashYear(date, calendar: utcCalendar)
        }
        // parseDate's formatters use the local timezone, so extract components
        // the same way to avoid shifting the day for users east/west of UTC.
        if let date = parseDate(s) {
            return monthDaySlashYear(date, calendar: .current)
        }
        return s
    }

    /// Directly splits a "M/D/Y" or "M-D-Y" shaped string into its three
    /// numeric components assuming MM/DD/YYYY — e.g. "8/8/2008" or
    /// "12-12-2012" -> "8/8/8" / "12/12/12". Returns nil if `s` isn't shaped
    /// like exactly three numbers with a plausible month (1-12) and day
    /// (1-31), so it never touches an unrelated value like "13/13/13".
    private static func monthDaySlashYearFromComponents(_ s: String) -> String? {
        let parts = s.components(separatedBy: CharacterSet(charactersIn: "/-"))
        guard parts.count == 3,
              let month = Int(parts[0]), let day = Int(parts[1]), let year = Int(parts[2]),
              month >= 1, month <= 12, day >= 1, day <= 31
        else { return nil }
        return "\(month)/\(day)/\(year % 100)"
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

    /// "12/12/12" style: month/day/last-2-digits-of-year.
    private static func monthDaySlashYear(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let shortYear = (c.year ?? 0) % 100
        return "\(c.month ?? 0)/\(c.day ?? 0)/\(shortYear)"
    }
}
