//
//  CreditYesterdayAsRestTests.swift
//  TheJymTests
//
//  Verifies WorkoutSession.creditYesterdayAsRestIfNothingLogged: credits
//  yesterday as a rest day (ActiveRecovery + no-activity session) only when
//  literally nothing was logged for it — a real session, a rest-day
//  activity, or a plain rest credit already there all mean it leaves
//  yesterday alone.
//

import XCTest
import SwiftData
@testable import TheJym

final class CreditYesterdayAsRestTests: XCTestCase {
    @MainActor
    private func makeContext() -> ModelContext {
        let container = try! ModelContainer(
            for: AppSettings.self, Bar.self, ExerciseDef.self,
                 Phase.self, PhaseDay.self, PlannedExercise.self,
                 WorkoutSession.self, ExerciseLog.self, SetLog.self,
                 BodyWeightEntry.self, RestDayActivity.self,
                 ActiveRecovery.self, TrainingDaysPerWeekChange.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @MainActor
    func testCreditsYesterdayWhenNothingWasLogged() {
        let context = makeContext()
        WorkoutSession.creditYesterdayAsRestIfNothingLogged(context: context)

        let sessions = (try? context.fetch(FetchDescriptor<WorkoutSession>())) ?? []
        let recoveries = (try? context.fetch(FetchDescriptor<ActiveRecovery>())) ?? []
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.dayLabel, "Rest Day")
        XCTAssertEqual(recoveries.count, 1)
        XCTAssertEqual(recoveries.first?.type, .rest)

        let cal = Calendar.current
        let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date()))!
        XCTAssertTrue(cal.isDate(sessions.first!.date, inSameDayAs: yesterday))
    }

    @MainActor
    func testDoesNothingWhenARealSessionAlreadyExistsYesterday() {
        let context = makeContext()
        let cal = Calendar.current
        let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date()))!
        context.insert(WorkoutSession(date: yesterday, dayLabel: "Push A", cycleNumber: 0))
        try? context.save()

        WorkoutSession.creditYesterdayAsRestIfNothingLogged(context: context)

        let sessions = (try? context.fetch(FetchDescriptor<WorkoutSession>())) ?? []
        let recoveries = (try? context.fetch(FetchDescriptor<ActiveRecovery>())) ?? []
        XCTAssertEqual(sessions.count, 1, "No extra rest-day session should be added")
        XCTAssertEqual(recoveries.count, 0)
    }

    @MainActor
    func testDoesNothingWhenAPlainRestCreditAlreadyExistsYesterday() {
        let context = makeContext()
        let cal = Calendar.current
        let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date()))!
        context.insert(ActiveRecovery(date: yesterday, type: .rest))
        try? context.save()

        WorkoutSession.creditYesterdayAsRestIfNothingLogged(context: context)

        let sessions = (try? context.fetch(FetchDescriptor<WorkoutSession>())) ?? []
        let recoveries = (try? context.fetch(FetchDescriptor<ActiveRecovery>())) ?? []
        XCTAssertEqual(sessions.count, 0, "Shouldn't add a session when a rest credit already covers yesterday")
        XCTAssertEqual(recoveries.count, 1, "Shouldn't add a duplicate credit")
    }
}
