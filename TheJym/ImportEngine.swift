//
//  ImportEngine.swift
//  TheJym
//
//  Bulk-import historical workouts from a CSV (e.g. a Google Sheet
//  exported/shared as .csv). One row = one exercise logged on one day, with
//  Date, Exercise, Sets, Weights, and Reps columns (any order, header
//  matched case-insensitively):
//
//    Date       | Exercise    | Sets      | Weights           | Reps
//    2026-01-05 | Back Squat  | 5/5/5/3/3 | 135/135/135/145/145 | 6/5/5/5/3
//
//  Sets is the target rep scheme for that exercise (becomes a saved "Set" on
//  it in the Exercises tab); Weights and Reps are what was actually lifted,
//  one slash-separated value per set, in the same order. Weights and Reps
//  must have the same count; Sets may have a different count or be left
//  blank if there was no real target.
//

import Foundation
import SwiftData

enum ImportEngine {
    struct ImportedEntry {
        let date: Date
        let exerciseName: String
        let targetReps: [Int]     // "Sets" column, e.g. [5,5,5,3,3]
        let weights: [Double]     // "Weights" column
        let reps: [Int]           // "Reps" column — actual reps achieved
    }

    struct ImportResult {
        var sessionsCreated: Int
        var setsImported: Int
    }

    /// Parses CSV text into rows, matching the header case-insensitively.
    /// Returns the parsed rows plus a count of data rows that didn't parse.
    static func parseRows(csv: String) -> (rows: [ImportedEntry], skipped: Int) {
        let lines = csv.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }).map(String.init)
        guard let headerLine = lines.first else { return ([], 0) }
        let header = splitCSVLine(headerLine).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let dateIdx = header.firstIndex(where: { $0.hasPrefix("date") }),
              let exerciseIdx = header.firstIndex(where: { $0.hasPrefix("exercise") }),
              let setsIdx = header.firstIndex(where: { $0.hasPrefix("set") }),
              let weightsIdx = header.firstIndex(where: { $0.hasPrefix("weight") }),
              let repsIdx = header.firstIndex(where: { $0.hasPrefix("rep") })
        else { return ([], 0) }

        var out: [ImportedEntry] = []
        var skipped = 0
        for line in lines.dropFirst() {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let fields = splitCSVLine(line)
            guard fields.count > max(dateIdx, exerciseIdx, setsIdx, weightsIdx, repsIdx) else { skipped += 1; continue }
            let name = fields[exerciseIdx].trimmingCharacters(in: .whitespaces)
            let dateStr = fields[dateIdx].trimmingCharacters(in: .whitespaces)
            let setsStr = recoverSlashValue(fields[setsIdx])
            let weightsStr = recoverSlashValue(fields[weightsIdx])
            let repsStr = recoverSlashValue(fields[repsIdx])

            guard !name.isEmpty, let date = parseDate(dateStr) else { skipped += 1; continue }

            let targetReps = setsStr.split(separator: "/").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            let weights = weightsStr.split(separator: "/").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            let reps = repsStr.split(separator: "/").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard !weights.isEmpty, weights.count == reps.count else { skipped += 1; continue }

            out.append(ImportedEntry(date: date, exerciseName: name, targetReps: targetReps, weights: weights, reps: reps))
        }
        return (out, skipped)
    }

    /// Groups rows into one WorkoutSession per calendar day, one ExerciseLog
    /// per row, sets built from the row's Weights/Reps pairs in order.
    @MainActor
    static func importIntoStore(_ rows: [ImportedEntry], context: ModelContext) -> ImportResult {
        let cal = Calendar.current
        let byDay = Dictionary(grouping: rows) { cal.startOfDay(for: $0.date) }
        let existingDefs = (try? context.fetch(FetchDescriptor<ExerciseDef>())) ?? []
        var knownDefs = Dictionary(uniqueKeysWithValues: existingDefs.map { ($0.name, $0) })

        var sessionsCreated = 0
        var setsImported = 0

        for (day, dayRows) in byDay.sorted(by: { $0.key < $1.key }) {
            let session = WorkoutSession(date: day, dayLabel: "Imported", cycleNumber: 0)
            context.insert(session)
            sessionsCreated += 1

            for (order, entry) in dayRows.enumerated() {
                let log = ExerciseLog(exerciseName: entry.exerciseName, targetReps: entry.targetReps, order: order)
                log.session = session
                context.insert(log)

                for (i, pair) in zip(entry.weights, entry.reps).enumerated() {
                    let set = SetLog(index: i, weight: pair.0, reps: pair.1)
                    set.exerciseLog = log
                    context.insert(set)
                    setsImported += 1
                }

                if entry.targetReps.isEmpty {
                    ExerciseDef.ensureAnyVariantExists(name: entry.exerciseName, knownDefs: &knownDefs, context: context)
                } else {
                    ExerciseDef.ensureVariantExists(name: entry.exerciseName, targetReps: entry.targetReps,
                                                    knownDefs: &knownDefs, context: context)
                }
            }
        }

        try? context.save()
        return ImportResult(sessionsCreated: sessionsCreated, setsImported: setsImported)
    }

    // MARK: - CSV line splitting (quote-aware, handles embedded commas + "" escapes)

    private static func splitCSVLine(_ line: String) -> [String] {
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
            } else if c == "," {
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

    private static func parseDate(_ s: String) -> Date? {
        if let iso = ISO8601DateFormatter().date(from: s) { return iso }
        for f in dateFormatters {
            if let d = f.date(from: s) { return d }
        }
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

        // A bare integer might be a spreadsheet date serial rather than an
        // actual rep/weight value — real reps/weights never get this large.
        // Serials are timezone-agnostic day counts, so extract in UTC.
        if let serial = Int(s), let date = excelSerialDate(serial) {
            return monthDaySlashYear(date, calendar: utcCalendar)
        }
        // parseDate's formatters use the local timezone, so extract components
        // the same way to avoid shifting the day for users east/west of UTC.
        if let date = parseDate(s) {
            return monthDaySlashYear(date, calendar: .current)
        }
        return s
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
