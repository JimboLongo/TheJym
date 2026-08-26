//
//  PlannedExerciseLibraryMatchTests.swift
//  TheJymTests
//
//  Covers PlannedExercise.hasLibraryMatch — flags a phase's exercise/set
//  as broken once it no longer matches anything in the Exercises library
//  (renamed exercise, or a set removed from it).
//

import XCTest
@testable import TheJym

final class PlannedExerciseLibraryMatchTests: XCTestCase {
    func testMatchesWhenExerciseAndSetBothExistInLibrary() {
        let def = ExerciseDef(name: "Bench Press", repSchemes: [[5, 5, 5, 3, 3, 3]])
        let pe = PlannedExercise(order: 0, exerciseName: "Bench Press", targetReps: [5, 5, 5, 3, 3, 3])
        XCTAssertTrue(pe.hasLibraryMatch(in: [def]))
    }

    func testNoMatchWhenExerciseWasRenamed() {
        let def = ExerciseDef(name: "Barbell Bench Press", repSchemes: [[5, 5, 5, 3, 3, 3]])
        let pe = PlannedExercise(order: 0, exerciseName: "Bench Press", targetReps: [5, 5, 5, 3, 3, 3])
        XCTAssertFalse(pe.hasLibraryMatch(in: [def]))
    }

    func testNoMatchWhenTheSetWasRemovedFromTheExercise() {
        let def = ExerciseDef(name: "Bench Press", repSchemes: [[8, 8, 8]])
        let pe = PlannedExercise(order: 0, exerciseName: "Bench Press", targetReps: [5, 5, 5, 3, 3, 3])
        XCTAssertFalse(pe.hasLibraryMatch(in: [def]))
    }

    func testRepTotalMatchesByItsOwnTargetList() {
        let def = ExerciseDef(name: "Pull-Up", repTotalTargets: [40])
        let pe = PlannedExercise(order: 0, exerciseName: "Pull-Up", targetReps: [], goalType: .repTotal(target: 40))
        XCTAssertTrue(pe.hasLibraryMatch(in: [def]))
    }

    func testRepTotalNoMatchWhenTargetWasRemoved() {
        let def = ExerciseDef(name: "Pull-Up", repTotalTargets: [50])
        let pe = PlannedExercise(order: 0, exerciseName: "Pull-Up", targetReps: [], goalType: .repTotal(target: 40))
        XCTAssertFalse(pe.hasLibraryMatch(in: [def]))
    }

    func testNoMatchWhenLibraryIsEmpty() {
        let pe = PlannedExercise(order: 0, exerciseName: "Bench Press", targetReps: [5, 5, 5])
        XCTAssertFalse(pe.hasLibraryMatch(in: []))
    }
}
