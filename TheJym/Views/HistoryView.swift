//
//  HistoryView.swift
//  TheJym
//
//  Every past workout, with per-exercise total weight moved.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct HistoryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \WorkoutSession.date, order: .reverse) private var sessions: [WorkoutSession]

    @State private var showingAddPast = false
    @State private var showingImporter = false
    @State private var importResultMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if sessions.isEmpty {
                    ContentUnavailableView("No workouts yet",
                                           systemImage: "clock.arrow.circlepath",
                                           description: Text("Your logged sessions will show up here."))
                }
                ForEach(sessions, id: \.persistentModelID) { session in
                    NavigationLink {
                        SessionDetailView(session: session)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(session.cycleNumber > 0
                                     ? "Day \(session.dayLetter) · Cycle \(session.cycleNumber)"
                                     : session.dayLetter)
                                    .font(.headline)
                                if session.isDeload {
                                    Text("DELOAD").font(.caption2.bold())
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(.orange.opacity(0.2), in: Capsule())
                                }
                                Spacer()
                                Text(Formatters.date.string(from: session.date))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text("\(session.exerciseLogs.count) exercises · \(Formatters.trim(session.totalWeightMoved)) lbs moved")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { idx in
                    for i in idx { context.delete(sessions[i]) }
                    try? context.save()
                }
            }
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Add Past Workout", systemImage: "square.and.pencil") { showingAddPast = true }
                        Button("Import from CSV…", systemImage: "square.and.arrow.down") { showingImporter = true }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddPast) {
                AddHistoricalWorkoutView()
            }
            .fileImporter(isPresented: $showingImporter,
                         allowedContentTypes: [.commaSeparatedText, .plainText, .text]) { result in
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

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            importResultMessage = "Couldn't read that file: \(error.localizedDescription)"
        case .success(let url):
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                importResultMessage = "Couldn't read that file as text."
                return
            }
            let (rows, skipped) = ImportEngine.parseRows(csv: text)
            guard !rows.isEmpty else {
                importResultMessage = "No valid rows found. Make sure the sheet has Date, Exercise, Weight, and Reps columns."
                return
            }
            let outcome = ImportEngine.importIntoStore(rows, context: context)
            var msg = "Imported \(outcome.setsImported) sets across \(outcome.sessionsCreated) day\(outcome.sessionsCreated == 1 ? "" : "s")."
            if skipped > 0 { msg += " Skipped \(skipped) row\(skipped == 1 ? "" : "s") that didn't parse." }
            importResultMessage = msg
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
