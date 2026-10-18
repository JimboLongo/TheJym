//
//  MacroCycleHeaderTests.swift
//  TheJymTests
//
//  The day count was printed six times under the old table — once per
//  row, almost always identical. It now sits in the section header, and
//  a row prints its own only when it disagrees.
//
//  The per-category counts are the point, not noise: a day you didn't
//  record fiber isn't a day you ate none. So the rule has to keep a
//  differing count visible while removing the repetition when they
//  agree, and these tests pin both halves of that.
//

import XCTest
import SwiftData
@testable import TheJym

@MainActor
final class MacroCycleHeaderTests: XCTestCase {
    private let cal = Calendar.current
    private lazy var anchor = cal.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
    private func day(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: anchor)! }

    private func makeContext() -> ModelContext {
        let c = try! ModelContainer(
            for: Phase.self, PhaseDay.self, WorkoutSession.self, ExerciseLog.self, SetLog.self,
            MacroTier.self, CycleMacroTag.self, MacroLog.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(c)
    }

    /// A phase with one tagged cycle and `days` of sessions, so
    /// MacroCycleSummary has a window to work in.
    private func summary(logs: [MacroLog], days: Int) -> MacroCycleSummary? {
        let ctx = makeContext()
        let phase = Phase(number: 1, totalCycles: 4, startDate: day(0), isActive: true)
        ctx.insert(phase)
        for (i, name) in ["Push", "Pull", "Rest"].enumerated() {
            let d = PhaseDay(order: i, name: name, isRest: name == "Rest")
            d.phase = phase
            ctx.insert(d)
        }
        let trainingDay = phase.orderedDays.first { !$0.isRest }
        for i in 0..<days {
            let s = WorkoutSession(date: day(i), dayLabel: "Push", cycleNumber: 1)
            s.phase = phase
            s.day = trainingDay
            ctx.insert(s)
            let log = ExerciseLog(exerciseName: "Bench Press", targetReps: [8], order: 0)
            log.session = s
            ctx.insert(log)
        }
        let tier = MacroTier(name: "2450", order: 0, proteinGrams: 185, carbsGrams: 260,
                             fatGrams: 75, sugarGrams: 40, fiberGrams: 30)
        ctx.insert(tier)
        let tag = CycleMacroTag(cycleNumber: 1, phase: phase, tier: tier)
        ctx.insert(tag)
        for l in logs { ctx.insert(l) }
        return MacroCycleSummary.compute(phase: phase, cycle: 1, logs: logs,
                                         now: day(days))
    }

    /// Every category logged on every day — the common case, and the one
    /// the hoist exists for.
    func testUniformCountsGoInTheHeaderAndLeaveTheRowsBare() throws {
        let logs = (0..<3).map {
            MacroLog(date: day($0), proteinGrams: 187, carbsGrams: 228,
                     fatGrams: 77, sugarGrams: 31, fiberGrams: 28)
        }
        let s = try XCTUnwrap(summary(logs: logs, days: 3))
        XCTAssertEqual(s.headerDayCount, 3)
        XCTAssertTrue(s.dayCountsAreUniform)
        XCTAssertEqual(Set(s.allDayCounts), [3], "all five categories plus calories")
    }

    /// A day with fiber missing. Fiber's count must stay visible — that
    /// is the whole reason per-category counts exist — while the other
    /// five keep quiet behind the header.
    func testAMissingCategoryKeepsItsOwnCountVisible() throws {
        var logs = (0..<3).map {
            MacroLog(date: day($0), proteinGrams: 187, carbsGrams: 228,
                     fatGrams: 77, sugarGrams: 31, fiberGrams: 28)
        }
        logs[2].fiberGrams = nil
        let s = try XCTUnwrap(summary(logs: logs, days: 3))
        XCTAssertEqual(s.headerDayCount, 3, "five of six rows still run over three days")
        XCTAssertFalse(s.dayCountsAreUniform)
        let fiber = try XCTUnwrap(s.variances.first { $0.category == .fiber })
        XCTAssertEqual(fiber.average.dayCount, 2, "and fiber says so itself")
    }

    /// Calories are stricter — only days with protein, carbs AND fat all
    /// present — so a partly logged day moves that count alone.
    func testAPartialDayMovesOnlyTheCalorieCount() throws {
        var logs = (0..<3).map {
            MacroLog(date: day($0), proteinGrams: 187, carbsGrams: 228,
                     fatGrams: 77, sugarGrams: 31, fiberGrams: 28)
        }
        logs[2].fatGrams = nil
        let s = try XCTUnwrap(summary(logs: logs, days: 3))
        XCTAssertEqual(s.calories.dayCount, 2, "day 2 has no fat, so it can't carry calories")
        XCTAssertEqual(s.headerDayCount, 3, "the mode, not the minimum")
        XCTAssertFalse(s.dayCountsAreUniform)
    }

    /// The header takes the MODE, so it stands for what most of the
    /// table is measured over rather than being dragged by one outlier.
    func testTheHeaderTakesTheModeNotTheExtremes() throws {
        var logs = (0..<4).map {
            MacroLog(date: day($0), proteinGrams: 187, carbsGrams: 228,
                     fatGrams: 77, sugarGrams: 31, fiberGrams: 28)
        }
        logs[3].sugarGrams = nil
        logs[3].fiberGrams = nil
        let s = try XCTUnwrap(summary(logs: logs, days: 4))
        XCTAssertEqual(s.headerDayCount, 4,
                       "protein, carbs, fat and calories all run over 4; sugar and fiber over 3")
    }
}
