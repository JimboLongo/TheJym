//
//  BackupEngine.swift
//  TheJym
//
//  Writes a full, self-contained .xlsx export into the user's backup
//  folder, verifies it by reading it back, and prunes old ones.
//
//  Three decisions worth stating, because each is the opposite of the
//  obvious one:
//
//  1. FULL export every time, never incremental. A versioned backup exists
//     so yesterday's file still works when today's data is wrong; an
//     incremental chain means one bad link destroys everything after it,
//     which is the opposite of the point. Deflate made this cheap — a full
//     export of the real store is ~76 KB.
//
//  2. VERIFY BY PARSING, not by checking `write` returned. The export and
//     import round trip is measured lossless (RealStoreRoundTripDiffTests),
//     so parsing the bytes back off disk proves the file is RESTORABLE
//     rather than merely present. A file that writes fine and parses to
//     nothing is the failure that would otherwise go unnoticed for months.
//
//  3. A FAILED FILE IS KEPT, renamed .corrupt, and the prune is SKIPPED
//     for that run. Silent corruption plus a prune that trusts it is the
//     one failure mode that destroys real history: delete-the-oldest, run
//     daily, and two weeks of bad writes erases everything good.
//

import Foundation
import SwiftData

@MainActor
enum BackupEngine {

    /// How long a backup stays current before a foreground launch writes a
    /// new one. Slightly under a day so a daily user doesn't drift past
    /// 24h and skip one.
    static let staleAfter: TimeInterval = 20 * 60 * 60

    /// Dailies kept, newest first. Monthlies (the 1st of each month) are
    /// promoted out of this count and kept separately.
    static let dailiesKept = 14
    static let monthliesKept = 12
    /// Failed writes kept. Capped because an unbounded pile of these in
    /// someone's iCloud Drive is its own problem — and because the COUNT
    /// is the signal, not the contents.
    static let corruptKept = 3

    static let latestFileName = "latest.xlsx"
    private static let prefix = "TheJym-"

    private static let fileDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // MARK: - Result

    struct Success {
        var fileName: String
        var byteCount: Int
        var rowCount: Int
        var prunedCount: Int
    }

    enum Failure: LocalizedError {
        case folder(BackupFolder.ResolveError)
        case writeFailed(String)
        /// Wrote, but reading it back didn't produce a usable workbook.
        case verifyFailed(parsedRows: Int, expectedRows: Int)

        var errorDescription: String? {
            switch self {
            case .folder(let e): return e.errorDescription
            case .writeFailed(let m): return "Couldn't write the backup: \(m)"
            case .verifyFailed(let got, let want):
                return "Backup verification failed: read back \(got) of \(want) rows"
            }
        }
    }

    // MARK: - Should we?

    /// True when there's a folder configured and the last SUCCESS is older
    /// than `staleAfter`. Deliberately keyed on the last success, not the
    /// last attempt — a run of failures must not suppress further tries.
    static func isDue(_ status: BackupStatus?, now: Date = .now) -> Bool {
        guard BackupFolder.isConfigured else { return false }
        guard let last = status?.lastSuccessAt else { return true }
        return now.timeIntervalSince(last) >= staleAfter
    }

    /// Runs a backup if a folder is configured, finding-or-creating the
    /// status row itself. For call sites that just want to say "something
    /// worth backing up happened" without owning the status.
    ///
    /// Silent when no folder is set: an automatic backup nobody asked for
    /// shouldn't nag at the end of a workout.
    @discardableResult
    static func runIfConfigured(context: ModelContext, force: Bool,
                                now: Date = .now) -> Result<Success, Failure>? {
        guard BackupFolder.isConfigured else { return nil }
        let existing = try? context.fetch(FetchDescriptor<BackupStatus>()).first
        let status = existing ?? {
            let created = BackupStatus()
            context.insert(created)
            return created
        }()
        guard force || isDue(status, now: now) else { return nil }
        return run(context: context, status: status, now: now)
    }

    // MARK: - Run

    /// Exports, writes, verifies, then prunes. Updates `status` either way.
    ///
    /// Order matters: the DATED file is written and verified first, and
    /// only a verified file is copied to latest.xlsx. latest.xlsx is the
    /// one filename carrying no date, so letting a bad write land there
    /// first would corrupt the single most obvious file to grab.
    @discardableResult
    static func run(context: ModelContext, status: BackupStatus,
                    now: Date = .now) -> Result<Success, Failure> {
        status.lastAttemptAt = now

        let data = ExportBuilder.workbook(from: context)
        let expectedRows = ExportBuilder.historyRows(from: context).count - 1  // minus header
        let outcome = write(data, expectedRows: expectedRows, now: now)

        switch outcome {
        case .success(let s):
            status.lastSuccessAt = now
            status.lastSuccessFileName = s.fileName
            status.lastSuccessByteCount = s.byteCount
            status.lastSuccessRowCount = s.rowCount
            status.lastFailureReason = nil
            status.lastFailureAt = nil
        case .failure(let f):
            status.lastFailureReason = f.errorDescription
            status.lastFailureAt = now
        }
        try? context.save()
        return outcome
    }

    /// The file half, split out from `run` so the FAILURE path is
    /// reachable from a test by handing it bytes that can't parse.
    ///
    /// That branch — keep the bad file, skip the prune — is the one
    /// protecting real history, and a test that can't actually enter it
    /// proves nothing about it.
    static func write(_ data: Data, expectedRows: Int,
                      now: Date = .now) -> Result<Success, Failure> {
        do {
            return try BackupFolder.withFolder { folder in
                let name = "\(prefix)\(fileDate.string(from: now)).xlsx"
                let dated = folder.appendingPathComponent(name)
                do {
                    try data.write(to: dated, options: .atomic)
                } catch {
                    return .failure(.writeFailed(error.localizedDescription))
                }

                // Verify from DISK, not from the Data we still hold — the
                // question is whether what landed is restorable.
                let parsedRows = verify(dated)
                guard parsedRows == expectedRows else {
                    quarantine(dated, in: folder)
                    return .failure(.verifyFailed(parsedRows: parsedRows,
                                                  expectedRows: expectedRows))
                }

                // Only now is it safe to replace the undated copy.
                let latest = folder.appendingPathComponent(latestFileName)
                try? FileManager.default.removeItem(at: latest)
                try? FileManager.default.copyItem(at: dated, to: latest)

                let pruned = prune(in: folder, now: now)
                return .success(Success(fileName: name, byteCount: data.count,
                                        rowCount: parsedRows, prunedCount: pruned))
            }
        } catch let e as BackupFolder.ResolveError {
            return .failure(.folder(e))
        } catch {
            return .failure(.writeFailed(error.localizedDescription))
        }
    }

    /// Rows the written file parses back to, or -1 if it doesn't parse at
    /// all. Uses the real import path, so this answers "could I restore
    /// from this", not "is this a file".
    private static func verify(_ url: URL) -> Int {
        guard let onDisk = try? Data(contentsOf: url),
              let wb = ImportEngine.parseWorkbook(xlsxData: onDisk),
              wb.isFullyAccounted
        else { return -1 }
        return wb.historyRows.count + wb.skipped.total
    }

    /// Keeps a file that failed verification, under a name that can't be
    /// mistaken for a backup. Keeping it is deliberate: a corrupt file is
    /// evidence, and deleting the evidence of a failure is how a backup
    /// system lies to you.
    private static func quarantine(_ url: URL, in folder: URL) {
        let stamp = Int(Date.now.timeIntervalSince1970)
        let dest = folder.appendingPathComponent("\(url.lastPathComponent).\(stamp).corrupt")
        try? FileManager.default.moveItem(at: url, to: dest)
        pruneCorrupt(in: folder)
    }

    // MARK: - Retention

    struct Listing {
        var dailies: [BackupFile] = []
        var monthlies: [BackupFile] = []
        var corrupt: [BackupFile] = []
        var latest: BackupFile?
        var totalBytes: Int { (dailies + monthlies + corrupt).reduce(0) { $0 + $1.byteCount } }
        var newest: BackupFile? { (dailies + monthlies).max { $0.date < $1.date } }
    }

    struct BackupFile: Identifiable, Hashable {
        var name: String
        var date: Date
        var byteCount: Int
        var id: String { name }
    }

    /// What's actually in the folder, read from the folder.
    ///
    /// The Settings screen shows THIS rather than a stored date. A stored
    /// date is a claim the app makes about itself; a directory listing is
    /// evidence. Only the listing catches a backup that stopped landing.
    static func listing(now: Date = .now) -> Listing? {
        try? BackupFolder.withFolder { folder in
            var out = Listing()
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            for url in urls {
                let name = url.lastPathComponent
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if name == latestFileName {
                    out.latest = BackupFile(name: name, date: modified(url), byteCount: size)
                } else if name.hasSuffix(".corrupt") {
                    out.corrupt.append(BackupFile(name: name, date: modified(url), byteCount: size))
                } else if let day = parsedDate(from: name) {
                    let file = BackupFile(name: name, date: day, byteCount: size)
                    if isMonthly(day) { out.monthlies.append(file) } else { out.dailies.append(file) }
                }
            }
            out.dailies.sort { $0.date > $1.date }
            out.monthlies.sort { $0.date > $1.date }
            out.corrupt.sort { $0.date > $1.date }
            return out
        }
    }

    /// Deletes only files THIS app wrote and can parse the date out of —
    /// never "the oldest file in the folder". It's the user's folder and
    /// may hold anything else.
    @discardableResult
    private static func prune(in folder: URL, now: Date) -> Int {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder,
                                                                 includingPropertiesForKeys: nil)) ?? []
        var dailies: [(URL, Date)] = []
        var monthlies: [(URL, Date)] = []
        for url in urls {
            guard url.lastPathComponent != latestFileName,
                  let day = parsedDate(from: url.lastPathComponent) else { continue }
            if isMonthly(day) { monthlies.append((url, day)) } else { dailies.append((url, day)) }
        }
        var removed = 0
        for group in [(dailies, dailiesKept), (monthlies, monthliesKept)] {
            let sorted = group.0.sorted { $0.1 > $1.1 }
            for (url, _) in sorted.dropFirst(group.1) {
                if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
            }
        }
        return removed
    }

    /// Caps the quarantined files. Their COUNT is the signal — several of
    /// them means something is persistently wrong — so the status line
    /// surfaces it while the folder stays bounded.
    private static func pruneCorrupt(in folder: URL) {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let corrupt = urls.filter { $0.lastPathComponent.hasSuffix(".corrupt") }
            .sorted { modified($0) > modified($1) }
        for url in corrupt.dropFirst(corruptKept) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Naming

    /// The 1st of the month is promoted to a monthly, so it survives past
    /// the 14-day daily window without a separate write.
    static func isMonthly(_ date: Date) -> Bool {
        Calendar.current.component(.day, from: date) == 1
    }

    static func parsedDate(from fileName: String) -> Date? {
        guard fileName.hasPrefix(prefix), fileName.hasSuffix(".xlsx") else { return nil }
        let stem = fileName.dropFirst(prefix.count).dropLast(".xlsx".count)
        return fileDate.date(from: String(stem))
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }
}
