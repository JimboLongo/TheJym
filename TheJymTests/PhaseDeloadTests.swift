//
//  PhaseDeloadTests.swift
//  TheJymTests
//
//  Covers Phase.isDeloadCycle/setDeload — the manual per-cycle toggle from
//  the Phases tab's Cycle N bar, layered on top of the existing single
//  AI-auto-scheduled deloadCycle.
//

import XCTest
import SwiftData
@testable import TheJym

final class PhaseDeloadTests: XCTestCase {
    @MainActor
    private func makeContext() -> ModelContext {
        let container = try! ModelContainer(
            for: Phase.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @MainActor
    func testManualToggleMarksACycleDeloadIndependentOfAISetting() {
        let phase = Phase(number: 1, totalCycles: 8)
        phase.setDeload(true, forCycle: 3)

        XCTAssertTrue(phase.isDeloadCycle(3, aiDeloadEnabled: false))
        XCTAssertTrue(phase.isDeloadCycle(3, aiDeloadEnabled: true))
        XCTAssertFalse(phase.isDeloadCycle(2, aiDeloadEnabled: true))
    }

    @MainActor
    func testMultipleCyclesCanBeManuallyDeloadAtOnce() {
        let phase = Phase(number: 1, totalCycles: 10)
        phase.setDeload(true, forCycle: 4)
        phase.setDeload(true, forCycle: 8)

        XCTAssertTrue(phase.isDeloadCycle(4, aiDeloadEnabled: false))
        XCTAssertTrue(phase.isDeloadCycle(8, aiDeloadEnabled: false))
        XCTAssertFalse(phase.isDeloadCycle(6, aiDeloadEnabled: false))
    }

    @MainActor
    func testTurningOffRemovesTheManualToggle() {
        let phase = Phase(number: 1, totalCycles: 8)
        phase.setDeload(true, forCycle: 3)
        phase.setDeload(false, forCycle: 3)

        XCTAssertFalse(phase.isDeloadCycle(3, aiDeloadEnabled: true))
    }

    @MainActor
    func testAIAutoScheduledCycleOnlyCountsWhileItsSettingIsOn() {
        let phase = Phase(number: 1, totalCycles: 8, deloadCycle: 6)

        XCTAssertTrue(phase.isDeloadCycle(6, aiDeloadEnabled: true))
        XCTAssertFalse(phase.isDeloadCycle(6, aiDeloadEnabled: false),
                       "the AI-scheduled cycle shouldn't count once Settings' Deload Weeks toggle is off")
    }

    @MainActor
    func testTurningOffTheAIScheduledCycleClearsItEvenWithAIEnabled() {
        let phase = Phase(number: 1, totalCycles: 8, deloadCycle: 6)
        phase.setDeload(false, forCycle: 6)

        XCTAssertFalse(phase.isDeloadCycle(6, aiDeloadEnabled: true),
                       "the toggle should be authoritative even over the legacy AI-scheduled cycle")
    }

    @MainActor
    func testCycleZeroIsNeverDeload() {
        let phase = Phase(number: 1, totalCycles: 8)
        phase.setDeload(true, forCycle: 0)
        XCTAssertFalse(phase.isDeloadCycle(0, aiDeloadEnabled: true))
    }
}
