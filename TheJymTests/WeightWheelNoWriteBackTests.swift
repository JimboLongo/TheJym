//
//  WeightWheelNoWriteBackTests.swift
//  TheJymTests
//
//  The weight wheel snaps an off-step value onto its nearest offered row
//  for DISPLAY (nearestValue, in the Picker binding's `get`). This test
//  pins the thing that actually matters about that: merely rendering the
//  screen must not write the snapped value back into the draft.
//
//  It exists because bar-weight offsetting (and, before it, the
//  smallest-achievable-step change) both altered which values are on the
//  list, so a draft holding a previously-valid weight can now be off-list.
//  Losing a hand-entered 181 to a silent 180 on mere display would be a
//  real data bug, and a pure-function test of nearestValue alone can't
//  rule it out — only driving the actual SwiftUI Picker can.
//
//  Uses a real mutable Binding rather than .constant(), which would
//  silently swallow exactly the write-back this is looking for.
//

import XCTest
import SwiftUI
import SwiftData
@testable import TheJym

final class WeightWheelNoWriteBackTests: XCTestCase {
    @MainActor
    func testOpeningTheScreenDoesNotWriteBackTheSnappedValue() {
        let c = try! ModelContainer(
            for: WorkoutSession.self, ExerciseLog.self, SetLog.self, Bar.self,
            ExerciseDef.self, AppSettings.self, BodyWeightEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(c)
        let bar = Bar(name: "Barbell", weight: 45, loadableSides: 2)
        ctx.insert(bar)
        let def = ExerciseDef(name: "BB Squats")
        def.equipment = bar
        ctx.insert(def)
        try? ctx.save()

        // 181 is NOT on the new list (45 + k*2.5 never hits 181), 180 IS,
        // and "" is the blank case. All three must survive a full render.
        var draft = WorkoutLogView.ExerciseDraft(
            name: "BB Squats", targetReps: [8, 8, 8],
            sets: [WorkoutLogView.SetDraft(weightText: "181", repsText: ""),
                   WorkoutLogView.SetDraft(weightText: "180", repsText: ""),
                   WorkoutLogView.SetDraft(weightText: "", repsText: "")],
            goalType: .fixedSets, isBodyweight: false)
        draft.isExpanded = true

        // A real Binding over mutable storage — so a write-back would be
        // observable, unlike .constant() which would silently swallow it.
        final class Box { var d: WorkoutLogView.ExerciseDraft; init(_ d: WorkoutLogView.ExerciseDraft) { self.d = d } }
        let box = Box(draft)
        let binding = Binding<WorkoutLogView.ExerciseDraft>(
            get: { box.d }, set: { box.d = $0 })

        let root = NavigationStack {
            ExercisePageView(
                draft: binding, allLogs: [], exerciseDef: def,
                plateSizes: [45, 25, 10, 5, 2.5, 1.25], dumbbellIncrement: 5,
                pageHeight: 760, currentBodyweight: nil,
                currentPageID: .constant("ex-\(draft.id)"), allDrafts: [draft],
                isDeloadCycle: false, restTimeSeconds: 90, upperTargetReps: nil)
        }
        .modelContainer(c)

        let vc = UIHostingController(rootView: root)
        vc.view.frame = CGRect(x: 0, y: 0, width: 393, height: 850)
        vc.view.setNeedsLayout(); vc.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        vc.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        print("AFTER RENDER: [\(box.d.sets[0].weightText)] [\(box.d.sets[1].weightText)] [\(box.d.sets[2].weightText)]")
        XCTAssertEqual(box.d.sets[0].weightText, "181", "off-list 181 must not be rewritten to 180")
        XCTAssertEqual(box.d.sets[1].weightText, "180", "on-list 180 unchanged")
        XCTAssertEqual(box.d.sets[2].weightText, "", "blank must stay blank, not become 0 or 45")
    }
}
