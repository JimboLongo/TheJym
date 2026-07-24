//
//  WorkoutLogView.swift
//  TheJym
//
//  Log a session. For each exercise, shows the three comparison workouts
//  (last time / best at these weights / all-time best for this plan) with
//  dates, totals, and the reps you need next set to stay on pace to beat each.
//  On finish, the AI Assistant suggests next-cycle weights (overridable).
//

import SwiftUI
import SwiftData

struct WorkoutLogView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var settingsList: [AppSettings]
    @Query private var allExerciseLogs: [ExerciseLog]
    @Query(sort: \ExerciseDef.name) private var exerciseDefs: [ExerciseDef]

    let phase: Phase
    let day: PhaseDay

    @State private var drafts: [ExerciseDraft] = []
    @State private var showFinishSheet = false
    @State private var aiSuggestions: [AISuggestionRow] = []

    private var settings: AppSettings? { settingsList.first }
    private var isDeloadCycle: Bool {
        settings?.deloadWeeksEnabled == true && phase.deloadCycle == phase.currentCycle
    }

    // MARK: Draft state

    struct SetDraft: Identifiable {
        let id = UUID()
        var weightText: String
        var repsText: String
        var weight: Double? { Double(weightText) }
        var reps: Int? { Int(repsText) }
        var isLogged: Bool { weight != nil && reps != nil }
    }

    struct ExerciseDraft: Identifiable {
        let id = UUID()
        var name: String
        var targetReps: [Int]
        var sets: [SetDraft]
        var loggedTotal: Double {
            sets.reduce(0) { $0 + (Double($1.reps ?? 0) * ($1.weight ?? 0)) }
        }
    }

    struct AISuggestionRow: Identifiable {
        let id = UUID()
        var name: String
        var current: String
        var suggested: [Double]
        var overrideText: String
    }

    var body: some View {
        let plateSizes = settings?.availablePlateSizes ?? PlateCalculator.defaultPlates
        List {
            if isDeloadCycle {
                Section {
                    Label("Deload cycle — weights below are cut to ~60% to dissipate fatigue before the next block. Go light, move well, recover.",
                          systemImage: "arrow.down.heart")
                        .font(.callout).foregroundStyle(.orange)
                }
            }
            ForEach(Array(drafts.indices), id: \.self) { i in
                Section {
                    ExerciseDraftSection(draft: $drafts[i], allLogs: allExerciseLogs,
                                        exerciseDef: exerciseDefs.first { $0.name == drafts[i].name },
                                        plateSizes: plateSizes)
                }
            }
            Section {
                Button {
                    finishWorkout()
                } label: {
                    Label("Finish & Save Workout", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .disabled(drafts.allSatisfy { $0.sets.allSatisfy { !$0.isLogged } })
            }
        }
        .navigationTitle("\(day.name) · Cycle \(phase.currentCycle)")
        .onAppear(perform: buildDrafts)
        .sheet(isPresented: $showFinishSheet, onDismiss: { dismiss() }) {
            AISuggestionSheet(rows: $aiSuggestions) { applySuggestions() }
        }
    }

    // MARK: Setup

    /// This exercise's logs within the current phase, same plan key, oldest -> newest.
    private func history(for pe: PlannedExercise) -> [ExerciseLog] {
        phase.sessions
            .flatMap(\.exerciseLogs)
            .filter { $0.planKey == pe.planKey && !$0.sets.isEmpty && $0.session?.isDeload != true }
            .sorted { ($0.session?.date ?? .distantPast) < ($1.session?.date ?? .distantPast) }
    }

    private func buildDrafts() {
        guard drafts.isEmpty else { return }
        let aiOn = settings?.aiAssistantEnabled == true
        let agg = settings?.aiAggressiveness ?? .moderate

        for pe in phase.plan(for: day) {
            let logs = history(for: pe)
            // AI on: what the AI Assistant thinks is the right goal from history.
            // AI off: exactly what was lifted last time.
            var weights = aiOn
                ? (ProgressionEngine.suggestNextWeights(targetReps: pe.targetReps, history: logs,
                                                        aggressiveness: agg)
                   ?? pe.suggestedWeights)
                : (logs.last?.sortedSets.map(\.weight) ?? pe.suggestedWeights)
            if isDeloadCycle, !weights.isEmpty {
                weights = ProgressionEngine.deloadWeights(from: weights)
            }
            let sets = pe.targetReps.enumerated().map { i, _ in
                SetDraft(weightText: i < weights.count ? Formatters.trim(weights[i]) : "",
                         repsText: "")
            }
            drafts.append(ExerciseDraft(name: pe.exerciseName,
                                        targetReps: pe.targetReps,
                                        sets: sets))
        }
    }

    // MARK: Saving + AI

    private func finishWorkout() {
        let session = WorkoutSession(day: day, dayLabel: day.name,
                                     cycleNumber: phase.currentCycle,
                                     isDeload: isDeloadCycle)
        session.phase = phase
        context.insert(session)

        for (order, d) in drafts.enumerated() {
            let logged = d.sets.filter(\.isLogged)
            guard !logged.isEmpty else { continue }
            let log = ExerciseLog(exerciseName: d.name, targetReps: d.targetReps, order: order)
            log.session = session
            context.insert(log)
            for (i, s) in logged.enumerated() {
                let set = SetLog(index: i, weight: s.weight ?? 0, reps: s.reps ?? 0)
                set.exerciseLog = log
                context.insert(set)
            }
        }
        try? context.save()

        // AI Assistant: suggest next-cycle weights if enabled and phase continues.
        if settings?.aiAssistantEnabled == true, !phase.isComplete, !isDeloadCycle {
            buildAISuggestions()
            if !aiSuggestions.isEmpty {
                showFinishSheet = true
                return
            }
        }
        dismiss()
    }

    private func buildAISuggestions() {
        let agg = settings?.aiAggressiveness ?? .moderate
        aiSuggestions = []
        for pe in phase.plan(for: day) {
            let logs = history(for: pe)
            guard let suggestion = ProgressionEngine.suggestNextWeights(
                targetReps: pe.targetReps, history: logs,
                aggressiveness: agg),
                let latest = logs.last else { continue }

            let currentStr = latest.sortedSets.map { Formatters.trim($0.weight) }.joined(separator: "/")
            let suggestedStr = suggestion.map { Formatters.trim($0) }.joined(separator: "/")
            guard suggestedStr != currentStr else { continue }   // no change, skip

            aiSuggestions.append(AISuggestionRow(name: pe.exerciseName,
                                                 current: currentStr,
                                                 suggested: suggestion,
                                                 overrideText: suggestedStr))
        }
    }

    private func applySuggestions() {
        for row in aiSuggestions {
            guard let pe = phase.plan(for: day).first(where: { $0.exerciseName == row.name }) else { continue }
            let weights = row.overrideText.split(separator: "/")
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if !weights.isEmpty { pe.suggestedWeights = weights }
        }
        try? context.save()
    }
}

// MARK: - One exercise's logging card + pace panel

struct ExerciseDraftSection: View {
    @Binding var draft: WorkoutLogView.ExerciseDraft
    let allLogs: [ExerciseLog]
    let exerciseDef: ExerciseDef?
    let plateSizes: [Double]

    @State private var showingDetails = false
    @State private var plateTargetText = ""

    private var currentWeights: [Double] {
        draft.sets.compactMap(\.weight)
    }
    private var comparisons: [ComparisonTarget] {
        PaceEngine.comparisons(for: draft.name,
                               targetReps: draft.targetReps,
                               currentWeights: draft.sets.map { $0.weight ?? 0 },
                               allLogs: allLogs)
    }
    /// Weights for sets not yet logged (reps missing), using entered weight or 0.
    private var remainingWeights: [Double] {
        draft.sets.filter { $0.reps == nil }.map { $0.weight ?? 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(draft.name).font(.headline)
                Spacer()
                Text("Goal \(draft.targetReps.map(String.init).joined(separator: "/"))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button {
                    withAnimation { showingDetails.toggle() }
                } label: {
                    Image(systemName: showingDetails ? "chevron.up.circle.fill" : "info.circle")
                }
                .buttonStyle(.plain)
                .imageScale(.large)
            }

            if showingDetails {
                notesAndPlateCalc(exerciseDef)
            }

            // Set rows
            ForEach(Array(draft.sets.enumerated()), id: \.element.id) { i, _ in
                HStack(spacing: 10) {
                    Text("Set \(i + 1)")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .leading)
                    TextField("lbs", text: $draft.sets[i].weightText)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Text("×")
                    TextField("reps (goal \(draft.targetReps[safe: i] ?? 0))",
                              text: $draft.sets[i].repsText)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Text("Total moved:")
                Text("\(Formatters.trim(draft.loggedTotal)) lbs")
                    .font(.system(.body, design: .monospaced)).bold()
            }
            .font(.subheadline)

            // Pace panel
            if comparisons.isEmpty {
                Text("First time logging this — set the baseline. 💪")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(comparisons) { c in
                        PaceRow(target: c,
                                loggedSoFar: draft.loggedTotal,
                                remainingWeights: remainingWeights)
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func notesAndPlateCalc(_ def: ExerciseDef?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let def, !def.notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notes").font(.caption.bold()).foregroundStyle(.secondary)
                    Text(def.notes).font(.subheadline)
                }
            }

            if let bar = def?.equipment {
                if bar.isDumbbell {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Dumbbell Match").font(.caption.bold()).foregroundStyle(.secondary)
                        HStack {
                            Text("Target")
                            TextField("lbs", text: $plateTargetText)
                                .keyboardType(.decimalPad)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                        }
                        .font(.subheadline)

                        if let target = Double(plateTargetText) {
                            if let closest = bar.dumbbellWeights.min(by: { abs($0 - target) < abs($1 - target) }) {
                                Text(closest == target
                                     ? "You have that exact dumbbell: \(Formatters.trim(closest)) lb"
                                     : "Closest you have: \(Formatters.trim(closest)) lb")
                                    .font(.caption)
                                    .foregroundStyle(closest == target ? .green : .orange)
                            } else {
                                Text("No dumbbell weights set for \(bar.name) — add some in Equipment.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Plate Calculator").font(.caption.bold()).foregroundStyle(.secondary)
                        HStack {
                            Text("Target")
                            TextField("lbs", text: $plateTargetText)
                                .keyboardType(.decimalPad)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                        }
                        .font(.subheadline)

                        if let target = Double(plateTargetText) {
                            if let (plates, leftover) = PlateCalculator.plates(target: target, barWeight: bar.weight, available: plateSizes) {
                                if plates.isEmpty && leftover == 0 {
                                    Text("Empty \(Formatters.trim(bar.weight)) lb bar — no plates needed")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                ForEach(plates) { p in
                                    HStack {
                                        Text("\(Formatters.trim(p.plate)) lb plate")
                                            .font(.system(.caption, design: .monospaced))
                                        Spacer()
                                        Text("× \(p.countPerSide) per side")
                                            .font(.system(.caption, design: .monospaced)).bold()
                                    }
                                }
                                if leftover > 0 {
                                    Text("Can't hit exactly — \(Formatters.trim(leftover)) lbs/side short.")
                                        .font(.caption2).foregroundStyle(.orange)
                                }
                            } else {
                                Text("Target is lighter than the \(Formatters.trim(bar.weight)) lb bar.")
                                    .font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                }
            } else {
                Text("Tag equipment for this exercise in the Exercises tab to use the plate calculator.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct PaceRow: View {
    let target: ComparisonTarget
    let loggedSoFar: Double
    let remainingWeights: [Double]

    var body: some View {
        let beaten = loggedSoFar > target.totalWeightMoved
        let paceReps = PaceEngine.repsNeededNextSet(targetTotal: target.totalWeightMoved,
                                                    loggedSoFar: loggedSoFar,
                                                    remainingWeights: remainingWeights)
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(target.kind.rawValue).font(.caption.bold())
                Spacer()
                Text(Formatters.date.string(from: target.date))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text("\(target.setsSummary) = \(Formatters.trim(target.totalWeightMoved)) lbs")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
            if beaten {
                Label("Beaten by \(Formatters.trim(loggedSoFar - target.totalWeightMoved)) lbs 🔥",
                      systemImage: "flame.fill")
                    .font(.caption).foregroundStyle(.green)
            } else if remainingWeights.isEmpty {
                Label("Fell short by \(Formatters.trim(target.totalWeightMoved - loggedSoFar)) lbs",
                      systemImage: "arrow.down.right")
                    .font(.caption).foregroundStyle(.red)
            } else if let reps = paceReps {
                Label("Need \(reps) reps/set pace to beat it (\(remainingWeights.count) sets left)",
                      systemImage: "target")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - AI suggestion sheet (override before accepting)

struct AISuggestionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var rows: [WorkoutLogView.AISuggestionRow]
    var onApply: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("AI suggestions for your next cycle. Edit any of these before applying, or skip to keep current weights.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach($rows) { $row in
                    Section(row.name) {
                        LabeledContent("This cycle", value: row.current)
                        LabeledContent("Suggested") {
                            Text(row.suggested.map { Formatters.trim($0) }.joined(separator: "/"))
                                .foregroundStyle(.green)
                        }
                        TextField("Next cycle (override)", text: $row.overrideText)
                            .font(.system(.body, design: .monospaced))
                            .keyboardType(.numbersAndPunctuation)
                    }
                }
            }
            .navigationTitle("Next Cycle Weights")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Skip") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { onApply(); dismiss() }
                }
            }
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
