//
//  SettingsView.swift
//  TheJym
//
//  AI Assistant toggle + aggressiveness, deload toggle, optional Gemini key,
//  training start date lives in Stats.
//

import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Query private var settingsList: [AppSettings]
    @Query private var sessions: [WorkoutSession]
    @Query private var exerciseDefs: [ExerciseDef]
    @Query private var phases: [Phase]

    @State private var showingDeleteHistoryConfirm = false
    @State private var showingDeleteExercisesConfirm = false

    private var activePhase: Phase? { phases.first(where: \.isActive) }

    private func setTrainingDaysPerWeek(_ value: Int) {
        settingsList.first?.trainingDaysPerWeek = value
        context.insert(TrainingDaysPerWeekChange(trainingDaysPerWeek: value))
        try? context.save()
    }

    var body: some View {
        NavigationStack {
            Form {
                if let s = settingsList.first {
                    Section {
                        Toggle("AI Assistant", isOn: Binding(
                            get: { s.aiAssistantEnabled },
                            set: { s.aiAssistantEnabled = $0; try? context.save() }))
                    } footer: {
                        Text("When on: suggests next-cycle weights after each workout, plans your next Phase when one ends, and (if enabled below) schedules deload weeks. You can always override its suggestions.")
                    }

                    if s.aiAssistantEnabled {
                        Section("Progression Aggressiveness") {
                            Picker("Aggressiveness", selection: Binding(
                                get: { s.aiAggressiveness },
                                set: { s.aiAggressiveness = $0; try? context.save() })) {
                                ForEach(AIAggressiveness.allCases) { a in
                                    Text(a.label).tag(a)
                                }
                            }
                            .pickerStyle(.segmented)
                            Text(s.aiAggressiveness.detail)
                                .font(.caption).foregroundStyle(.secondary)
                        }

                        Section {
                            Toggle("Deload Weeks", isOn: Binding(
                                get: { s.deloadWeeksEnabled },
                                set: { s.deloadWeeksEnabled = $0; try? context.save() }))
                        } footer: {
                            Text("AI schedules one deload cycle per phase (phases of 4+ cycles), placed at the end of the block. Weights drop to ~60% of your last logged loads so accumulated fatigue dissipates before the next phase — you keep the fitness, shed the fatigue.")
                        }

                        Section {
                            Toggle("Use Gemini for Phase Planning", isOn: Binding(
                                get: { s.useGeminiForPhasePlanning },
                                set: { s.useGeminiForPhasePlanning = $0; try? context.save() }))
                            if s.useGeminiForPhasePlanning {
                                SecureField("Gemini API Key", text: Binding(
                                    get: { s.geminiAPIKey },
                                    set: { s.geminiAPIKey = $0; try? context.save() }))
                            }
                        } footer: {
                            Text("Optional. Free key from aistudio.google.com. Without it, the built-in on-device planner is used (no network, no cost).")
                        }
                    }
                }

                if activePhase == nil, let s = settingsList.first {
                    Section {
                        Picker("Training Days Per Week", selection: Binding(
                            get: { s.trainingDaysPerWeek },
                            set: { setTrainingDaysPerWeek($0) })) {
                            ForEach(1...7, id: \.self) { n in
                                Text("\(n)").tag(n)
                            }
                        }
                        .pickerStyle(.menu)
                    } footer: {
                        Text("Used to pace the rest-bank streak when no Phase is active — a Phase's own split determines this automatically once one is running.")
                    }
                }

                Section {
                    if let url = exportCSVURL {
                        ShareLink(item: url) {
                            Label("Export History to CSV…", systemImage: "square.and.arrow.up")
                        }
                    } else {
                        Label("Export History to CSV…", systemImage: "square.and.arrow.up")
                            .foregroundStyle(.secondary)
                    }
                    Button("Delete All History", role: .destructive) {
                        showingDeleteHistoryConfirm = true
                    }
                    .disabled(sessions.isEmpty)
                } footer: {
                    Text("Export saves every logged workout as a .csv file (same format the importer expects, so it doubles as a backup). Delete All History permanently deletes every logged workout — Phases, exercises, and equipment are untouched.")
                }

                if let s = settingsList.first {
                    Section {
                        Toggle("Include Default Exercises", isOn: Binding(
                            get: { s.includeDefaultExercises },
                            set: { s.includeDefaultExercises = $0; try? context.save() }))
                    } footer: {
                        Text("When on, the built-in starter library (Bench Press, Back Squat, etc.) is seeded into the Exercises tab whenever it's empty. Turn off to keep it from coming back after Delete All Exercises — it won't remove anything already there.")
                    }
                }

                Section {
                    Button("Delete All Exercises", role: .destructive) {
                        showingDeleteExercisesConfirm = true
                    }
                    .disabled(exerciseDefs.isEmpty)
                } footer: {
                    Text("Permanently deletes every exercise from the Exercises tab library (names, saved sets, equipment tags, bodyweight flags). Logged history and Phase plans are untouched — they'll just reference exercises no longer in the library.")
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Delete all \(sessions.count) logged workout\(sessions.count == 1 ? "" : "s")? This can't be undone.",
                                isPresented: $showingDeleteHistoryConfirm, titleVisibility: .visible) {
                Button("Delete All History", role: .destructive) { deleteAllHistory() }
                Button("Cancel", role: .cancel) { }
            }
            .confirmationDialog("Delete all \(exerciseDefs.count) exercise\(exerciseDefs.count == 1 ? "" : "s") from the library? This can't be undone.",
                                isPresented: $showingDeleteExercisesConfirm, titleVisibility: .visible) {
                Button("Delete All Exercises", role: .destructive) { deleteAllExercises() }
                Button("Cancel", role: .cancel) { }
            }
        }
    }

    private func deleteAllHistory() {
        for session in sessions { context.delete(session) }
        try? context.save()
    }

    private func deleteAllExercises() {
        for def in exerciseDefs { context.delete(def) }
        try? context.save()
    }

    /// Every logged workout as a CSV file (Date, Exercise, Sets, Weights,
    /// Reps — same columns ImportEngine reads), written to a temp file so it
    /// can be handed to ShareLink. Regenerated each time this is read;
    /// cheap enough at personal-history scale.
    private var exportCSVURL: URL? {
        guard !sessions.isEmpty else { return nil }
        var lines = ["Date,Exercise,Sets,Weights,Reps"]
        for session in sessions.sorted(by: { $0.date < $1.date }) {
            let dateStr = Formatters.exportDate.string(from: session.date)
            for log in session.exerciseLogs.sorted(by: { $0.order < $1.order }) {
                let sortedSets = log.sortedSets
                guard !sortedSets.isEmpty else { continue }
                let sets = log.targetReps.map(String.init).joined(separator: "/")
                let weights = sortedSets.map { Formatters.trim($0.weight) }.joined(separator: "/")
                let reps = sortedSets.map { String($0.reps) }.joined(separator: "/")
                lines.append([dateStr, log.exerciseName, sets, weights, reps].map(csvField).joined(separator: ","))
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TheJym-History.csv")
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private func csvField(_ s: String) -> String {
        guard s.contains(",") || s.contains("\"") || s.contains("\n") else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

// MARK: - Next Phase Planner (shown when a phase completes)

struct NextPhasePlannerView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var settingsList: [AppSettings]

    let previousPhase: Phase

    @State private var plan: [String: [ProgressionEngine.PlannedSlot]] = [:]
    @State private var loading = true
    @State private var usedGemini = false
    @State private var showSetup = false

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("Analyzing Phase \(previousPhase.number)…")
                } else {
                    List {
                        Section {
                            Text(usedGemini
                                 ? "Planned by Gemini from your Phase \(previousPhase.number) logs. Review, then edit anything on the next screen."
                                 : "Planned on-device from your Phase \(previousPhase.number) logs. Review, then edit anything on the next screen.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(plan.keys.sorted(), id: \.self) { dayName in
                            Section(dayName) {
                                ForEach(plan[dayName] ?? [], id: \.exerciseName) { slot in
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack {
                                            Text(slot.exerciseName).font(.headline)
                                            Spacer()
                                            Text(slot.targetReps.map(String.init).joined(separator: "/"))
                                                .font(.system(.caption, design: .monospaced))
                                        }
                                        if !slot.startingWeights.isEmpty {
                                            Text("Start @ \(slot.startingWeights.map { Formatters.trim($0) }.joined(separator: "/"))")
                                                .font(.system(.caption2, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                        }
                                        Text(slot.rationale)
                                            .font(.caption2).foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                        Section {
                            Button("Continue to Edit & Start Phase \(previousPhase.number + 1)") {
                                previousPhase.isActive = false
                                try? context.save()
                                showSetup = true
                            }
                            .font(.headline)
                        }
                    }
                }
            }
            .navigationTitle("Phase \(previousPhase.number + 1) Plan")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task { await buildPlan() }
            .sheet(isPresented: $showSetup, onDismiss: { dismiss() }) {
                PhaseBuilderView(previousPhase: previousPhase, seededPlan: plan)
            }
        }
    }

    private func buildPlan() async {
        defer { loading = false }
        let settings = settingsList.first

        if settings?.useGeminiForPhasePlanning == true,
           let key = settings?.geminiAPIKey, !key.isEmpty {
            do {
                let slots = try await GeminiPhasePlanner(apiKey: key)
                    .planNextPhase(previousPhase: previousPhase)
                var grouped: [String: [ProgressionEngine.PlannedSlot]] = [:]
                for s in slots {
                    grouped[s.dayName, default: []].append(
                        .init(exerciseName: s.exerciseName,
                              targetReps: s.targetReps,
                              startingWeights: s.startingWeights,
                              rationale: s.rationale))
                }
                if !grouped.isEmpty {
                    plan = grouped
                    usedGemini = true
                    return
                }
            } catch {
                // fall through to on-device planner
            }
        }
        plan = ProgressionEngine.planNextPhase(previousPhase: previousPhase)
        usedGemini = false
    }
}
