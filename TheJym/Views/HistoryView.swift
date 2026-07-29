//
//  HistoryView.swift
//  TheJym
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

extension UTType {
    /// Office Open XML Spreadsheet (.xlsx) — the canonical system UTI, with a
    /// filename-extension lookup and generic-data fallback for robustness.
    static let xlsxSpreadsheet: UTType =
        UTType("org.openxmlformats.spreadsheetml.sheet")
        ?? UTType(filenameExtension: "xlsx")
        ?? .data
}

/// One row per logged day (WorkoutSession) — a plain, native List, the
/// standard high-performance choice for a log like this (List virtualizes
/// rows automatically; the old horizontally-scrolling flat table didn't).
/// Each row shows the date + day name once, with an edit button that opens
/// the full day for editing and a delete button that removes the whole day.
struct HistoryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \WorkoutSession.date, order: .reverse) private var sessions: [WorkoutSession]
    @Query(sort: \BodyWeightEntry.date) private var bodyWeights: [BodyWeightEntry]
    @Query(sort: \ExerciseDef.name) private var exerciseDefs: [ExerciseDef]

    @State private var showingAddPast = false
    @State private var showingImporter = false
    @State private var showingImportHelp = false
    @State private var importResultMessage: String?
    @State private var searchText = ""
    @State private var editingSessionID: PersistentIdentifier?

    // Import -> auto-drafted-Phase review flow: rows are held here between
    // parsing and the user confirming/editing the detected Phase, since the
    // actual store-import is deferred until the Phase exists to attribute to.
    @State private var showingImportPhaseReview = false
    @State private var seededPhaseDayDrafts: [PhaseBuilderView.DayDraft]?
    @State private var pendingImportRows: [ImportEngine.ImportedEntry] = []
    @State private var pendingImportSkipped = 0

    private var filteredSessions: [WorkoutSession] {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return sessions }
        return sessions.filter { session in
            session.exerciseLogs.contains { $0.exerciseName.localizedCaseInsensitiveContains(trimmed) }
        }
    }

    /// A session's exercises, narrowed to just the ones matching the search
    /// — so searching "Squat" doesn't also surface everything else you did
    /// that day.
    private func filteredLogs(for session: WorkoutSession) -> [ExerciseLog] {
        let sorted = session.exerciseLogs.sorted { $0.order < $1.order }
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return sorted }
        return sorted.filter { $0.exerciseName.localizedCaseInsensitiveContains(trimmed) }
    }

    /// Pull-to-refresh: an exercise logged before it was flagged bodyweight
    /// in the Exercises tab recorded its full weight as a plain total, with
    /// no added-weight/bodyweight split — this backfills that split for any
    /// log whose exercise has since been tagged, by resolving the body
    /// weight on record as of that session's date and treating the
    /// difference as added weight. `weight` itself (the effective total)
    /// never changes, so totals/comparisons stay correct either way; this
    /// only fixes how it's displayed and keyed. Skips a log if no
    /// BodyWeightEntry exists yet for that date — nothing to split against.
    private func refreshHistory() {
        let bodyweightNames = Set(exerciseDefs.filter(\.isBodyweight).map(\.name))
        guard !bodyweightNames.isEmpty else { return }
        var changed = false
        for session in sessions {
            for log in session.exerciseLogs where !log.isBodyweight && bodyweightNames.contains(log.exerciseName) {
                guard let bw = bodyWeights.last(where: { $0.date <= session.date })?.weight else { continue }
                log.isBodyweight = true
                for set in log.sets {
                    set.addedWeight = max(0, set.weight - bw)
                    set.bodyweightAtLog = bw
                }
                changed = true
            }
        }
        if changed { try? context.save() }
    }

    var body: some View {
        NavigationStack {
            List {
                if sessions.isEmpty {
                    Section {
                        ContentUnavailableView("No workouts yet",
                                               systemImage: "clock.arrow.circlepath",
                                               description: Text("Your logged sessions will show up here."))
                    }
                } else if filteredSessions.isEmpty {
                    Section {
                        ContentUnavailableView.search(text: searchText)
                    }
                } else {
                    ForEach(filteredSessions, id: \.persistentModelID) { session in
                        Section {
                            ForEach(filteredLogs(for: session), id: \.persistentModelID) { log in
                                exerciseRow(log)
                            }
                        } header: {
                            sessionHeader(session)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .headerProminence(.increased)
            .refreshable {
                refreshHistory()
            }
            .navigationTitle("History")
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Filter by exercise")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Add Past Workout", systemImage: "square.and.pencil") { showingAddPast = true }
                        Button("Import from CSV or Excel…", systemImage: "square.and.arrow.down") { showingImporter = true }
                        Button("Import Format Guide…", systemImage: "questionmark.circle") { showingImportHelp = true }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddPast) {
                AddHistoricalWorkoutView()
            }
            .sheet(isPresented: $showingImportHelp) {
                CSVFormatHelpView()
            }
            .sheet(isPresented: $showingImportPhaseReview) {
                PhaseBuilderView(previousPhase: nil, seededDayDrafts: seededPhaseDayDrafts) { newPhase in
                    finishImportIntoPhase(newPhase)
                }
            }
            .fileImporter(isPresented: $showingImporter,
                         allowedContentTypes: [.commaSeparatedText, .plainText, .text, .xlsxSpreadsheet]) { result in
                handleImport(result)
            }
            .alert("Import Complete", isPresented: Binding(
                get: { importResultMessage != nil },
                set: { if !$0 { importResultMessage = nil } })) {
                Button("OK") { importResultMessage = nil }
            } message: {
                Text(importResultMessage ?? "")
            }
            .navigationDestination(item: $editingSessionID) { id in
                if let session = sessions.first(where: { $0.persistentModelID == id }) {
                    SessionDetailView(session: session)
                }
            }
        }
    }

    /// One per day: date + day name shown once, with the day's only edit
    /// (opens the full day for editing) and delete (removes the whole day)
    /// buttons — the individual exercises below it are read-only display;
    /// drill in via Edit to change a weight/rep or delete one exercise.
    private func sessionHeader(_ session: WorkoutSession) -> some View {
        HStack(spacing: 12) {
            Button {
                editingSessionID = session.persistentModelID
            } label: {
                Image(systemName: "pencil").foregroundStyle(.blue)
            }
            .buttonStyle(.plain)

            HStack {
                Text(Formatters.shortDate.string(from: session.date))
                    .font(.subheadline.bold())
                Text(session.dayLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if session.isDeload {
                    Text("DELOAD").font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.orange.opacity(0.2), in: Capsule())
                }
                Spacer()
                if let n = session.phase?.number {
                    Text("Phase \(n)").font(.caption2).foregroundStyle(.secondary)
                }
            }

            Button(role: .destructive) {
                context.delete(session)
                try? context.save()
            } label: {
                Image(systemName: "trash").foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .textCase(nil)
    }

    private func exerciseRow(_ log: ExerciseLog) -> some View {
        let showGoal = !log.targetReps.isEmpty
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(log.exerciseName).font(.subheadline.weight(.semibold))
                if case .repTotal(let target) = log.goalType {
                    Text("\(log.repTotalSoFar)/\(target) reps")
                        .font(.caption.bold())
                        .foregroundStyle(log.repTotalReached ? .green : .secondary)
                }
            }
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(log.isBodyweight ? "added" : "lbs")
                    if showGoal { Text("target") }
                    Text("reps")
                }
                .font(.caption2)
                .foregroundStyle(.secondary.opacity(0.7))

                liftsGrid(log)
            }
            if log.isBodyweight, let bw = log.sortedSets.first?.bodyweightAtLog {
                Text("Bodyweight: \(Formatters.trim(bw)) lb")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    /// Weights, goal (target reps), and actual reps stacked in that order,
    /// laid out in a Grid so each column's width matches its widest value —
    /// the "/" separators land in the same horizontal spot on every line,
    /// and each column centers its goal/reps under its weight.
    private func liftsGrid(_ log: ExerciseLog) -> some View {
        let sortedSets = log.sortedSets
        let targetReps = log.targetReps
        let showGoal = !targetReps.isEmpty
        let columnCount = max(sortedSets.count, targetReps.count)

        return Grid(alignment: .center, horizontalSpacing: 3, verticalSpacing: 2) {
            GridRow {
                ForEach(0..<columnCount, id: \.self) { idx in
                    Text(idx < sortedSets.count ? weightLabel(sortedSets[idx], isBodyweight: log.isBodyweight) : "")
                    if idx < columnCount - 1 {
                        Text("/").foregroundStyle(.secondary.opacity(0.5))
                    }
                }
            }
            if showGoal {
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { idx in
                        Text(idx < targetReps.count ? String(targetReps[idx]) : "")
                        if idx < columnCount - 1 {
                            Text("/").foregroundStyle(.secondary.opacity(0.5))
                        }
                    }
                }
            }
            GridRow {
                ForEach(0..<columnCount, id: \.self) { idx in
                    Text(idx < sortedSets.count ? String(sortedSets[idx].reps) : "")
                    if idx < columnCount - 1 {
                        Text("/").foregroundStyle(.secondary.opacity(0.5))
                    }
                }
            }
        }
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.secondary)
    }

    /// Added weight for a bodyweight set (the resolved effective weight
    /// isn't meaningful to display per-set, since bodyweight can drift
    /// between sessions — the added load is what's actually comparable).
    private func weightLabel(_ set: SetLog, isBodyweight: Bool) -> String {
        isBodyweight ? Formatters.trim(set.addedWeight ?? 0) : Formatters.trim(set.weight)
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            importResultMessage = "Couldn't read that file: \(error.localizedDescription)"
        case .success(let url):
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

            let parsed: (rows: [ImportEngine.ImportedEntry], skipped: Int)?
            if url.pathExtension.lowercased() == "xlsx" {
                guard let data = try? Data(contentsOf: url) else {
                    importResultMessage = "Couldn't read that file."
                    return
                }
                parsed = ImportEngine.parseRows(xlsxData: data)
                if parsed == nil {
                    importResultMessage = "Couldn't read that Excel file — make sure it's a standard .xlsx workbook."
                    return
                }
            } else {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                    importResultMessage = "Couldn't read that file as text."
                    return
                }
                parsed = ImportEngine.parseRows(csv: text)
            }

            guard let (rows, skipped) = parsed, !rows.isEmpty else {
                importResultMessage = "No valid rows found. Make sure the sheet has Date, Exercise, Sets, Weights, and Reps columns — see the Import Format Guide for the exact layout."
                return
            }
            // If the file's Day column reveals a repeating training pattern,
            // draft a Phase from the most recently completed cycle and let
            // the user review/edit it before anything actually gets
            // imported — once they save it, every row that matches one of
            // its days gets attributed there.
            if let detected = ImportEngine.detectLastCyclePattern(from: rows),
               detected.contains(where: { !$0.isRest && !$0.exercises.isEmpty }) {
                pendingImportRows = rows
                pendingImportSkipped = skipped
                seededPhaseDayDrafts = dayDrafts(from: detected)
                showingImportPhaseReview = true
                return
            }

            let outcome = ImportEngine.importIntoStore(rows, context: context)
            var msg = "Imported \(outcome.setsImported) sets across \(outcome.sessionsCreated) day\(outcome.sessionsCreated == 1 ? "" : "s")."
            if skipped > 0 { msg += " Skipped \(skipped) row\(skipped == 1 ? "" : "s") that didn't parse." }
            importResultMessage = msg
        }
    }

    /// Builds Phase Builder's day-draft seed from a detected last-cycle
    /// pattern — each exercise's starting weights come straight from that
    /// occurrence's actual logged weights.
    private func dayDrafts(from detected: [ImportEngine.DetectedDay]) -> [PhaseBuilderView.DayDraft] {
        detected.map { day in
            guard !day.isRest else {
                return PhaseBuilderView.DayDraft(name: "Rest", isRest: true)
            }
            let exercises = day.exercises.map { e -> PhaseBuilderView.DraftExercise in
                var draft = PhaseBuilderView.DraftExercise(
                    name: e.name, repsText: "",
                    weightsText: e.weights.map { Formatters.trim($0) }.joined(separator: "/"))
                switch e.goalType {
                case .fixedSets:
                    draft.repsText = e.targetReps.map(String.init).joined(separator: "/")
                case .repTotal(let target):
                    draft.goalType = .repTotal(target: target)
                    draft.repTotalTargetText = String(target)
                }
                return draft
            }
            return PhaseBuilderView.DayDraft(name: day.name, isRest: false, exercises: exercises)
        }
    }

    /// Runs once the auto-drafted Phase has been reviewed/edited and saved —
    /// the deferred real import, attributing every matching row to it.
    private func finishImportIntoPhase(_ phase: Phase) {
        let outcome = ImportEngine.importIntoStore(pendingImportRows, context: context, attributeTo: phase)
        var msg = "Imported \(outcome.setsImported) sets across \(outcome.sessionsCreated) day\(outcome.sessionsCreated == 1 ? "" : "s"), attributed to Phase \(phase.number)."
        if pendingImportSkipped > 0 {
            msg += " Skipped \(pendingImportSkipped) row\(pendingImportSkipped == 1 ? "" : "s") that didn't parse."
        }
        importResultMessage = msg
        pendingImportRows = []
        pendingImportSkipped = 0
        seededPhaseDayDrafts = nil
    }
}

/// Explains the expected column layout for bulk import (CSV or .xlsx).
struct CSVFormatHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Works with a .csv file or an Excel/Sheets .xlsx workbook (first sheet).")
                    Text("Required columns (any order): **Date**, **Exercise**, **Sets**, **Weights**, **Reps**. Optional: **Phase**, **Day**, **Equipment**.")
                    Text("One row = one exercise logged on one day. Sets, Weights, and Reps are slash-separated, one value per set, in the same order.")
                        .foregroundStyle(.secondary)
                }

                Section("Example") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Date,Phase,Day,Exercise,Sets,Weights,Reps")
                        Text("2026-01-05,2,Push A,Back Squat,5/5/5/3/3,135/135/135/145/145,6/5/5/5/3")
                    }
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                }

                Section("Rep-Total Example (e.g. Pull-Up, bodyweight)") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Date,Phase,Day,Exercise,Sets,Weights,Reps,Equipment")
                        Text("2026-01-05,2,Pull A,Pull-Up,40 total,0/0/0/0/0/0/0,6/5/5/4/4/3/3,Bodyweight")
                    }
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                }

                Section("Rest-Day Activity Example") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Date,Phase,Day,Exercise,Sets,Weights,Reps")
                        Text("2026-01-06,,Rest,Walk,,,3.1mi")
                    }
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                }

                Section {
                    Label("Sets is the target rep scheme (e.g. 5/5/5/3/3) — it becomes a saved Set for that exercise in the Exercises tab.",
                          systemImage: "list.bullet.rectangle")
                    Label("For a rep-total exercise (a running total instead of fixed sets, like Pull-Up), write Sets as \"40 total\" instead — it becomes a saved rep-total target on the exercise. Weights and Reps still list one value per set actually done.",
                          systemImage: "target")
                    Label("Weights and Reps are what you actually lifted, and must have the same number of slash-separated values as each other.",
                          systemImage: "checkmark.circle")
                    Label("For a bodyweight exercise, Weights means ADDED weight, not total load — it's resolved against whatever body weight was on record as of that row's date. Write 0 for no added weight.",
                          systemImage: "figure.strengthtraining.functional")
                    Label("Equipment tags the exercise: write \"Bodyweight\" to flag it bodyweight (same as the Exercises-tab toggle), or any equipment name (e.g. \"Trap Bar\"). A name that doesn't exist yet still imports fine — it creates a new placeholder in the Equipment tab (weight TBD, 2-sided) instead of being dropped.",
                          systemImage: "dumbbell")
                    Label("Leave Sets blank if there was no real target — the exercise still gets logged, just without a saved Set.",
                          systemImage: "questionmark.circle")
                    Label("Write Day as \"Rest\" for a rest-day activity instead of an exercise (requires a Day column) — Exercise becomes the activity's name, Reps optionally holds a distance (e.g. \"3.1mi\"), Sets/Weights are unused. Counts toward the rest-bank streak, same as logging it live.",
                          systemImage: "figure.walk")
                    Label("Phase is that phase's number; Day is the day's name (e.g. \"Push A\"), matched case-insensitively. If given and matched, the imported workout is attributed to that real Phase/Day, just like one logged live. Leave them out (or leave them unmatched) and the row still imports fine as a generic \"Imported\" entry.",
                          systemImage: "calendar.badge.checkmark")
                    Label("If your Day column shows a repeating pattern (Push A / Pull A / Legs A / Rest, over and over), you'll be shown a Phase auto-drafted from the most recently completed cycle to review and edit before anything imports — saving it attributes every matching row in the file to it, not just the last cycle.",
                          systemImage: "calendar.badge.clock")
                    Label("If a spreadsheet \"fixes\" a value like 12/12/12 into a date (12/12/2012, a leading '12/12/12, or a raw date serial like 41255), it's recovered automatically back to 12/12/12 — no need to clean it up first.",
                          systemImage: "wand.and.stars")
                } header: {
                    Text("Notes")
                }
            }
            .navigationTitle("Import Format")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

/// The full logged day: every exercise, editable in place. Editing a
/// weight/reps field persists immediately; delete a set with swipe, or an
/// entire exercise with the trash button in its section header.
struct SessionDetailView: View {
    @Environment(\.modelContext) private var context
    let session: WorkoutSession

    private var sortedLogs: [ExerciseLog] {
        session.exerciseLogs.sorted { $0.order < $1.order }
    }

    var body: some View {
        List {
            ForEach(sortedLogs, id: \.persistentModelID) { log in
                Section {
                    if !log.targetReps.isEmpty {
                        LabeledContent("Target", value: log.targetReps.map(String.init).joined(separator: "/"))
                            .font(.caption).foregroundStyle(.secondary)
                    } else if case .repTotal(let target) = log.goalType {
                        LabeledContent("Target", value: "\(log.repTotalSoFar)/\(target) reps")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(log.sortedSets, id: \.persistentModelID) { set in
                        SetEditRow(set: set, isBodyweight: log.isBodyweight)
                    }
                    .onDelete { idx in
                        let sorted = log.sortedSets
                        for i in idx { context.delete(sorted[i]) }
                        try? context.save()
                    }
                    Button("Add Set") { addSet(to: log) }
                } header: {
                    HStack {
                        Text(log.exerciseName)
                        Spacer()
                        Button(role: .destructive) {
                            context.delete(log)
                            try? context.save()
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle(Formatters.date.string(from: session.date))
    }

    private func addSet(to log: ExerciseLog) {
        let s: SetLog
        if log.isBodyweight {
            // Inherit the bodyweight already resolved for this log's other
            // sets, so a manually-added set doesn't end up with no
            // bodyweight to add its weight to.
            let bw = log.sortedSets.first?.bodyweightAtLog ?? 0
            s = SetLog(index: log.sets.count, weight: bw, reps: 0, addedWeight: 0, bodyweightAtLog: bw)
        } else {
            s = SetLog(index: log.sets.count, weight: 0, reps: 0)
        }
        s.exerciseLog = log
        context.insert(s)
        try? context.save()
    }
}

private struct SetEditRow: View {
    @Bindable var set: SetLog
    let isBodyweight: Bool

    var body: some View {
        HStack {
            Text("Set \(set.index + 1)").foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
            if isBodyweight {
                // Edits added weight only — bodyweightAtLog stays frozen at
                // whatever it resolved to when this set was originally
                // logged, and the effective weight is re-derived from it.
                TextField("Added", value: Binding(
                    get: { set.addedWeight ?? 0 },
                    set: { new in
                        set.addedWeight = new
                        set.weight = new + (set.bodyweightAtLog ?? 0)
                    }), format: .number)
                    .keyboardType(.decimalPad)
            } else {
                TextField("Weight", value: $set.weight, format: .number)
                    .keyboardType(.decimalPad)
            }
            Text("×")
            TextField("Reps", value: $set.reps, format: .number)
                .keyboardType(.numberPad)
        }
    }
}
