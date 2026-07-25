//
//  WorkoutLogView.swift
//  TheJym
//
//  Log a session. For each exercise, shows the three comparison workouts
//  (Previous Workout / Best at Weights / All-Time Best) with dates, totals,
//  and the reps you need next set to stay on pace to beat each. Once every
//  set in an exercise is logged, it auto-collapses to a compact summary
//  (tap to reopen and edit). On finish, the AI Assistant suggests
//  next-cycle weights (overridable). In-progress data survives leaving the
//  view or closing the app — it's persisted to disk on every change and
//  restored next time this exact phase/day/cycle is opened.
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
    @State private var scrollToDraftID: UUID?

    private var settings: AppSettings? { settingsList.first }
    private var isDeloadCycle: Bool {
        settings?.deloadWeeksEnabled == true && phase.deloadCycle == phase.currentCycle
    }

    // MARK: Draft state — Codable so in-progress work can be persisted to disk.

    struct SetDraft: Identifiable, Codable, Equatable {
        var id = UUID()
        var weightText: String
        var repsText: String
        var weight: Double? { Double(weightText) }
        var reps: Int? { Int(repsText) }
        var isLogged: Bool { weight != nil && reps != nil }
    }

    struct ExerciseDraft: Identifiable, Codable, Equatable {
        var id = UUID()
        var name: String
        var targetReps: [Int]
        var sets: [SetDraft]
        /// False once every set is logged and it's auto-collapsed to a summary.
        var isExpanded: Bool = true
        /// False after the user manually reopens a collapsed exercise, so it
        /// won't auto-collapse again until they close it themselves.
        var autoCollapseEnabled: Bool = true
        /// Notes / plate-calculator panel toggle, lifted up here (instead of
        /// local view state) so the sticky section header can drive it too.
        var showingDetails: Bool = false
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
        let dumbbellIncrement = settings?.dumbbellRoundingIncrement ?? 5
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(drafts.indices), id: \.self) { i in
                            ExercisePageView(draft: $drafts[i], allLogs: allExerciseLogs,
                                            exerciseDef: exerciseDefs.first { $0.name == drafts[i].name },
                                            plateSizes: plateSizes, dumbbellIncrement: dumbbellIncrement,
                                            pageHeight: geo.size.height)
                                .frame(height: geo.size.height)
                                .clipped()
                                .id(drafts[i].id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .onChange(of: scrollToDraftID) { _, newID in
                    if let newID {
                        withAnimation { proxy.scrollTo(newID, anchor: .top) }
                    }
                }
            }
        }
        .safeAreaInset(edge: .top) {
            if isDeloadCycle {
                Label("Deload cycle — weights below are cut to ~60% to dissipate fatigue before the next block. Go light, move well, recover.",
                      systemImage: "arrow.down.heart")
                    .font(.callout).foregroundStyle(.orange)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.12))
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                finishWorkout()
            } label: {
                Label("Finish & Save Workout", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(drafts.allSatisfy { $0.sets.allSatisfy { !$0.isLogged } })
            .padding()
            .background(.bar)
        }
        .navigationTitle("\(day.name) · Cycle \(phase.currentCycle)")
        .toolbar {
            if drafts.count > 1 {
                ToolbarItem(placement: .principal) {
                    Menu {
                        ForEach(drafts) { draft in
                            Button(draft.name) {
                                scrollToDraftID = draft.id
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Jump to Exercise…")
                                .font(.headline)
                            Image(systemName: "chevron.down")
                                .font(.caption)
                        }
                    }
                }
            }
        }
        .onAppear(perform: buildDrafts)
        .onChange(of: drafts) { _, _ in saveDraftToDisk() }
        .sheet(isPresented: $showFinishSheet, onDismiss: { dismiss() }) {
            AISuggestionSheet(rows: $aiSuggestions) { applySuggestions() }
        }
    }

    // MARK: Setup

    /// This exercise's logs, same plan key, any phase (progression looks at
    /// your whole training history, not just the current block).
    private func history(for pe: PlannedExercise) -> [ExerciseLog] {
        allExerciseLogs
            .filter { $0.planKey == pe.planKey && !$0.sets.isEmpty && $0.session?.isDeload != true }
            .sorted { ($0.session?.date ?? .distantPast) < ($1.session?.date ?? .distantPast) }
    }

    /// Finest weight jump achievable for this exercise's equipment — the
    /// standard 2.5 lb for barbell/plate work, or a finer dumbbell increment
    /// if the matching attachment is on hand.
    private func roundingIncrement(for exerciseName: String) -> Double {
        guard let def = exerciseDefs.first(where: { $0.name == exerciseName }),
              def.equipment?.isDumbbell == true
        else { return 2.5 }
        return settings?.dumbbellRoundingIncrement ?? 5
    }

    private func buildDrafts() {
        guard drafts.isEmpty else { return }
        if let saved = loadDraftFromDisk(), !saved.isEmpty {
            drafts = saved
            return
        }

        let aiOn = settings?.aiAssistantEnabled == true
        let agg = settings?.aiAggressiveness ?? .moderate

        for pe in phase.plan(for: day) {
            let logs = history(for: pe)
            let increment = roundingIncrement(for: pe.exerciseName)
            // AI on: what the AI Assistant thinks is the right goal from history.
            // AI off: exactly what was lifted last time.
            var weights = aiOn
                ? (ProgressionEngine.suggestNextWeights(targetReps: pe.targetReps, history: logs,
                                                        aggressiveness: agg, roundingIncrement: increment)
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

    // MARK: Draft persistence (survives tab switches / app close)

    private var draftStorageKey: String {
        "workoutDraft_\(phase.number)_\(day.name)_\(phase.currentCycle)"
    }

    private func saveDraftToDisk() {
        guard let data = try? JSONEncoder().encode(drafts) else { return }
        UserDefaults.standard.set(data, forKey: draftStorageKey)
    }

    private func loadDraftFromDisk() -> [ExerciseDraft]? {
        guard let data = UserDefaults.standard.data(forKey: draftStorageKey) else { return nil }
        return try? JSONDecoder().decode([ExerciseDraft].self, from: data)
    }

    private func clearSavedDraft() {
        UserDefaults.standard.removeObject(forKey: draftStorageKey)
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
        clearSavedDraft()

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
            let increment = roundingIncrement(for: pe.exerciseName)
            guard let suggestion = ProgressionEngine.suggestNextWeights(
                targetReps: pe.targetReps, history: logs,
                aggressiveness: agg, roundingIncrement: increment),
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

struct ExercisePageView: View {
    @Binding var draft: WorkoutLogView.ExerciseDraft
    let allLogs: [ExerciseLog]
    let exerciseDef: ExerciseDef?
    let plateSizes: [Double]
    let dumbbellIncrement: Double
    /// Full available height for this one exercise's "page" — everything
    /// from the name down through the pace panel must fit inside it so a
    /// vertical swipe moves cleanly to the next exercise instead of scrolling.
    let pageHeight: CGFloat

    @State private var plateTargetText = ""
    /// Sets a later set's weight was just shifted by via cascade, so the
    /// field can flash a "+10"/"-5" badge before fading out.
    @State private var cascadeIndicator: [Int: Double] = [:]

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
    /// Average weight moved per rep so far this workout — used to translate
    /// a beaten-by/fell-short-by weight delta into an equivalent rep count.
    private var avgWeightPerRep: Double {
        let totalReps = draft.sets.compactMap(\.reps).reduce(0, +)
        guard totalReps > 0 else { return 0 }
        return draft.loggedTotal / Double(totalReps)
    }
    /// The +/- step for this exercise's weight fields: the smallest plate
    /// you own for barbell/plate work, or the finest dumbbell increment
    /// (attachments considered) for a dumbbell exercise.
    private var weightStep: Double {
        guard let bar = exerciseDef?.equipment else { return 2.5 }
        return bar.isDumbbell ? dumbbellIncrement : (plateSizes.min() ?? 2.5)
    }
    /// Selectable values for the inline weight wheel, spaced by weightStep.
    private var weightValues: [Double] {
        Array(stride(from: 0.0, through: 600.0, by: weightStep))
    }
    /// Shrinks the weight/reps wheels as needed so all of this exercise's
    /// sets, plus the header and pace panel, fit within one page height.
    private var wheelHeight: CGFloat {
        let chromeHeight: CGFloat = 300   // header + pace panel + paddings, estimated
        let available = pageHeight - chromeHeight
        let setCount = max(draft.sets.count, 1)
        let perSet = available / CGFloat(setCount)
        return min(90, max(40, perSet))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if draft.isExpanded {
                if draft.showingDetails {
                    notesAndPlateCalc(exerciseDef)
                }
                setRows
            } else {
                currentWorkoutRow
            }

            // Pace panel
            if comparisons.isEmpty {
                Text("First time logging this — set the baseline. 💪")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(comparisons) { c in
                        PaceRow(target: c,
                                loggedSoFar: draft.loggedTotal,
                                remainingWeights: remainingWeights,
                                avgWeightPerRep: avgWeightPerRep)
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .frame(height: pageHeight, alignment: .top)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(draft.name)
                    .font(.title2.bold())
                Spacer()
                if draft.isExpanded {
                    Button {
                        withAnimation { draft.showingDetails.toggle() }
                    } label: {
                        Image(systemName: draft.showingDetails ? "chevron.up.circle.fill" : "info.circle")
                    }
                    .buttonStyle(.plain)
                    .imageScale(.large)
                    Button {
                        withAnimation { draft.isExpanded = false }
                    } label: {
                        Image(systemName: "checkmark.circle")
                    }
                    .buttonStyle(.plain)
                    .imageScale(.large)
                } else {
                    Button {
                        // Reopened manually — leave it open until the user closes
                        // it again themselves, don't auto-collapse a second time.
                        withAnimation { draft.isExpanded = true; draft.autoCollapseEnabled = false }
                    } label: {
                        Label("Edit", systemImage: "pencil.circle")
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                }
            }
            if draft.isExpanded {
                HStack(spacing: 12) {
                    Text("Set").font(.title3).foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .leading)
                    Text("Weight").font(.title3).foregroundStyle(.secondary)
                        .frame(width: 100, alignment: .center)
                    Text("Goal").font(.title3).foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .center)
                    Text("Reps").font(.title3).foregroundStyle(.secondary)
                        .frame(width: 75, alignment: .center)
                }
            }
        }
    }

    private var setRows: some View {
        VStack(alignment: .leading, spacing: -8) {
            ForEach(Array(draft.sets.enumerated()), id: \.element.id) { i, _ in
                HStack(spacing: 12) {
                    Text("Set \(i + 1)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .leading)

                    ZStack(alignment: .top) {
                        Picker("Weight", selection: Binding(
                            get: { nearestValue(draft.sets[i].weight ?? 0, in: weightValues) },
                            set: { newValue in
                                let old = draft.sets[i].weight ?? 0
                                draft.sets[i].weightText = Formatters.trim(newValue)
                                let delta = newValue - old
                                if delta != 0 { cascadeDelta(delta, from: i) }
                            })) {
                            ForEach(weightValues, id: \.self) { v in
                                Text(Formatters.trim(v)).font(.subheadline).tag(v)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(width: 100, height: wheelHeight)
                        .clipped()
                        if let delta = cascadeIndicator[i] {
                            Text(delta > 0 ? "+\(Formatters.trim(delta))" : Formatters.trim(delta))
                                .font(.caption2.bold())
                                .foregroundStyle(delta > 0 ? .green : .red)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.thinMaterial, in: Capsule())
                                .transition(.opacity)
                        }
                    }

                    if let goal = draft.targetReps[safe: i] {
                        Text("\(goal)")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .frame(width: 44, alignment: .center)
                    } else {
                        Text("–")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .center)
                    }

                    Picker("Reps", selection: Binding(
                        get: { draft.sets[i].reps ?? 0 },
                        set: { newValue in
                            draft.sets[i].repsText = String(newValue)
                            checkAutoCollapse()
                        })) {
                        ForEach(0...50, id: \.self) { v in
                            Text("\(v)").font(.subheadline).tag(v)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(width: 75, height: wheelHeight)
                    .clipped()
                }
                .animation(.easeInOut, value: cascadeIndicator[i])
            }
        }
    }

    private func cascadeDelta(_ delta: Double, from index: Int) {
        guard delta != 0 else { return }
        var affected: [Int] = []
        for k in (index + 1)..<draft.sets.count {
            guard let existing = draft.sets[k].weight else { continue }
            draft.sets[k].weightText = Formatters.trim(existing + delta)
            cascadeIndicator[k] = delta
            affected.append(k)
        }
        guard !affected.isEmpty else { return }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            for k in affected { cascadeIndicator.removeValue(forKey: k) }
        }
    }

    /// Only auto-collapses if the exercise hasn't been manually reopened
    /// since the last time it collapsed.
    private func checkAutoCollapse() {
        guard draft.autoCollapseEnabled else { return }
        if draft.sets.allSatisfy(\.isLogged) {
            withAnimation { draft.isExpanded = false }
        }
    }

    private func nearestValue(_ target: Double, in values: [Double]) -> Double {
        values.min(by: { abs($0 - target) < abs($1 - target) }) ?? 0
    }

    /// Compact summary of today's entered weights/reps, shown once the
    /// exercise auto-collapses (mirrors the historical pace-calc rows).
    private var currentWorkoutRow: some View {
        let weights = draft.sets.map { $0.weightText.isEmpty ? "—" : $0.weightText }.joined(separator: "/")
        let reps = draft.sets.map { $0.repsText.isEmpty ? "—" : $0.repsText }.joined(separator: "/")

        return VStack(alignment: .leading, spacing: 2) {
            Text("Current Workout").font(.caption.bold())
            Text("\(reps) reps @ \(weights) lbs")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
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
                            if let (plates, leftover) = PlateCalculator.plates(target: target, barWeight: bar.weight,
                                                                               available: plateSizes, sides: bar.loadableSides) {
                                if plates.isEmpty && leftover == 0 {
                                    Text("Empty \(Formatters.trim(bar.weight)) lb bar — no plates needed")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                ForEach(plates) { p in
                                    HStack {
                                        Text("\(Formatters.trim(p.plate)) lb plate")
                                            .font(.system(.caption, design: .monospaced))
                                        Spacer()
                                        Text(bar.loadableSides == 1 ? "× \(p.countPerSide)" : "× \(p.countPerSide) per side")
                                            .font(.system(.caption, design: .monospaced)).bold()
                                    }
                                }
                                if leftover > 0 {
                                    Text("Can't hit exactly — \(Formatters.trim(leftover)) lbs short.")
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
    /// Average weight moved per rep so far — converts a beaten-by/fell-
    /// short-by weight delta into an equivalent whole-rep count.
    let avgWeightPerRep: Double

    /// Whole reps (rounded up — a partial rep still costs you a full one).
    private func repsEquivalent(_ lbsDelta: Double) -> String {
        guard avgWeightPerRep > 0 else { return "0 reps" }
        let reps = max(1, Int(ceil(abs(lbsDelta) / avgWeightPerRep)))
        return "\(reps) rep\(reps == 1 ? "" : "s")"
    }

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
            Text(target.setsSummary)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
            if beaten {
                Label("Beaten by \(repsEquivalent(loggedSoFar - target.totalWeightMoved)) 🔥",
                      systemImage: "flame.fill")
                    .font(.caption).foregroundStyle(.green)
            } else if remainingWeights.isEmpty {
                Label("Fell short by \(repsEquivalent(target.totalWeightMoved - loggedSoFar))",
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
