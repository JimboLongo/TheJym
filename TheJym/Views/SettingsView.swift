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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var settingsList: [AppSettings]
    @Query private var sessions: [WorkoutSession]
    @Query private var exerciseDefs: [ExerciseDef]
    @Query private var phases: [Phase]
    @Query private var bars: [Bar]
    @Query private var bodyWeights: [BodyWeightEntry]
    @Query private var restActivities: [RestDayActivity]
    @Query private var activeRecoveries: [ActiveRecovery]
    @Query private var tdpwChanges: [TrainingDaysPerWeekChange]

    @State private var showingDeleteHistoryConfirm = false
    @State private var showingDeleteExercisesConfirm = false
    @State private var showingDeleteAllDataConfirm = false

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
                            Toggle("Custom Weight Increase Rule", isOn: Binding(
                                get: { s.customWeightIncreaseEnabled },
                                set: { s.customWeightIncreaseEnabled = $0; try? context.save() }))
                            if s.customWeightIncreaseEnabled {
                                Stepper("Beat target \(s.customWeightIncreaseStreak) time\(s.customWeightIncreaseStreak == 1 ? "" : "s") in a row",
                                       value: Binding(
                                           get: { s.customWeightIncreaseStreak },
                                           set: { s.customWeightIncreaseStreak = $0; try? context.save() }),
                                       in: 1...10)
                                Stepper("Increase by \(Formatters.trim(s.customWeightIncreaseAmount)) lbs",
                                       value: Binding(
                                           get: { s.customWeightIncreaseAmount },
                                           set: { s.customWeightIncreaseAmount = $0; try? context.save() }),
                                       in: 1.25...25, step: 1.25)
                            }
                        } footer: {
                            Text("Overrides the aggressiveness preset above with a flat rule: bump every set's weight by this amount once you've met or beaten every target rep this many sessions in a row at the same weight.")
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

                if let s = settingsList.first {
                    Section {
                        Toggle("Streak Reminders", isOn: Binding(
                            get: { s.streakRemindersEnabled },
                            set: { newValue in
                                s.streakRemindersEnabled = newValue
                                try? context.save()
                                if newValue {
                                    Task {
                                        await StreakNotificationManager.requestAuthorizationIfNeeded()
                                    }
                                } else {
                                    StreakNotificationManager.cancel()
                                }
                            }))
                        if s.streakRemindersEnabled {
                            Picker("Remind Me At", selection: Binding(
                                get: { s.streakReminderHour },
                                set: { s.streakReminderHour = $0; try? context.save() })) {
                                ForEach(0..<24, id: \.self) { hour in
                                    Text(Formatters.hourLabel(hour)).tag(hour)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    } footer: {
                        Text("A notification reminding you to log a workout or rest day, if you haven't yet that day — never fires once you have.")
                    }
                }

                if let s = settingsList.first {
                    Section {
                        Toggle("Weight Reminders", isOn: Binding(
                            get: { s.weightRemindersEnabled },
                            set: { newValue in
                                s.weightRemindersEnabled = newValue
                                try? context.save()
                                if newValue {
                                    Task {
                                        await StreakNotificationManager.requestAuthorizationIfNeeded()
                                    }
                                } else {
                                    WeightNotificationManager.cancel()
                                }
                            }))
                        if s.weightRemindersEnabled {
                            Picker("Remind Me At", selection: Binding(
                                get: { s.weightReminderHour },
                                set: { s.weightReminderHour = $0; try? context.save() })) {
                                ForEach(0..<24, id: \.self) { hour in
                                    Text(Formatters.hourLabel(hour)).tag(hour)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    } footer: {
                        Text("Weight is only ever logged to the nearest Monday — a notification on Monday reminding you to log it, if you haven't yet that week.")
                    }
                }

                Section {
                    if let url = exportXLSXURL {
                        ShareLink(item: url) {
                            Label("Export to Excel…", systemImage: "square.and.arrow.up")
                        }
                    } else {
                        Label("Export to Excel…", systemImage: "square.and.arrow.up")
                            .foregroundStyle(.secondary)
                    }
                    Button("Delete All History", role: .destructive) {
                        showingDeleteHistoryConfirm = true
                    }
                    .disabled(sessions.isEmpty)
                } footer: {
                    Text("Export saves a 3-tab .xlsx workbook: History (every logged workout plus weigh-ins), Exercises (your Exercises tab library — equipment, saved sets, notes), and Equipment (bars, dumbbells, bands, and plates owned). Delete All History permanently deletes every logged workout — Phases, exercises, and equipment are untouched.")
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

                Section {
                    Button("Delete All Data", role: .destructive) {
                        showingDeleteAllDataConfirm = true
                    }
                    .disabled(isAllDataEmpty)
                } footer: {
                    Text("Permanently deletes everything: logged history, exercises, equipment, Phases, body weight entries, and rest-day activity. Your app settings (this screen) are untouched. This can't be undone.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
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
            .confirmationDialog("Delete ALL data — every logged workout, exercise, piece of equipment, Phase, and body weight entry? This can't be undone.",
                                isPresented: $showingDeleteAllDataConfirm, titleVisibility: .visible) {
                Button("Delete All Data", role: .destructive) { deleteAllData() }
                Button("Cancel", role: .cancel) { }
            }
        }
    }

    private var isAllDataEmpty: Bool {
        sessions.isEmpty && exerciseDefs.isEmpty && phases.isEmpty && bars.isEmpty
            && bodyWeights.isEmpty && restActivities.isEmpty && activeRecoveries.isEmpty
    }

    /// Wipes every user-generated data type — history (sessions cascade to
    /// their logs/sets), Phases (cascade to their days/planned exercises),
    /// the exercise library, equipment, body weight, and rest-day activity —
    /// but leaves AppSettings (this screen's own toggles/preferences) alone.
    ///
    /// Deletes in stages with a save after each, rather than one massive
    /// delete-everything-then-save-once transaction — this app's history
    /// can span thousands of sessions/logs/sets plus Phases, PhaseDays, and
    /// ExerciseDefs all cross-referencing each other (nullify + cascade
    /// rules on both sides), and asking SwiftData to resolve that entire
    /// relationship graph in one save is exactly the kind of bulk operation
    /// that's crashed it before (see ImportEngine.checkpointInterval for
    /// the same defensive pattern on the import side). Sessions go first —
    /// by the time Phases are deleted, no session still references a
    /// PhaseDay/Phase for SwiftData to have to nullify mid-cascade.
    private func deleteAllData() {
        for session in sessions { context.delete(session) }
        try? context.save()
        for phase in phases { context.delete(phase) }
        try? context.save()
        for def in exerciseDefs { context.delete(def) }
        try? context.save()
        for bar in bars { context.delete(bar) }
        try? context.save()
        for entry in bodyWeights { context.delete(entry) }
        for activity in restActivities { context.delete(activity) }
        for recovery in activeRecoveries { context.delete(recovery) }
        for change in tdpwChanges { context.delete(change) }
        try? context.save()
    }

    private func deleteAllHistory() {
        for session in sessions { context.delete(session) }
        try? context.save()
    }

    private func deleteAllExercises() {
        for def in exerciseDefs { context.delete(def) }
        try? context.save()
    }

    /// Everything exportable, as a 3-tab .xlsx workbook, written to a temp
    /// file so it can be handed to ShareLink. Regenerated each time this is
    /// read; cheap enough at personal-history scale.
    ///
    /// - "History": every logged workout (Date, Exercise, Sets, Weights,
    ///   Reps — same columns ImportEngine reads for a workout row) plus
    ///   every body-weight entry, interleaved chronologically as
    ///   "Body Weight" pseudo-exercise rows.
    /// - "Exercises": the Exercises tab library — name, tagged equipment,
    ///   bodyweight flag, saved sets (rep schemes + rep-total targets),
    ///   and notes.
    /// - "Equipment": every Bar (barbells, dumbbell sets, bands — bands are
    ///   just a Bar with isDumbbell = true) and the plate sizes owned.
    private var exportXLSXURL: URL? {
        guard !sessions.isEmpty || !exerciseDefs.isEmpty || !bars.isEmpty else { return nil }
        let workbook = XLSXWriter.makeWorkbook(sheets: [
            ("History", historySheetRows),
            ("Exercises", exercisesSheetRows),
            ("Equipment", equipmentSheetRows),
        ])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TheJym-Export.xlsx")
        do {
            try workbook.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private var historySheetRows: [[XLSXCell]] {
        var rows: [[XLSXCell]] = [[.string("Date"), .string("Exercise"), .string("Sets"), .string("Weights"), .string("Reps")]]
        var dated: [(date: Date, row: [XLSXCell])] = []
        for session in sessions {
            let dateStr = Formatters.exportDate.string(from: session.date)
            for log in session.exerciseLogs.sorted(by: { $0.order < $1.order }) {
                let sortedSets = log.sortedSets
                guard !sortedSets.isEmpty else { continue }
                let weights = sortedSets.map { Formatters.trim($0.weight) }.joined(separator: "/")
                let reps = sortedSets.map { String($0.reps) }.joined(separator: "/")
                dated.append((session.date, [.string(dateStr), .string(log.exerciseName),
                                             .string(log.setsSummaryText), .string(weights), .string(reps)]))
            }
        }
        for entry in bodyWeights {
            let dateStr = Formatters.exportDate.string(from: entry.date)
            dated.append((entry.date, [.string(dateStr), .string("Body Weight"), .blank,
                                       .number(entry.weight), .blank]))
        }
        rows.append(contentsOf: dated.sorted { $0.date < $1.date }.map(\.row))
        return rows
    }

    private var exercisesSheetRows: [[XLSXCell]] {
        var rows: [[XLSXCell]] = [[.string("Exercise"), .string("Equipment"), .string("Bodyweight"), .string("Sets"), .string("Notes")]]
        for def in exerciseDefs.sorted(by: { $0.name < $1.name }) {
            let sets = (def.repSchemes.map { $0.map(String.init).joined(separator: "/") }
                        + def.repTotalTargets.map { "\($0) total" }).joined(separator: "; ")
            rows.append([.string(def.name), .string(def.equipment?.name ?? ""),
                        .string(def.isBodyweight ? "Yes" : "No"), .string(sets), .string(def.notes)])
        }
        return rows
    }

    private var equipmentSheetRows: [[XLSXCell]] {
        var rows: [[XLSXCell]] = [[.string("Name"), .string("Type"), .string("Weight"), .string("Sides"), .string("Dumbbell/Band Weights")]]
        for bar in bars.sorted(by: { $0.name < $1.name }) {
            rows.append([.string(bar.name), .string(bar.isDumbbell ? "Dumbbell/Band" : "Barbell"),
                        bar.isDumbbell ? .blank : .number(bar.weight),
                        bar.isDumbbell ? .blank : .int(bar.loadableSides),
                        .string(bar.dumbbellWeights.map { Formatters.trim($0) }.joined(separator: ", "))])
        }
        if let plates = settingsList.first?.availablePlateSizes, !plates.isEmpty {
            rows.append([.blank])
            rows.append([.string("Plates Owned"), .string(plates.map { Formatters.trim($0) }.joined(separator: ", "))])
        }
        return rows
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
                                            Text(slot.setsSummaryText)
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
