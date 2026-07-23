//
//  ImportEngine.swift
//  TheJym
//
//  Bulk-import historical sets from a CSV (e.g. a Google Sheet exported/shared
//  as .csv) with Date, Exercise, Weight, Reps columns — any order, header
//  matched case-insensitively. One row = one set.
//

import Foundation
import SwiftData

enum ImportEngine {
    struct ImportedSet {
        let date: Date
        let exerciseName: String
        let weight: Double
        let reps: Int
    }

    struct ImportResult {
        var sessionsCreated: Int
        var setsImported: Int
    }

    /// Parses CSV text into rows, matching the header case-insensitively.
    /// Returns the parsed rows plus a count of data rows that didn't parse.
    static func parseRows(csv: String) -> (rows: [ImportedSet], skipped: Int) {
        let lines = csv.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }).map(String.init)
        guard let headerLine = lines.first else { return ([], 0) }
        let header = splitCSVLine(headerLine).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let dateIdx = header.firstIndex(where: { $0.hasPrefix("date") }),
              let exerciseIdx = header.firstIndex(where: { $0.hasPrefix("exercise") }),
              let weightIdx = header.firstIndex(where: { $0.hasPrefix("weight") }),
              let repsIdx = header.firstIndex(where: { $0.hasPrefix("rep") })
        else { return ([], 0) }

        var out: [ImportedSet] = []
        var skipped = 0
        for line in lines.dropFirst() {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let fields = splitCSVLine(line)
            guard fields.count > max(dateIdx, exerciseIdx, weightIdx, repsIdx) else { skipped += 1; continue }
            let name = fields[exerciseIdx].trimmingCharacters(in: .whitespaces)
            let dateStr = fields[dateIdx].trimmingCharacters(in: .whitespaces)
            let weightStr = fields[weightIdx].trimmingCharacters(in: .whitespaces)
            let repsStr = fields[repsIdx].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty,
                  let date = parseDate(dateStr),
                  let weight = Double(weightStr),
                  let reps = Int(repsStr)
            else { skipped += 1; continue }
            out.append(ImportedSet(date: date, exerciseName: name, weight: weight, reps: reps))
        }
        return (out, skipped)
    }

    /// Groups rows into one WorkoutSession per calendar day, one ExerciseLog per
    /// distinct exercise that day (in first-seen order), sets in row order.
    @MainActor
    static func importIntoStore(_ rows: [ImportedSet], context: ModelContext) -> ImportResult {
        let cal = Calendar.current
        let byDay = Dictionary(grouping: rows) { cal.startOfDay(for: $0.date) }
        var knownExerciseNames = Set((try? context.fetch(FetchDescriptor<ExerciseDef>()))?.map(\.name) ?? [])

        var sessionsCreated = 0
        var setsImported = 0

        for (day, dayRows) in byDay.sorted(by: { $0.key < $1.key }) {
            let session = WorkoutSession(date: day, dayLabel: "Imported", cycleNumber: 0)
            context.insert(session)
            sessionsCreated += 1

            var logIndexByName: [String: Int] = [:]
            var logs: [ExerciseLog] = []
            var setCounts: [Int: Int] = [:]

            for row in dayRows {
                let idx: Int
                if let existing = logIndexByName[row.exerciseName] {
                    idx = existing
                } else {
                    let log = ExerciseLog(exerciseName: row.exerciseName, targetReps: [], order: logs.count)
                    log.session = session
                    context.insert(log)
                    logs.append(log)
                    idx = logs.count - 1
                    logIndexByName[row.exerciseName] = idx
                    setCounts[idx] = 0
                    ExerciseDef.ensureAnyVariantExists(name: row.exerciseName, knownNames: &knownExerciseNames, context: context)
                }
                let setIndex = setCounts[idx] ?? 0
                let set = SetLog(index: setIndex, weight: row.weight, reps: row.reps)
                set.exerciseLog = logs[idx]
                context.insert(set)
                setCounts[idx] = setIndex + 1
                setsImported += 1
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
}
