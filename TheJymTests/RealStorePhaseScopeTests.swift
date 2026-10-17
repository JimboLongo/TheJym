//
//  RealStorePhaseScopeTests.swift
//  TheJymTests
//
//  StatsEngine.phaseBestStreak scopes its inputs two different ways, and
//  it has to: sessions carry a stored `phase` relationship, while
//  RestDayActivity and ActiveRecovery carry nothing but a date, so the
//  date window [startDate, next phase's startDate) is the only rule
//  available for those two.
//
//  The relationship is authoritative. 27 sessions in this store were
//  hand-attributed during recovery precisely BECAUSE their dates didn't
//  imply the right phase, so the window is a proxy for membership and
//  must never be allowed to overrule the record it stands in for.
//
//  Today the two agree. That is a fact about this data, not a property
//  of the design, and the difference matters: "they agree" is something
//  to be NOTIFIED of losing. So this test asserts the agreement against
//  the real store and NAMES the session that breaks it. A divergence is
//  then a failure to look at, not a silent re-resolution in favour of
//  whichever rule happened to be applied first.
//
//  ACKNOWLEDGING ONE. Hand-attributing a session against its date is a
//  legitimate thing to do, so this detector has an accept list — see
//  `acceptedDivergences`. A detector with no way to say "yes, that one
//  is deliberate" is a detector that eventually gets deleted instead of
//  read, which is strictly worse than a noisy one.
//
//  Three arms, all three tested:
//    - an UNACCEPTED divergence fails, with the full report
//    - an ACCEPTED one passes quietly
//    - an acknowledgement that no longer matches anything ALSO fails,
//      as stale. A list of exceptions nobody prunes is how a detector
//      stops meaning anything, so the list is required to stay honest
//      in both directions.
//
//  The list starts EMPTY and is deliberately not pre-populated: there
//  are no divergences today, and the empty list is the correct starting
//  state. The structure exists before it is needed, for the same reason
//  the scale-floor catalogue carries a string that can't be reached.
//
//  FAILS LOUDLY when the store copy isn't present, for the same reason
//  RealStoreRoundTripDiffTests does — a dormant correctness test that
//  reads green is worse than a failing one. Opting out deliberately
//  means creating a .allow-missing-store marker beside where the store
//  would be.
//
//  It never touches the original: the file is copied first, because
//  opening a store with SwiftData can migrate it.
//

import XCTest
import SwiftData
@testable import TheJym

@MainActor
final class RealStorePhaseScopeTests: XCTestCase {

    /// The host Mac's home, not the simulator's — see
    /// RealStoreRoundTripDiffTests for why SIMULATOR_HOST_HOME.
    private static var storeDirectory: URL {
        let env = ProcessInfo.processInfo.environment
        let home = env["SIMULATOR_HOST_HOME"] ?? env["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/TheJymTests", isDirectory: true)
    }

    private struct MissingRealStore: LocalizedError, CustomStringConvertible {
        let path: String
        let markerDirectory: String
        var description: String { errorDescription ?? "" }
        var errorDescription: String? {
            """

            ════════════════════════════════════════════════════════════════
            REAL-STORE PHASE-SCOPE TEST COULD NOT RUN.
            Whether the phase relationship and the date window still agree
            is currently UNVERIFIED.
            ════════════════════════════════════════════════════════════════

            No store file at:
              \(path)

            StatsEngine.phaseBestStreak trusts the stored phase
            relationship for sessions and a date window for rest days.
            This is what proves those two have not drifted apart on real
            history — a fixture cannot, because the sessions that would
            diverge are hand-attributed ones.

            To restore it, pull a fresh copy off the device:

              mkdir -p "$HOME/Library/Application Support/TheJymTests"
              xcrun devicectl device copy from \\
                --device 00008150-001640561410C01C \\
                --domain-type appDataContainer \\
                --domain-identifier com.jimbo.TheJym \\
                --source "Library/Application Support" \\
                --destination "$HOME/Library/Application Support/TheJymTests"

            Or opt out deliberately:
              touch "\(markerDirectory)/.allow-missing-store"

            """
        }
    }

    private func openCopy() throws -> ModelContext {
        let fm = FileManager.default
        let path = Self.storeDirectory.appendingPathComponent("default.store").path
        if !fm.fileExists(atPath: path) {
            let marker = Self.storeDirectory.appendingPathComponent(".allow-missing-store")
            if fm.fileExists(atPath: marker.path)
                || ProcessInfo.processInfo.environment["THEJYM_ALLOW_MISSING_STORE"] != nil {
                throw XCTSkip("Opt-out present — real-store phase-scope check deliberately skipped.")
            }
            throw MissingRealStore(path: path,
                                   markerDirectory: Self.storeDirectory.path)
        }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("phasescope-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let dest = tmp.appendingPathComponent("default.store")
        try fm.copyItem(at: URL(fileURLWithPath: path), to: dest)
        let container = try ModelContainer(
            for: AppSettings.self, Bar.self, ExerciseDef.self, Phase.self, PhaseDay.self,
            PlannedExercise.self, WorkoutSession.self, ExerciseLog.self, SetLog.self,
            BodyWeightEntry.self, RestDayActivity.self, ActiveRecovery.self,
            TrainingDaysPerWeekChange.self, TimerTemplate.self, TimerPreset.self,
            BackupStatus.self, MacroTier.self, CycleMacroTag.self, MacroLog.self,
            configurations: ModelConfiguration(url: dest))
        return ModelContext(container)
    }

    /// One deliberately hand-attributed session, acknowledged so the
    /// detector stays quiet about it.
    ///
    /// `date` is the session's own date formatted "d MMM yyyy" — the
    /// same spelling the failure report prints, so an entry can be
    /// copied straight out of a red run. `phaseNumber` and `dayLabel`
    /// disambiguate two sessions on one day.
    struct AcceptedDivergence {
        let phaseNumber: Int
        let date: String
        let dayLabel: String
        /// Why this one is correct despite its date. Required — an
        /// unexplained exception is the thing this list exists to avoid
        /// becoming.
        let reason: String

        var key: String { "\(phaseNumber)|\(date)|\(dayLabel)" }
    }

    /// EMPTY ON PURPOSE. There are no divergences in the store today.
    ///
    /// To accept one: run the failing test, copy the phase number, date
    /// and label out of its report, and add an entry with a one-line
    /// reason. To un-accept one: delete the entry — and note that if the
    /// divergence is already gone, the test will tell you to delete it
    /// rather than letting it sit here forever.
    static let acceptedDivergences: [AcceptedDivergence] = []

    /// Every exercise-bearing session attributed to a phase must also
    /// fall inside that phase's date window, unless it is on the accept
    /// list above. Failure names the session.
    func testTheRelationshipAndTheWindowAgree() throws {
        let ctx = try openCopy()
        let cal = Calendar.current
        let phases = try ctx.fetch(FetchDescriptor<Phase>()).sorted { $0.number < $1.number }
        let f = DateFormatter(); f.dateFormat = "d MMM yyyy"

        var checked = 0
        var found: [(key: String, line: String)] = []
        for phase in phases {
            let start = cal.startOfDay(for: phase.startDate)
            let ceiling = phases
                .filter { $0.startDate > phase.startDate }
                .map { cal.startOfDay(for: $0.startDate) }
                .min()
            for session in phase.sessions where !session.exerciseLogs.isEmpty {
                checked += 1
                let day = cal.startOfDay(for: session.date)
                let inside = day >= start && (ceiling.map { day < $0 } ?? true)
                if !inside {
                    let dateText = f.string(from: session.date)
                    found.append((
                        key: "\(phase.number)|\(dateText)|\(session.dayLabel)",
                        line: "  Phase \(phase.number) [\(f.string(from: start))"
                            + " – \(ceiling.map(f.string(from:)) ?? "open"))"
                            + "  <-  \"\(session.dayLabel)\" on \(dateText)"
                            + " (cycle \(session.cycleNumber))"))
                }
            }
        }

        XCTAssertGreaterThan(checked, 0, "no attributed sessions found — is this the right store?")

        let acceptedKeys = Set(Self.acceptedDivergences.map(\.key))
        let foundKeys = Set(found.map(\.key))

        // ARM 1 — a divergence nobody has acknowledged.
        let unaccepted = found.filter { !acceptedKeys.contains($0.key) }
        XCTAssertTrue(unaccepted.isEmpty,
                      """

                      The phase RELATIONSHIP and the date WINDOW now disagree on \
                      \(unaccepted.count) of \(checked) attributed sessions:

                      \(unaccepted.map(\.line).joined(separator: "\n"))

                      This is a notification, not necessarily a bug. \
                      StatsEngine.phaseBestStreak trusts the relationship for \
                      sessions, so those sessions still count toward the phase \
                      they are attributed to — but the rest days around them are \
                      scoped by the window, so the two inputs now describe \
                      different spans. Decide which is right for these sessions \
                      before changing anything.

                      If a line above is a deliberate hand-attribution, add it to \
                      RealStorePhaseScopeTests.acceptedDivergences with a one-line \
                      reason, in the form:

                        AcceptedDivergence(phaseNumber: 1, date: "28 Aug 2026",
                                           dayLabel: "Push Day",
                                           reason: "…")
                      """)

        // ARM 3 — an acknowledgement that no longer matches anything.
        // Just as important as arm 1: an accept list nobody prunes stops
        // describing the store and starts hiding whatever drifts into
        // its shape later.
        let stale = Self.acceptedDivergences.filter { !foundKeys.contains($0.key) }
        XCTAssertTrue(stale.isEmpty,
                      """

                      \(stale.count) acknowledged divergence\(stale.count == 1 ? "" : "s") in \
                      RealStorePhaseScopeTests.acceptedDivergences no longer \
                      exist\(stale.count == 1 ? "s" : "") in the store:

                      \(stale.map { "  Phase \($0.phaseNumber)  \"\($0.dayLabel)\" on \($0.date)"
                                      + "\n      reason given: \($0.reason)" }
                              .joined(separator: "\n"))

                      Delete \(stale.count == 1 ? "it" : "them"). An exception list \
                      nobody prunes is how this detector stops meaning anything — \
                      a stale entry silently pre-approves any future divergence \
                      that happens to land on the same phase, date and label.
                      """)
    }

    /// The headline numbers, computed through the real engine against
    /// the real store, so the offsets baked into
    /// ProgramStreakAcceptanceTests can be caught drifting from reality.
    /// Phase-by-phase, this is what the per-phase screen shows.
    func testPerPhaseBestStreakMatchesTheAcceptanceFigures() throws {
        let ctx = try openCopy()
        let phases = try ctx.fetch(FetchDescriptor<Phase>()).sorted { $0.number < $1.number }
        let restActivities = try ctx.fetch(FetchDescriptor<RestDayActivity>())
        let recoveries = try ctx.fetch(FetchDescriptor<ActiveRecovery>())
        // Fixed, so an active phase's walk doesn't drift with the clock.
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 17,
                                                             hour: 12))!
        let expected = [1: 45, 2: 48, 3: 2]
        for phase in phases {
            guard let want = expected[phase.number] else { continue }
            let r = StatsEngine.phaseBestStreak(phase: phase, allPhases: phases,
                                                restActivities: restActivities,
                                                activeRecoveries: recoveries, now: now)
            XCTAssertEqual(r.maxStreak, want,
                           "Phase \(phase.number) Best Streak — the acceptance figure is \(want). "
                           + "If this moved because you logged more training, update the figure "
                           + "and ProgramStreakAcceptanceTests together.")
        }
    }
}
