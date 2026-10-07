//
//  DayAttributionEngine.swift
//  TheJym
//
//  Proposes a PhaseDay for sessions that have none, by matching what was
//  logged against what the phase planned.
//
//  Built for one specific repair: the Oct 2026 recovery imported four
//  weeks of history from a spreadsheet that carried no Phase/Day/Cycle
//  columns, so 27 real sessions landed with `day == nil`. A session with
//  no day fills no cycle slot (Phase.cycleWalk filters on
//  `day != nil && cycleNumber > 0`), so the phase's cycle count, its
//  cycleCompletionDates, its restBankResetEvents and therefore the
//  Program Streak all stall.
//
//  Nothing here writes. The caller applies a proposal only after the user
//  confirms it, and can undo it.
//

import Foundation
import SwiftData

@MainActor
enum DayAttributionEngine {

    /// One session and the day being proposed for it.
    struct Proposal: Identifiable {
        let session: WorkoutSession
        let day: PhaseDay
        /// How many of the day's planned exercises this session logged,
        /// over how many it plans. nil for a rest-day proposal, which
        /// isn't a similarity judgement at all — see `isCertain`.
        let matched: Int?
        let plannedCount: Int?
        /// True when the match is a FACT rather than a similarity score:
        /// a session carrying a RestDayActivity belongs on a Rest slot
        /// because that's what a logged rest-day activity IS, not because
        /// its exercises happen to look alike.
        let isCertain: Bool
        var id: PersistentIdentifier { session.persistentModelID }

        var strengthText: String {
            guard let matched, let plannedCount else { return "rest day" }
            return "\(matched)/\(plannedCount)"
        }
        /// A partial match still imports, but should look weaker.
        var isWeak: Bool {
            guard let matched, let plannedCount, plannedCount > 0 else { return false }
            return Double(matched) / Double(plannedCount) < 1.0
        }
    }

    /// What applying a set of proposals would do to the phase's cycle
    /// count — computed by replaying Phase.cycleWalk's OWN algorithm over
    /// the proposed assignment rather than estimating, so the preview
    /// can't disagree with what actually happens.
    struct Projection {
        var filledBefore = 0, filledAfter = 0
        var cycleBefore = 1, cycleAfter = 1
        var totalSlots = 0
    }

    /// Candidate sessions for `phase`: unattributed, and dated inside the
    /// phase's OWN window.
    ///
    /// The window matters more than it looks. This store holds 165
    /// sessions from a 2025 CSV import whose days were never recorded and
    /// can't be recovered; an unwindowed proposal would sweep them into
    /// whichever phase it was run for. The upper bound is the next
    /// phase's start, so a session can only ever be offered to the phase
    /// whose dates contain it.
    static func candidates(for phase: Phase, in allPhases: [Phase],
                           cal: Calendar = .current) -> [WorkoutSession] {
        let start = cal.startOfDay(for: phase.startDate)
        let nextStart = allPhases
            .filter { $0.startDate > phase.startDate }
            .map { cal.startOfDay(for: $0.startDate) }
            .min()
        return phaseScopedSessions(allPhases: allPhases).filter { session in
            guard session.day == nil else { return false }
            let day = cal.startOfDay(for: session.date)
            guard day >= start else { return false }
            if let nextStart, day >= nextStart { return false }
            return true
        }
    }

    /// Every session in the store, reached through the phases' own
    /// relationship plus the unattached ones. Phase.sessions only holds
    /// sessions already pointing at it, and the whole point here is the
    /// ones that don't.
    private static var allSessionsOverride: [WorkoutSession]?
    static func withAllSessions<T>(_ sessions: [WorkoutSession], _ body: () -> T) -> T {
        allSessionsOverride = sessions
        defer { allSessionsOverride = nil }
        return body()
    }
    private static func phaseScopedSessions(allPhases: [Phase]) -> [WorkoutSession] {
        allSessionsOverride ?? allPhases.flatMap(\.sessions)
    }

    /// Best day for each candidate, or nothing when there's no evidence.
    ///
    /// Two different kinds of match, deliberately not blended:
    ///
    /// - A session with a RestDayActivity log goes to a Rest slot. That's
    ///   a fact about the session, so it's marked certain.
    /// - Anything else is scored by how many of its logged exercise names
    ///   appear in a day's plan. The best-scoring day wins, and a score of
    ///   zero proposes nothing rather than guessing.
    static func propose(for phase: Phase, sessions: [WorkoutSession]) -> [Proposal] {
        let restDays = phase.orderedDays.filter(\.isRest)
        let trainingDays = phase.orderedDays.filter { !$0.isRest }
        var restCursor = 0
        var out: [Proposal] = []

        for session in sessions.sorted(by: { $0.date < $1.date }) {
            let logs = session.exerciseLogs
            if logs.contains(where: { $0.restDayActivity != nil }) || logs.isEmpty {
                guard !restDays.isEmpty else { continue }
                // Rest slots alternate in rotation order, so consecutive
                // rest days land on different slots rather than all
                // piling onto the first one — a cycle needs BOTH filled.
                let day = restDays[restCursor % restDays.count]
                restCursor += 1
                out.append(Proposal(session: session, day: day, matched: nil,
                                    plannedCount: nil, isCertain: true))
                continue
            }
            let loggedNames = Set(logs.map(\.exerciseName))
            var best: (day: PhaseDay, hits: Int)?
            for day in trainingDays {
                let planned = Set(day.plannedExercises.map(\.exerciseName))
                let hits = loggedNames.intersection(planned).count
                if hits > (best?.hits ?? 0) { best = (day, hits) }
            }
            guard let best, best.hits > 0 else { continue }
            out.append(Proposal(session: session, day: best.day, matched: best.hits,
                                plannedCount: best.day.plannedExercises.count,
                                isCertain: false))
        }
        return out
    }

    /// Replays Phase.cycleWalk's slot-filling over the proposed
    /// assignment. Cycle numbers aren't set yet — repairMissingCycleNumbers
    /// stamps those on next launch — so this walks sessions in DATE order
    /// and advances a cycle each time every slot has been filled once,
    /// which is the same rule legacyCycleNumbers uses to assign them.
    static func project(phase: Phase, applying proposals: [Proposal]) -> Projection {
        var p = Projection()
        let slots = phase.orderedDays
        p.totalSlots = slots.count * phase.totalCycles
        guard !slots.isEmpty else { return p }

        p.filledBefore = phase.filledSlotCount
        p.cycleBefore = phase.currentCycle

        var assigned: [(date: Date, dayID: PersistentIdentifier)] =
            phase.sessions.compactMap { session in
                guard let id = session.day?.persistentModelID else { return nil }
                return (session.date, id)
            }
        assigned += proposals.map { ($0.session.date, $0.day.persistentModelID) }
        assigned.sort { $0.date < $1.date }

        var filled: Set<PersistentIdentifier> = []
        var completed = 0
        var distinctFills = 0
        for entry in assigned {
            if filled.contains(entry.dayID) { continue }   // a repeat within the cycle
            filled.insert(entry.dayID)
            distinctFills += 1
            if filled.count == slots.count {
                completed += 1
                filled = []
            }
        }
        p.filledAfter = distinctFills
        p.cycleAfter = min(completed + 1, phase.totalCycles)
        return p
    }

    /// What a session looked like before a proposal was applied, so the
    /// whole batch can be put back. In-memory only and single-shot: it
    /// covers "apply, look at the result, change my mind", not a general
    /// undo stack. A relaunch clears it — and relaunching is also when
    /// repairMissingCycleNumbers stamps cycle numbers, so the safe order
    /// is apply, check, then relaunch.
    struct Snapshot {
        let entries: [(session: WorkoutSession, phase: Phase?, day: PhaseDay?, cycleNumber: Int)]
        var count: Int { entries.count }
    }

    @discardableResult
    static func apply(_ proposals: [Proposal], to phase: Phase,
                      context: ModelContext) -> Snapshot {
        let snapshot = Snapshot(entries: proposals.map {
            ($0.session, $0.session.phase, $0.session.day, $0.session.cycleNumber)
        })
        for proposal in proposals {
            proposal.session.phase = phase
            proposal.session.day = proposal.day
            proposal.session.dayLabel = proposal.day.name
            // cycleNumber is deliberately NOT set here.
            // repairMissingCycleNumbers() already derives it on next
            // launch for exactly `day != nil && cycleNumber == 0`, using
            // the same date-ordered walk, so computing it twice would be
            // two things to keep agreeing.
        }
        try? context.save()
        return snapshot
    }

    static func revert(_ snapshot: Snapshot, context: ModelContext) {
        for entry in snapshot.entries {
            entry.session.phase = entry.phase
            entry.session.day = entry.day
            entry.session.cycleNumber = entry.cycleNumber
        }
        try? context.save()
    }
}
