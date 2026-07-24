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
            }
            .navigationTitle("Settings")
        }
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
