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

    private enum Col {
        static let day: CGFloat = 76
        static let phase: CGFloat = 48
        static let exercise: CGFloat = 150
        static let sets: CGFloat = 74
        static let weights: CGFloat = 120
        static let reps: CGFloat = 90
        static let source: CGFloat = 70
        static let delete: CGFloat = 32
    }

    var body: some View {
        NavigationStack {
            Group {
                if rows.isEmpty {
                    ContentUnavailableView("No workouts yet",
                                           systemImage: "clock.arrow.circlepath",
                                           description: Text("Your logged sessions will show up here."))
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        VStack(alignment: .leading, spacing: 0) {
                            headerRow
                            Divider()
                            ForEach(rows) { row in
                                rowView(row)
                                Divider()
                            }
                        }
                    }
                }
            }
            .navigationTitle("History")
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
        }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            Text("Day").frame(width: Col.day, alignment: .leading)
            Text("Phase").frame(width: Col.phase, alignment: .leading)
            Text("Exercise").frame(width: Col.exercise, alignment: .leading)
            Text("Sets").frame(width: Col.sets, alignment: .leading)
            Text("Weights").frame(width: Col.weights, alignment: .leading)
            Text("Reps").frame(width: Col.reps, alignment: .leading)
            Text("Source").frame(width: Col.source, alignment: .leading)
            Color.clear.frame(width: Col.delete)
        }
        .font(.caption.bold())
        .padding(.horizontal, 12)
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
            NavigationLink {
                SessionDetailView(session: row.session)
            } label: {
                HStack(spacing: 0) {
                    Text(Formatters.shortDate.string(from: row.session.date)).frame(width: Col.day, alignment: .leading)
                    Text(row.session.phase.map { String($0.number) } ?? "—").frame(width: Col.phase, alignment: .leading)
                    Text(log.exerciseName).frame(width: Col.exercise, alignment: .leading).lineLimit(1)
                    Text(sets.isEmpty ? "—" : sets).frame(width: Col.sets, alignment: .leading)
                    Text(weights).frame(width: Col.weights, alignment: .leading)
                    Text(reps).frame(width: Col.reps, alignment: .leading)
                    Text(source).frame(width: Col.source, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                delete(row)
            } label: {
                Image(systemName: "trash").foregroundStyle(.red)
            }
            .frame(width: Col.delete)
            .buttonStyle(.plain)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.horizontal, 12)
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
