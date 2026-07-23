//
//  HistoryView.swift
//  TheJym
//
//  Every past workout, with per-exercise total weight moved.
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

struct HistoryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \WorkoutSession.date, order: .reverse) private var sessions: [WorkoutSession]

    @State private var showingAddPast = false
    @State private var showingImporter = false
    @State private var showingImportHelp = false
    @State private var importResultMessage: String?
    @State private var searchText = ""
    @State private var editingLog: ExerciseLog?
    @State private var showingEdit = false

    /// One row per logged exercise (not per session) — Sets/Weights/Reps are
    /// per-exercise, so that's the natural row unit for a flat table.
    private struct Row: Identifiable {
        let log: ExerciseLog
        let session: WorkoutSession
        var id: PersistentIdentifier { log.persistentModelID }
    }

    private var rows: [Row] {
        sessions.flatMap { session in
            session.exerciseLogs.sorted { $0.order < $1.order }.map { Row(log: $0, session: session) }
        }
    }

    private var filteredRows: [Row] {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return rows }
        return rows.filter { $0.log.exerciseName.localizedCaseInsensitiveContains(trimmed) }
    }

    private enum Col {
        static let day: CGFloat = 62
        static let phase: CGFloat = 48
        static let source: CGFloat = 70
        static let action: CGFloat = 32
    }

    // Exercise/Lifts are sized from the longest string that'll ever land in
    // them (monospaced font, so character count maps to width reliably) —
    // that way nothing ever wraps or gets cut off.
    private static let charWidth: CGFloat = 7.4
    private static let colPadding: CGFloat = 16

    private var exerciseColWidth: CGFloat {
        let longest = rows.reduce(8) { longest, row in
            let sets = row.log.targetReps.map(String.init).joined(separator: "/")
            return max(longest, row.log.exerciseName.count, sets.count)
        }
        return CGFloat(longest) * Self.charWidth + Self.colPadding
    }

    private var liftsColWidth: CGFloat {
        let longest = rows.reduce(5) { longest, row in
            let sortedSets = row.log.sortedSets
            let weights = sortedSets.map { Formatters.trim($0.weight) }.joined(separator: "/")
            let reps = "(" + sortedSets.map { String($0.reps) }.joined(separator: "/") + ")"
            return max(longest, weights.count, reps.count)
        }
        return CGFloat(longest) * Self.charWidth + Self.colPadding
    }

    var body: some View {
        NavigationStack {
            Group {
                if rows.isEmpty {
                    ContentUnavailableView("No workouts yet",
                                           systemImage: "clock.arrow.circlepath",
                                           description: Text("Your logged sessions will show up here."))
                } else if filteredRows.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    GeometryReader { geo in
                        ScrollView(.horizontal) {
                            ScrollView(.vertical) {
                                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                                    Section {
                                        ForEach(filteredRows) { row in
                                            rowView(row)
                                            Divider()
                                        }
                                    } header: {
                                        VStack(spacing: 0) {
                                            headerRow
                                            Divider()
                                        }
                                    }
                                }
                            }
                            .frame(height: geo.size.height)
                        }
                    }
                }
            }
            .navigationTitle("History")
            .searchable(text: $searchText, prompt: "Filter by exercise")
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
            .sheet(isPresented: $showingEdit) {
                if let editingLog {
                    EditExerciseLogView(log: editingLog)
                }
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Col.action)
            HStack(spacing: 0) {
                Text("Day").frame(width: Col.day, alignment: .leading)
                Text("Phase").frame(width: Col.phase, alignment: .leading)
                Text("Exercise").frame(width: exerciseColWidth, alignment: .leading)
                Text("Lifts").frame(width: liftsColWidth, alignment: .leading)
                Text("Source").frame(width: Col.source, alignment: .leading)
            }
            .padding(.horizontal, 12)
            Color.clear.frame(width: Col.action)
        }
        .font(.caption.bold())
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func rowView(_ row: Row) -> some View {
        let log = row.log
        let sets = log.targetReps.map(String.init).joined(separator: "/")
        let sortedSets = log.sortedSets
        let weights = sortedSets.map { Formatters.trim($0.weight) }.joined(separator: "/")
        let reps = sortedSets.map { String($0.reps) }.joined(separator: "/")
        let source = row.session.dayLabel == "Imported" ? "Imported" : "Logged"

        return HStack(spacing: 0) {
            Button {
                editingLog = log
                showingEdit = true
            } label: {
                Image(systemName: "pencil").foregroundStyle(.blue)
            }
            .frame(width: Col.action)
            .buttonStyle(.plain)

            NavigationLink {
                SessionDetailView(session: row.session)
            } label: {
                HStack(spacing: 0) {
                    Text(Formatters.shortDate.string(from: row.session.date)).frame(width: Col.day, alignment: .leading)
                    Text(row.session.phase.map { String($0.number) } ?? "—").frame(width: Col.phase, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(log.exerciseName)
                        Text(sets.isEmpty ? "—" : sets).foregroundStyle(.secondary)
                    }
                    .frame(width: exerciseColWidth, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(weights)
                        Text("(\(reps))").foregroundStyle(.secondary)
                    }
                    .frame(width: liftsColWidth, alignment: .leading)
                    Text(source).frame(width: Col.source, alignment: .leading)
                }
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                delete(row)
            } label: {
                Image(systemName: "trash").foregroundStyle(.red)
            }
            .frame(width: Col.action)
            .buttonStyle(.plain)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.vertical, 6)
    }

    private func delete(_ row: Row) {
        if row.session.exerciseLogs.count <= 1 {
            context.delete(row.session)
        } else {
            context.delete(row.log)
        }
        try? context.save()
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
            let outcome = ImportEngine.importIntoStore(rows, context: context)
            var msg = "Imported \(outcome.setsImported) sets across \(outcome.sessionsCreated) day\(outcome.sessionsCreated == 1 ? "" : "s")."
            if skipped > 0 { msg += " Skipped \(skipped) row\(skipped == 1 ? "" : "s") that didn't parse." }
            importResultMessage = msg
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
                    Text("Columns (any order): **Date**, **Exercise**, **Sets**, **Weights**, **Reps**.")
                    Text("One row = one exercise logged on one day. Sets, Weights, and Reps are slash-separated, one value per set, in the same order.")
                        .foregroundStyle(.secondary)
                }

                Section("Example") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Date,Exercise,Sets,Weights,Reps")
                        Text("2026-01-05,Back Squat,5/5/5/3/3,135/135/135/145/145,6/5/5/5/3")
                    }
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                }

                Section {
                    Label("Sets is the target rep scheme (e.g. 5/5/5/3/3) — it becomes a saved Set for that exercise in the Exercises tab.",
                          systemImage: "list.bullet.rectangle")
                    Label("Weights and Reps are what you actually lifted, and must have the same number of slash-separated values as each other.",
                          systemImage: "checkmark.circle")
                    Label("Leave Sets blank if there was no real target — the exercise still gets logged, just without a saved Set.",
                          systemImage: "questionmark.circle")
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

struct SessionDetailView: View {
    let session: WorkoutSession

    var body: some View {
        List {
            ForEach(session.exerciseLogs.sorted { $0.order < $1.order }, id: \.persistentModelID) { log in
                Section(log.exerciseName) {
                    if !log.targetReps.isEmpty {
                        LabeledContent("Goal", value: log.targetReps.map(String.init).joined(separator: "/"))
                    }
                    ForEach(log.sortedSets, id: \.persistentModelID) { s in
                        LabeledContent("Set \(s.index + 1)",
                                       value: "\(Formatters.trim(s.weight)) × \(s.reps) = \(Formatters.trim(s.weight * Double(s.reps)))")
                            .font(.system(.subheadline, design: .monospaced))
                    }
                    LabeledContent("Total Weight Moved") {
                        Text("\(Formatters.trim(log.totalWeightMoved)) lbs").bold()
                    }
                }
            }
        }
        .navigationTitle(Formatters.date.string(from: session.date))
    }
}

/// Edit an already-logged exercise entry in place: its name, target Sets
/// scheme, and the actual weight/reps of each set.
struct EditExerciseLogView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var log: ExerciseLog

    @State private var targetRepsText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Exercise") {
                    TextField("Exercise name", text: $log.exerciseName)
                }
                Section("Sets (target)") {
                    TextField("e.g. 5/5/5/3/3", text: $targetRepsText)
                        .keyboardType(.numbersAndPunctuation)
                        .onChange(of: targetRepsText) { _, new in
                            log.targetReps = new.split(separator: "/").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                        }
                }
                Section("Lifts") {
                    ForEach(log.sortedSets, id: \.persistentModelID) { set in
                        SetEditRow(set: set)
                    }
                    .onDelete { idx in
                        let sorted = log.sortedSets
                        for i in idx { context.delete(sorted[i]) }
                        renumberSets()
                    }
                    Button("Add Set") { addSet() }
                }
            }
            .navigationTitle("Edit Entry")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { try? context.save(); dismiss() }
                }
            }
            .onAppear {
                targetRepsText = log.targetReps.map(String.init).joined(separator: "/")
            }
        }
    }

    private func addSet() {
        let s = SetLog(index: log.sets.count, weight: 0, reps: 0)
        s.exerciseLog = log
        context.insert(s)
    }

    private func renumberSets() {
        for (i, s) in log.sortedSets.enumerated() { s.index = i }
    }
}

private struct SetEditRow: View {
    @Bindable var set: SetLog

    var body: some View {
        HStack {
            Text("Set \(set.index + 1)").foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
            TextField("Weight", value: $set.weight, format: .number)
                .keyboardType(.decimalPad)
            Text("×")
            TextField("Reps", value: $set.reps, format: .number)
                .keyboardType(.numberPad)
        }
    }
}
