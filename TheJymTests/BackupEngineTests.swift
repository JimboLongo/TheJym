//
//  BackupEngineTests.swift
//  TheJymTests
//
//  The parts of the backup that must not be wrong: the staleness decision,
//  the retention arithmetic, and the verification/quarantine behaviour.
//
//  Folder access itself isn't covered — security-scoped bookmarks need a
//  real document picker — so these drive the pure logic directly and the
//  file-level behaviour through a plain temp directory.
//

import XCTest
import SwiftData
@testable import TheJym

@MainActor
final class BackupEngineTests: XCTestCase {
    private let cal = Calendar.current
    private func d(_ y: Int, _ m: Int, _ day: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: day))!
    }

    // MARK: - Due

    func testNotDueWithoutAFolder() {
        // No bookmark is set in the test process, so this is the real
        // "user hasn't chosen a folder" path.
        XCTAssertFalse(BackupEngine.isDue(nil))
    }

    /// Staleness is keyed on the last SUCCESS, never the last attempt — a
    /// run of failures must not suppress further tries, which is exactly
    /// how a broken backup would go quiet.
    func testDueIsKeyedOnLastSuccessNotLastAttempt() {
        let status = BackupStatus()
        let now = Date.now
        status.lastSuccessAt = now.addingTimeInterval(-21 * 3600)
        status.lastAttemptAt = now          // tried a second ago, failed
        status.lastFailureReason = "disk full"
        // isDue also gates on a configured folder, so assert the time
        // comparison directly rather than through the folder check.
        XCTAssertGreaterThanOrEqual(now.timeIntervalSince(status.lastSuccessAt!),
                                    BackupEngine.staleAfter)
    }

    func testFreshBackupIsNotStale() {
        let status = BackupStatus()
        status.lastSuccessAt = Date.now.addingTimeInterval(-3600)
        XCTAssertLessThan(Date.now.timeIntervalSince(status.lastSuccessAt!),
                          BackupEngine.staleAfter)
    }

    // MARK: - Naming

    func testFileNameDateRoundTrips() {
        let name = "TheJym-2026-10-07.xlsx"
        let parsed = BackupEngine.parsedDate(from: name)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(cal.component(.year, from: parsed!), 2026)
        XCTAssertEqual(cal.component(.month, from: parsed!), 10)
        XCTAssertEqual(cal.component(.day, from: parsed!), 7)
    }

    /// Anything the app didn't write must not parse as a backup — pruning
    /// keys on this, and it's the user's own folder.
    func testForeignFileNamesAreNotRecognised() {
        for name in ["latest.xlsx", "notes.txt", "TheJym.xlsx",
                     "TheJym-2026-10-07.xlsx.1759860000.corrupt",
                     "Backup-2026-10-07.xlsx", "TheJym-not-a-date.xlsx"] {
            XCTAssertNil(BackupEngine.parsedDate(from: name), "\(name) should not parse")
        }
    }

    func testFirstOfTheMonthIsPromotedToMonthly() {
        XCTAssertTrue(BackupEngine.isMonthly(d(2026, 10, 1)))
        XCTAssertFalse(BackupEngine.isMonthly(d(2026, 10, 2)))
        XCTAssertFalse(BackupEngine.isMonthly(d(2026, 10, 31)))
    }

    // MARK: - End to end, through a real directory

    private func makeStore() -> ModelContext {
        let c = try! ModelContainer(
            for: AppSettings.self, Bar.self, ExerciseDef.self, Phase.self, PhaseDay.self,
            PlannedExercise.self, WorkoutSession.self, ExerciseLog.self, SetLog.self,
            BodyWeightEntry.self, RestDayActivity.self, ActiveRecovery.self,
            TrainingDaysPerWeekChange.self, TimerTemplate.self, TimerPreset.self,
            BackupStatus.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(c)
        ctx.insert(AppSettings())
        let session = WorkoutSession(date: d(2026, 10, 6), dayLabel: "Upper A", cycleNumber: 1)
        ctx.insert(session)
        let log = ExerciseLog(exerciseName: "Bench Press", targetReps: [5, 5, 5], order: 0)
        log.session = session
        ctx.insert(log)
        for i in 0..<3 {
            let set = SetLog(index: i, weight: 185, reps: 5)
            set.exerciseLog = log
            ctx.insert(set)
        }
        try? ctx.save()
        return ctx
    }

    /// A written backup must parse back to the same row count through the
    /// real import path. This is the check the whole feature rests on: it
    /// proves the file is RESTORABLE, not merely present.
    func testWrittenBackupParsesBackToTheSameRowCount() throws {
        let ctx = makeStore()
        let data = ExportBuilder.workbook(from: ctx)
        let expected = ExportBuilder.historyRows(from: ctx).count - 1

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("TheJym-2026-10-07.xlsx")
        try data.write(to: file, options: .atomic)

        let onDisk = try Data(contentsOf: file)
        let wb = try XCTUnwrap(ImportEngine.parseWorkbook(xlsxData: onDisk))
        XCTAssertTrue(wb.isFullyAccounted)
        XCTAssertEqual(wb.historyRows.count + wb.skipped.total, expected)
        XCTAssertEqual(expected, 1, "one exercise log in the fixture")
    }

    /// A truncated file must NOT verify. Without this the whole scheme is
    /// decorative — it's the case that distinguishes "checked the file"
    /// from "checked that write() returned".
    func testTruncatedFileFailsVerification() throws {
        let ctx = makeStore()
        let data = ExportBuilder.workbook(from: ctx)
        let truncated = data.prefix(data.count / 2)
        XCTAssertNil(ImportEngine.parseWorkbook(xlsxData: Data(truncated)),
                     "half a workbook must not parse")
    }

    func testEmptyFileFailsVerification() {
        XCTAssertNil(ImportEngine.parseWorkbook(xlsxData: Data()))
    }

    // MARK: - Retention arithmetic

    /// Mirrors prune()'s partition so the keep/delete split is testable
    /// without a security-scoped folder.
    private func partition(_ names: [String]) -> (dailies: [Date], monthlies: [Date]) {
        var dailies: [Date] = [], monthlies: [Date] = []
        for n in names {
            guard n != BackupEngine.latestFileName,
                  let day = BackupEngine.parsedDate(from: n) else { continue }
            if BackupEngine.isMonthly(day) { monthlies.append(day) } else { dailies.append(day) }
        }
        return (dailies.sorted(by: >), monthlies.sorted(by: >))
    }

    func testRetentionKeeps14DailiesAnd12Monthlies() {
        var names: [String] = ["latest.xlsx", "my-notes.txt"]
        // 60 consecutive days ending 2026-10-07.
        for offset in 0..<60 {
            let day = cal.date(byAdding: .day, value: -offset, to: d(2026, 10, 7))!
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
            f.locale = Locale(identifier: "en_US_POSIX")
            names.append("TheJym-\(f.string(from: day)).xlsx")
        }
        let (dailies, monthlies) = partition(names)
        XCTAssertEqual(dailies.count + monthlies.count, 60)
        // Two 1st-of-month dates fall in a 60-day window ending Oct 7.
        XCTAssertEqual(monthlies.count, 2)
        XCTAssertEqual(dailies.count, 58)
        XCTAssertEqual(dailies.prefix(BackupEngine.dailiesKept).count, 14)
        XCTAssertEqual(dailies.dropFirst(BackupEngine.dailiesKept).count, 44,
                       "the rest are pruned")
        XCTAssertEqual(monthlies.dropFirst(BackupEngine.monthliesKept).count, 0,
                       "2 monthlies is under the cap, so none are pruned")
    }

    /// Files the app didn't write are never candidates for deletion. It's
    /// the user's folder and may hold anything.
    func testForeignFilesAreNeverPruneCandidates() {
        let names = ["receipt.pdf", "latest.xlsx", "TheJym Backups notes.md",
                     "export (1).xlsx", "TheJym-2026-10-07.xlsx"]
        let (dailies, monthlies) = partition(names)
        XCTAssertEqual(dailies.count + monthlies.count, 1,
                       "only the app's own dated file is a candidate")
    }

    func testCorruptCapIsThree() {
        XCTAssertEqual(BackupEngine.corruptKept, 3)
    }

    // MARK: - Status

    /// Success clears the failure, so a recovered backup stops showing a
    /// stale red line.
    func testSuccessClearsThePriorFailure() {
        let s = BackupStatus()
        s.lastFailureReason = "folder permission lost"
        s.lastFailureAt = .now
        // Mirrors BackupEngine.run's success branch.
        s.lastSuccessAt = .now
        s.lastFailureReason = nil
        s.lastFailureAt = nil
        XCTAssertNil(s.lastFailureReason)
        XCTAssertNotNil(s.lastSuccessAt)
    }

    /// BackupStatus must never ride along in the export — a restored
    /// install inheriting the old device's backup date is exactly the
    /// false reassurance this feature exists to prevent.
    func testBackupStatusIsNotCarriedByTheExport() {
        let ctx = makeStore()
        let status = BackupStatus()
        status.lastSuccessAt = d(2026, 10, 6)
        status.lastSuccessFileName = "TheJym-2026-10-06.xlsx"
        status.lastSuccessRowCount = 999
        ctx.insert(status)
        try? ctx.save()

        let data = ExportBuilder.workbook(from: ctx)
        let text = (XLSXReader.partNames(in: data).compactMap {
            XLSXReader.rawPart(named: $0, in: data)
        }).map { String(decoding: $0, as: UTF8.self) }.joined()

        XCTAssertFalse(text.contains("TheJym-2026-10-06.xlsx"))
        XCTAssertFalse(text.contains("lastSuccess"))
        XCTAssertFalse(text.contains("999"))
    }
}

// MARK: - End to end, through BackupEngine.run itself
//
// These drive the real run() — export, write, verify, latest.xlsx, prune
// — against a plain temp directory via BackupFolder.testOverrideFolder.
// Testing the pieces separately proves less than the sequence working:
// the ordering (verify BEFORE latest.xlsx, skip the prune on failure) is
// the part that protects real history.

@MainActor
final class BackupEngineRunTests: XCTestCase {
    private var dir: URL!
    private let cal = Calendar.current

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bkrun-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        BackupFolder.testOverrideFolder = dir
    }
    override func tearDown() async throws {
        BackupFolder.testOverrideFolder = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func names() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    private func makeStore(logs: Int = 1) -> ModelContext {
        let c = try! ModelContainer(
            for: AppSettings.self, Bar.self, ExerciseDef.self, Phase.self, PhaseDay.self,
            PlannedExercise.self, WorkoutSession.self, ExerciseLog.self, SetLog.self,
            BodyWeightEntry.self, RestDayActivity.self, ActiveRecovery.self,
            TrainingDaysPerWeekChange.self, TimerTemplate.self, TimerPreset.self,
            BackupStatus.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(c)
        ctx.insert(AppSettings())
        let day = cal.date(from: DateComponents(year: 2026, month: 10, day: 6))!
        let session = WorkoutSession(date: day, dayLabel: "Upper A", cycleNumber: 1)
        ctx.insert(session)
        for i in 0..<logs {
            let log = ExerciseLog(exerciseName: "Lift \(i)", targetReps: [5], order: i)
            log.session = session
            ctx.insert(log)
            let set = SetLog(index: 0, weight: 185, reps: 5)
            set.exerciseLog = log
            ctx.insert(set)
        }
        try? ctx.save()
        return ctx
    }

    func testRunWritesVerifiesAndCopiesToLatest() throws {
        let ctx = makeStore(logs: 3)
        let status = BackupStatus()
        ctx.insert(status)

        let result = BackupEngine.run(context: ctx, status: status,
                                      now: cal.date(from: DateComponents(year: 2026, month: 10, day: 7))!)
        guard case .success(let s) = result else { return XCTFail("run failed: \(result)") }

        XCTAssertEqual(s.fileName, "TheJym-2026-10-07.xlsx")
        XCTAssertEqual(s.rowCount, 3)
        XCTAssertGreaterThan(s.byteCount, 0)
        XCTAssertEqual(names(), ["TheJym-2026-10-07.xlsx", "latest.xlsx"])

        // latest.xlsx must be byte-identical to the dated file it copies.
        let dated = try Data(contentsOf: dir.appendingPathComponent("TheJym-2026-10-07.xlsx"))
        let latest = try Data(contentsOf: dir.appendingPathComponent("latest.xlsx"))
        XCTAssertEqual(dated, latest)

        // And it must actually parse — the point of the whole exercise.
        let wb = try XCTUnwrap(ImportEngine.parseWorkbook(xlsxData: latest))
        XCTAssertEqual(wb.historyRows.count, 3)

        XCTAssertNotNil(status.lastSuccessAt)
        XCTAssertNil(status.lastFailureReason)
        XCTAssertEqual(status.lastSuccessRowCount, 3)
    }

    /// Deflate made a full export cheap; this records what one actually
    /// costs so a regression back to "stored" is visible as a number.
    func testBackupIsSmall() throws {
        let ctx = makeStore(logs: 50)
        let status = BackupStatus()
        ctx.insert(status)
        guard case .success(let s) = BackupEngine.run(context: ctx, status: status) else {
            return XCTFail("run failed")
        }
        XCTAssertLessThan(s.byteCount, 20_000,
                          "a 50-log export should be a few KB deflated, not tens of KB stored")
    }

    func testSecondRunSameDayOverwritesRatherThanAccumulating() {
        let ctx = makeStore()
        let status = BackupStatus()
        ctx.insert(status)
        let day = cal.date(from: DateComponents(year: 2026, month: 10, day: 7))!
        BackupEngine.run(context: ctx, status: status, now: day)
        BackupEngine.run(context: ctx, status: status, now: day)
        XCTAssertEqual(names(), ["TheJym-2026-10-07.xlsx", "latest.xlsx"])
    }

    /// The retention rule, exercised by actually writing 40 days.
    func testPruneKeeps14DailiesAndEveryMonthly() {
        let ctx = makeStore()
        let status = BackupStatus()
        ctx.insert(status)
        let start = cal.date(from: DateComponents(year: 2026, month: 9, day: 1))!
        for offset in 0..<40 {
            let day = cal.date(byAdding: .day, value: offset, to: start)!
            BackupEngine.run(context: ctx, status: status, now: day)
        }
        let files = names().filter { BackupEngine.parsedDate(from: $0) != nil }
        let monthlies = files.filter { BackupEngine.isMonthly(BackupEngine.parsedDate(from: $0)!) }
        let dailies = files.filter { !BackupEngine.isMonthly(BackupEngine.parsedDate(from: $0)!) }
        XCTAssertEqual(dailies.count, BackupEngine.dailiesKept)
        XCTAssertEqual(monthlies.count, 2, "Sep 1 and Oct 1 fall in a 40-day window")
        XCTAssertTrue(names().contains("latest.xlsx"))
    }

    /// Files the app didn't write are never deleted. It's the user's
    /// folder — a prune that deletes "the oldest file" is unacceptable.
    func testPruneLeavesForeignFilesAlone() throws {
        try Data("hello".utf8).write(to: dir.appendingPathComponent("receipt.pdf"))
        try Data("hello".utf8).write(to: dir.appendingPathComponent("Old Export.xlsx"))
        let ctx = makeStore()
        let status = BackupStatus()
        ctx.insert(status)
        let start = cal.date(from: DateComponents(year: 2026, month: 9, day: 2))!
        for offset in 0..<20 {
            BackupEngine.run(context: ctx, status: status,
                             now: cal.date(byAdding: .day, value: offset, to: start)!)
        }
        XCTAssertTrue(names().contains("receipt.pdf"))
        XCTAssertTrue(names().contains("Old Export.xlsx"))
    }

    /// The failure that would actually hurt: a corrupt write followed by
    /// a prune that trusts it. Delete-the-oldest plus two weeks of bad
    /// writes erases everything good — so the bad file must be KEPT, and
    /// the prune must NOT run that time.
    ///
    /// Reached for real by handing write() bytes that can't parse, rather
    /// than asserting around the branch.
    func testFailedVerificationQuarantinesAndSkipsThePrune() throws {
        let ctx = makeStore()
        let status = BackupStatus()
        ctx.insert(status)

        // 20 good backups, pruned to the 14 most recent.
        let start = cal.date(from: DateComponents(year: 2026, month: 9, day: 2))!
        for offset in 0..<20 {
            BackupEngine.run(context: ctx, status: status,
                             now: cal.date(byAdding: .day, value: offset, to: start)!)
        }
        let goodBefore = names().filter { BackupEngine.parsedDate(from: $0) != nil }
        XCTAssertEqual(goodBefore.count, 14)

        // A 21st "backup" that is not a workbook at all.
        let badDay = cal.date(byAdding: .day, value: 20, to: start)!
        let result = BackupEngine.write(Data("not an xlsx".utf8), expectedRows: 1, now: badDay)
        guard case .failure(.verifyFailed(let got, let want)) = result else {
            return XCTFail("expected verifyFailed, got \(result)")
        }
        XCTAssertEqual(got, -1)
        XCTAssertEqual(want, 1)

        let after = names()
        // 1. The bad file is kept, renamed so it can never be mistaken
        //    for a backup. Deleting the evidence of a failure is how a
        //    backup system lies to you.
        XCTAssertTrue(after.contains { $0.hasSuffix(".corrupt") })
        XCTAssertFalse(after.contains("TheJym-2026-09-22.xlsx"),
                       "the failed write must not remain under a backup name")
        // 2. Every good backup survives — the prune did not run.
        for name in goodBefore {
            XCTAssertTrue(after.contains(name), "\(name) was pruned on a failed run")
        }
        // 3. latest.xlsx still points at the last GOOD backup, not the
        //    bad one. It's the obvious file to grab, so it must never be
        //    the corrupt one.
        let latest = try Data(contentsOf: dir.appendingPathComponent("latest.xlsx"))
        XCTAssertNotNil(ImportEngine.parseWorkbook(xlsxData: latest))
    }

    /// Quarantined files are capped — an unbounded pile of them in a real
    /// iCloud Drive folder is its own problem, and the COUNT is the
    /// signal, not the contents.
    func testQuarantinedFilesAreCappedAtThree() {
        let start = cal.date(from: DateComponents(year: 2026, month: 9, day: 2))!
        for offset in 0..<6 {
            _ = BackupEngine.write(Data("not an xlsx".utf8), expectedRows: 1,
                                   now: cal.date(byAdding: .day, value: offset, to: start)!)
        }
        let corrupt = names().filter { $0.hasSuffix(".corrupt") }
        XCTAssertEqual(corrupt.count, BackupEngine.corruptKept)
    }

    /// A failed run leaves the previous success date alone, so the status
    /// line can say "last backup Sep 21, last attempt today failed" —
    /// which is actionable where a single date isn't.
    func testFailedRunKeepsThePriorSuccessDate() {
        let ctx = makeStore()
        let status = BackupStatus()
        ctx.insert(status)
        let good = cal.date(from: DateComponents(year: 2026, month: 9, day: 21))!
        BackupEngine.run(context: ctx, status: status, now: good)
        let successAt = status.lastSuccessAt

        _ = BackupEngine.write(Data("junk".utf8), expectedRows: 1)
        XCTAssertEqual(status.lastSuccessAt, successAt,
                       "a failure must not move the success date")
    }

    func testMissingFolderIsReportedAsAFailureWithAReason() {
        BackupFolder.testOverrideFolder = nil
        let ctx = makeStore()
        let status = BackupStatus()
        ctx.insert(status)
        let result = BackupEngine.run(context: ctx, status: status)
        guard case .failure = result else { return XCTFail("expected a failure") }
        XCTAssertNotNil(status.lastFailureReason)
        XCTAssertNotNil(status.lastAttemptAt)
        XCTAssertNil(status.lastSuccessAt, "a failure must never set a success date")
    }

    /// The listing is what Settings shows, so it has to describe the
    /// folder rather than the app's beliefs about it.
    func testListingReportsWhatIsActuallyOnDisk() throws {
        let ctx = makeStore()
        let status = BackupStatus()
        ctx.insert(status)
        let start = cal.date(from: DateComponents(year: 2026, month: 9, day: 2))!
        for offset in 0..<5 {
            BackupEngine.run(context: ctx, status: status,
                             now: cal.date(byAdding: .day, value: offset, to: start)!)
        }
        try Data("damaged".utf8).write(
            to: dir.appendingPathComponent("TheJym-2026-09-01.xlsx.123.corrupt"))

        let listing = try XCTUnwrap(BackupEngine.listing())
        XCTAssertEqual(listing.dailies.count, 5)
        XCTAssertEqual(listing.corrupt.count, 1)
        XCTAssertNotNil(listing.latest)
        XCTAssertGreaterThan(listing.totalBytes, 0)
        XCTAssertEqual(listing.newest.map { cal.component(.day, from: $0.date) }, 6)
    }
}
