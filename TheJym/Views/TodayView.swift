//
//  TodayView.swift
//  TheJym
//
//  Home of training: shows the active Phase, where you are in the cycle,
//  and launches today's workout. Also handles Phase completion -> AI plan
//  for the next Phase.
//

import SwiftUI
import SwiftData

struct TodayView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Phase.number, order: .reverse) private var phases: [Phase]
    @Query private var settingsList: [AppSettings]
    @Query(sort: \RestDayActivity.date, order: .reverse) private var restActivities: [RestDayActivity]

    @State private var showingPhaseSetup = false
    @State private var showingNextPhasePlanner = false
    @State private var newActivityText = ""

    private var activePhase: Phase? { phases.first(where: \.isActive) }
    private var settings: AppSettings? { settingsList.first }

    private var todaysActivities: [RestDayActivity] {
        restActivities.filter { Calendar.current.isDateInToday($0.date) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let phase = activePhase {
                    if phase.isComplete {
                        phaseCompleteSection(phase)
                    } else {
                        activePhaseSections(phase)
                    }
                } else {
                    noPhaseSection
                }

                restDayActivitySection
            }
            .navigationTitle("Train")
            .sheet(isPresented: $showingPhaseSetup) {
                PhaseSetupView(previousPhase: nil)
            }
            .sheet(isPresented: $showingNextPhasePlanner) {
                if let phase = activePhase {
                    NextPhasePlannerView(previousPhase: phase)
                }
            }
        }
    }

    @ViewBuilder
    private var noPhaseSection: some View {
        Section {
            ContentUnavailableView {
                Label("No Active Phase", systemImage: "calendar.badge.plus")
            } description: {
                Text("Set up your split (e.g. PPLRPPLR), pick your exercises, and choose how many cycles the phase runs.")
            } actions: {
                Button("Set Up Phase 1") { showingPhaseSetup = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private func activePhaseSections(_ phase: Phase) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Phase \(phase.number)").font(.title2.bold())
                    Spacer()
                    Text(phase.splitPattern)
                        .font(.system(.subheadline, design: .monospaced))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.thinMaterial, in: Capsule())
                }
                ProgressView(value: Double(phase.completedSessionCount),
                             total: Double(phase.trainingDaysPerCycle * phase.totalCycles))
                HStack {
                    Text("Cycle \(phase.currentCycle) of \(phase.totalCycles)")
                    if settings?.deloadWeeksEnabled == true, phase.deloadCycle == phase.currentCycle {
                        Label("Deload", systemImage: "arrow.down.heart")
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Text("\(phase.completedSessionCount) sessions logged")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            .padding(.vertical, 4)
        }

        Section("Up Next: Day \(phase.nextDayLetter)") {
            let plan = phase.plan(for: phase.nextDayLetter)
            if plan.isEmpty {
                Text("No exercises planned for day \(phase.nextDayLetter). Edit the phase to add some.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(plan, id: \.persistentModelID) { pe in
                    HStack {
                        Text(pe.exerciseName)
                        Spacer()
                        Text(pe.targetReps.map(String.init).joined(separator: "/"))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                NavigationLink {
                    WorkoutLogView(phase: phase, dayLetter: phase.nextDayLetter)
                } label: {
                    Label("Start Day \(phase.nextDayLetter) Workout", systemImage: "play.fill")
                        .font(.headline)
                }
            }
        }

        Section("Or pick a different day") {
            ForEach(phase.distinctTrainingLetters, id: \.self) { letter in
                NavigationLink("Day \(letter)") {
                    WorkoutLogView(phase: phase, dayLetter: letter)
                }
            }
        }
    }

    @ViewBuilder
    private func phaseCompleteSection(_ phase: Phase) -> some View {
        Section {
            ContentUnavailableView {
                Label("Phase \(phase.number) Complete 🎉", systemImage: "trophy.fill")
            } description: {
                Text("All \(phase.totalCycles) cycles done. Time to plan Phase \(phase.number + 1).")
            } actions: {
                if settings?.aiAssistantEnabled == true {
                    Button("Plan Phase \(phase.number + 1) with AI") { showingNextPhasePlanner = true }
                        .buttonStyle(.borderedProminent)
                }
                Button("Build Phase \(phase.number + 1) Manually") {
                    phase.isActive = false
                    showingPhaseSetup = true
                }
            }
        }
    }

    @ViewBuilder
    private var restDayActivitySection: some View {
        Section("Rest Day Activity") {
            Text("Log a walk or something light on an off day — it counts toward your streak, but skipping it on an actual rest day won't break one.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("e.g. Walk, Yoga, Bike Ride", text: $newActivityText)
                Button("Log") { logActivity() }
                    .buttonStyle(.borderedProminent)
                    .disabled(newActivityText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ForEach(todaysActivities, id: \.persistentModelID) { activity in
                Text(activity.name)
            }
            .onDelete { idx in
                for i in idx { context.delete(todaysActivities[i]) }
                try? context.save()
            }
        }
    }

    private func logActivity() {
        let trimmed = newActivityText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        context.insert(RestDayActivity(name: trimmed))
        try? context.save()
        newActivityText = ""
    }
}
