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
    @Binding var overflowTab: OverflowTab?

    @Environment(\.modelContext) private var context
    @Query(sort: \WorkoutSession.date, order: .reverse) private var sessions: [WorkoutSession]
    @Query(sort: \BodyWeightEntry.date) private var bodyWeights: [BodyWeightEntry]
    @Query(sort: \ExerciseDef.name) private var exerciseDefs: [ExerciseDef]
    @Query(sort: \Phase.number) private var phases: [Phase]

    @State private var showingAddPast = false
    @State private var showingImporter = false
    @State private var showingImportHelp = false
    @State private var importResultMessage: String?
    @State private var searchText = ""
    @State private var editingSessionID: PersistentIdentifier?
    // A big import saves/yields periodically rather than running as one
    // giant unbroken block (see ImportEngine.checkpointInterval) — this just
    // gives the user something to look at while that's in progress instead
    // of an apparently-frozen screen.
    @State private var isImporting = false

    // Import -> auto-drafted-Phase review flow: rows are held here between
    // parsing and the user confirming/editing the detected Phase, since the
    // actual store-import is deferred until the Phase exists to attribute to.
    @State private var showingImportPhaseReview = false
    @State private var seededPhaseDayDrafts: [PhaseBuilderView.DayDraft]?
    @State private var pendingImportRows: [ImportEngine.ImportedEntry] = []
    @State private var pendingImportSkipped = 0
    // The just-created Phase, held until the review sheet has fully
    // dismissed — see the .sheet(onDismiss:) below for why the actual
    // import/alert can't run in the same moment as dismiss().
    @State private var phasePendingImportCompletion: Phase?

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
            .overlay {
                if isImporting {
                    ProgressView("Importing…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .navigationTitle("History")
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Filter by exercise")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Button("Add Past Workout", systemImage: "square.and.pencil") { showingAddPast = true }
                        Button("Import from CSV or Excel…", systemImage: "square.and.arrow.down") { showingImporter = true }
                        Button("Import Format Guide…", systemImage: "questionmark.circle") { showingImportHelp = true }
                    } label: {
                        Image(systemName: "plus")
                    }
                    // Declared last within this same .topBarTrailing group so
                    // it's guaranteed rightmost — mixing .primaryAction and
                    // .topBarTrailing for two different trailing items doesn't
                    // reliably order them relative to each other.
                    OverflowMenuButton(overflowTab: $overflowTab)
                }
            }
            .sheet(isPresented: $showingAddPast) {
                AddHistoricalWorkoutView()
            }
            .sheet(isPresented: $showingImportHelp) {
                CSVFormatHelpView()
            }
            .sheet(isPresented: $showingImportPhaseReview, onDismiss: {
                // PhaseBuilderView calls onPhaseCreated right before its own
                // dismiss() — presenting a NEW alert from that same instant
                // (while this sheet is still mid-dismissal) is a known
                // SwiftUI race that silently drops the presentation, so the
                // actual retroactive import (and its confirmation alert)
                // waits until the sheet has fully closed.
                if let phase = phasePendingImportCompletion {
                    finishImportIntoPhase(phase)
                    phasePendingImportCompletion = nil
                }
            }) {
                PhaseBuilderView(previousPhase: nil, seededDayDrafts: seededPhaseDayDrafts) { newPhase in
                    phasePendingImportCompletion = newPhase
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
                    // cycleNumber 0 means an import row never stated a
                    // Cycle column for this day — nothing to show until
                    // it's corrected (e.g. via the Cycle # field below).
                    Text(session.cycleNumber > 0 ? "Phase \(n), Cycle \(session.cycleNumber)" : "Phase \(n)")
                        .font(.caption2).foregroundStyle(.secondary)
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

    @ViewBuilder
    private func exerciseRow(_ log: ExerciseLog) -> some View {
        if let activity = log.restDayActivity {
            restActivityRow(log, activity)
        } else {
            normalExerciseRow(log)
        }
    }

    /// A rest-day activity's distance (e.g. "3.1 mi") — no weight/reps grid,
    /// since the one SetLog it carries just mirrors that distance for
    /// editing (see SetEditRow), not an actual lift.
    private func restActivityRow(_ log: ExerciseLog, _ activity: RestDayActivity) -> some View {
        HStack {
            Text(log.exerciseName).font(.subheadline.weight(.semibold))
            Spacer()
            if let distance = activity.distance {
                Text("\(Formatters.trim(distance)) \(activity.distanceUnit)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func normalExerciseRow(_ log: ExerciseLog) -> some View {
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
                    Text("lbs")
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
                    Text(idx < sortedSets.count ? weightLabel(sortedSets[idx]) : "")
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

    /// `set.weight` already holds the correct effective total for a
    /// bodyweight set (bodyweightAtLog + addedWeight, frozen at log time —
    /// see SetLog's own doc), same as any other set, so there's no separate
    /// bodyweight case to handle here.
    private func weightLabel(_ set: SetLog) -> String {
        Formatters.trim(set.weight)
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

            // If the file's own rows already explicitly name a Phase that
            // exists, import straight into it — the file already told us
            // exactly where this belongs, so there's nothing to detect or
            // build. Checked before pattern-detection below: a file with a
            // detectable Day pattern AND an explicit, already-existing
            // Phase number should attribute back into that real Phase, not
            // spin up a redundant new one that the file's own Phase column
            // wouldn't even match (ImportEngine only ever attributes a row
            // to the Phase its own Phase column names).
            let statedPhaseNumbers = Set(rows.compactMap(\.phaseNumber))
            if let existingPhase = phases.first(where: { statedPhaseNumbers.contains($0.number) }) {
                pendingImportRows = rows
                pendingImportSkipped = skipped
                finishImportIntoPhase(existingPhase)
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

            isImporting = true
            Task { @MainActor in
                let outcome = await ImportEngine.importIntoStore(rows, context: context)
                WorkoutSession.backfillRestDays(context: context)
                var msg = "Imported \(outcome.setsImported) sets across \(outcome.sessionsCreated) day\(outcome.sessionsCreated == 1 ? "" : "s")."
                if outcome.bodyWeightEntriesCreated > 0 {
                    msg += " Logged \(outcome.bodyWeightEntriesCreated) body weight entr\(outcome.bodyWeightEntriesCreated == 1 ? "y" : "ies")."
                }
                if skipped > 0 { msg += " Skipped \(skipped) row\(skipped == 1 ? "" : "s") that didn't parse." }
                importResultMessage = msg
                isImporting = false
            }
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
        isImporting = true
        Task { @MainActor in
            let outcome = await ImportEngine.importIntoStore(pendingImportRows, context: context, attributeTo: phase)
            // The Phase was created moments ago (startDate defaults to .now),
            // but retroactive attribution can backdate its actual history by
            // months — cyclePaceDelta/adherencePercent both assume every
            // attributed session happened within daysElapsed of startDate,
            // so left at "today" they compare a full history's worth of
            // filled slots against ~1 day of expected pace (hence wildly
            // inflated "N days ahead" / "1400%" readings). Backdate to the
            // earliest session actually attributed here.
            if let earliest = phase.sessions.map(\.date).min(), earliest < phase.startDate {
                phase.startDate = earliest
                try? context.save()
            }
            WorkoutSession.backfillRestDays(context: context)
            var msg = "Imported \(outcome.setsImported) sets across \(outcome.sessionsCreated) day\(outcome.sessionsCreated == 1 ? "" : "s"), attributed to Phase \(phase.number)."
            if outcome.bodyWeightEntriesCreated > 0 {
                msg += " Logged \(outcome.bodyWeightEntriesCreated) body weight entr\(outcome.bodyWeightEntriesCreated == 1 ? "y" : "ies")."
            }
            if pendingImportSkipped > 0 {
                msg += " Skipped \(pendingImportSkipped) row\(pendingImportSkipped == 1 ? "" : "s") that didn't parse."
            }
            importResultMessage = msg
            pendingImportRows = []
            pendingImportSkipped = 0
            seededPhaseDayDrafts = nil
            isImporting = false
        }
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

                Section("Body Weight Example") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Date,Exercise,Sets,Weights,Reps")
                        Text("2026-01-06,Weight,,,172.5")
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
                    Label("Write Day as \"Rest\" or \"Rest Day\" for a rest-day activity instead of an exercise (requires a Day column) — Exercise becomes the activity's name, Reps optionally holds a distance (e.g. \"3.1mi\"), Sets/Weights are unused. Counts toward the rest-bank streak, same as logging it live.",
                          systemImage: "figure.walk")
                    Label("Write Exercise as \"Weight\" to log body weight instead of a real exercise — the weight itself goes in Reps (Sets/Weights are unused). Creates a body weight entry for that date, same as the Weight tab.",
                          systemImage: "scalemass")
                    Label("Phase is that phase's number; Day is the day's name (e.g. \"Push A\"), matched case-insensitively. If given and matched, the imported workout is attributed to that real Phase/Day, just like one logged live. Leave them out (or leave them unmatched) and the row still imports fine as a generic \"Imported\" entry.",
                          systemImage: "calendar.badge.checkmark")
                    Label("If your Day column shows a repeating pattern (Push A / Pull A / Legs A / Rest, over and over), you'll be shown a Phase auto-drafted from the most recently completed cycle to review and edit before anything imports — saving it attributes every matching row in the file to it, not just the last cycle.",
                          systemImage: "calendar.badge.clock")
                    Label("Sets/Weights/Reps are read as plain text, exactly as the cell contains it. If your spreadsheet \"fixes\" a value like 12/12/12 into a date, format that column as Text before typing it, so it isn't mangled in the first place.",
                          systemImage: "text.alignleft")
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
    @Bindable var session: WorkoutSession
    @Query(sort: \Phase.number) private var phases: [Phase]

    @State private var dayReattachmentNote: String?

    private var sortedLogs: [ExerciseLog] {
        session.exerciseLogs.sorted { $0.order < $1.order }
    }

    var body: some View {
        List {
            Section {
                Picker("Phase", selection: Binding(
                    get: { session.phase?.persistentModelID },
                    set: { newID in
                        let newPhase = newID.flatMap { id in phases.first { $0.persistentModelID == id } }
                        changePhase(to: newPhase)
                    })) {
                    Text("None").tag(PersistentIdentifier?.none)
                    ForEach(phases, id: \.persistentModelID) { p in
                        Text("Phase \(p.number)").tag(Optional(p.persistentModelID))
                    }
                }
                if session.phase != nil {
                    HStack {
                        Text("Cycle")
                        Spacer()
                        TextField("Cycle", value: Binding(
                            get: { session.cycleNumber },
                            set: { newValue in
                                session.cycleNumber = max(0, newValue)
                                try? context.save()
                            }), format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                    }
                }
            } footer: {
                if let dayReattachmentNote {
                    Text(dayReattachmentNote).foregroundStyle(.orange)
                } else {
                    Text("Changing Phase moves this day's cycle progress — the day (e.g. \"Push A\") re-matches by name in the new Phase where possible.")
                }
            }
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
                        SetEditRow(set: set, isBodyweight: log.isBodyweight, restDayActivity: log.restDayActivity)
                    }
                    .onDelete { idx in
                        let sorted = log.sortedSets
                        for i in idx { context.delete(sorted[i]) }
                        try? context.save()
                    }
                    if log.restDayActivity == nil {
                        Button("Add Set") { addSet(to: log) }
                    }
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

    /// Reattributing a session to a different Phase leaves its old `day`
    /// (a specific PhaseDay belonging to the OLD phase) meaningless — it's
    /// re-resolved by name (e.g. "Push A") against the new Phase's own
    /// days, same case-insensitive match ImportEngine.matchPhaseDay uses,
    /// so cycle-slot tracking keeps working under the new Phase. If no day
    /// of that name exists there, `day` is cleared rather than left
    /// pointing at a day from a different Phase, and a note explains why.
    /// Cycle # is left as-is either way — edit it separately if it also
    /// needs correcting for the new Phase.
    private func changePhase(to newPhase: Phase?) {
        guard newPhase?.persistentModelID != session.phase?.persistentModelID else { return }
        let oldDayName = session.day?.name
        session.phase = newPhase
        if let newPhase, let oldDayName {
            session.day = newPhase.orderedDays.first { $0.name.localizedCaseInsensitiveCompare(oldDayName) == .orderedSame }
        } else {
            session.day = nil
        }
        dayReattachmentNote = (oldDayName != nil && session.day == nil)
            ? "No day named \"\(oldDayName!)\" in Phase \(newPhase?.number ?? 0) — day cleared."
            : nil
        try? context.save()
    }
}

private struct SetEditRow: View {
    @Bindable var set: SetLog
    let isBodyweight: Bool
    /// Non-nil for a rest-day activity's set — `set.weight` holds its
    /// distance rather than a lifted weight, and edits write through to
    /// keep this record's own `distance` in sync (see StatsEngine's
    /// miles-walked totals, which read from here, not from SetLog). Reps is
    /// a meaningless placeholder (always 1) for these, so it's hidden.
    var restDayActivity: RestDayActivity? = nil

    var body: some View {
        HStack {
            Text("Set \(set.index + 1)").foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
            if let restDayActivity {
                TextField("Distance", value: Binding(
                    get: { set.weight },
                    set: { new in
                        set.weight = new
                        restDayActivity.distance = new
                    }), format: .number)
                    .keyboardType(.decimalPad)
                Text(restDayActivity.distanceUnit).foregroundStyle(.secondary)
            } else if isBodyweight {
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
            if restDayActivity == nil {
                Text("×")
                TextField("Reps", value: $set.reps, format: .number)
                    .keyboardType(.numberPad)
            }
        }
    }
}
