//
//  RecoveryImportView.swift
//  TheJym
//
//  Restores a TheJym-Export.xlsx. Built for data recovery rather than as a
//  routine feature, which shapes every decision here:
//
//  - NOTHING is written until the preview is confirmed. The import is
//    additive with no dedup (ImportEngine has no context.delete and no
//    session identity key), so a mistaken run can't be undone by running
//    it again differently — it just doubles.
//  - The date floor is the duplicate guard, not a convenience. Set it one
//    day past whatever history already exists.
//  - Walk rows are never guessed at. The file's own exercise names are
//    listed and the user ticks which are really rest-day activities.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct RecoveryImportView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var bodyWeights: [BodyWeightEntry]
    @Query private var exerciseDefs: [ExerciseDef]

    @State private var showingPicker = false
    @State private var fileData: Data?
    @State private var fileName = ""
    @State private var workbook: ImportEngine.Workbook?
    @State private var parseFailed = false

    /// Ticked names import as RestDayActivity instead of lifting logs.
    @State private var activityNames: Set<String> = []
    /// Default floor: the day after the Sept 9 2026 snapshot's last
    /// session, so a restored store isn't double-counted.
    @State private var floorDate = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 10))!
    @State private var useCeiling = false
    @State private var ceilingDate = Date()

    @State private var importing = false
    @State private var result: ImportEngine.ImportResult?

    var body: some View {
        NavigationStack {
            List {
                fileSection
                if let workbook {
                    dateSection
                    activitySection(workbook)
                    librarySection(workbook)
                    previewSection(workbook)
                }
                if let result {
                    Section("Imported") {
                        LabeledContent("Sessions", value: "\(result.sessionsCreated)")
                        LabeledContent("Sets", value: "\(result.setsImported)")
                        LabeledContent("Weigh-ins", value: "\(result.bodyWeightEntriesCreated)")
                    }
                }
            }
            .navigationTitle("Restore from Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(isPresented: $showingPicker,
                          allowedContentTypes: [UTType(filenameExtension: "xlsx") ?? .data],
                          allowsMultipleSelection: false) { outcome in
                load(outcome)
            }
        }
    }

    // MARK: - Sections

    private var fileSection: some View {
        Section {
            Button {
                showingPicker = true
            } label: {
                Label(fileName.isEmpty ? "Choose .xlsx…" : fileName,
                      systemImage: "doc.badge.arrow.up")
            }
            if parseFailed {
                Text("Couldn't read that as an .xlsx workbook.")
                    .font(.caption).foregroundStyle(.red)
            }
        } footer: {
            Text("Reads the History, Exercises and Equipment sheets by name. A file without them falls back to reading the first sheet as history.")
        }
    }

    private var dateSection: some View {
        Section("Date Range") {
            DatePicker("On or after", selection: $floorDate, displayedComponents: .date)
                .onChange(of: floorDate) { _, _ in reparse() }
            Toggle("Limit the end date", isOn: $useCeiling)
                .onChange(of: useCeiling) { _, _ in reparse() }
            if useCeiling {
                DatePicker("On or before", selection: $ceilingDate, displayedComponents: .date)
                    .onChange(of: ceilingDate) { _, _ in reparse() }
            }
        }
    }

    @ViewBuilder
    private func activitySection(_ wb: ImportEngine.Workbook) -> some View {
        Section {
            if wb.candidateNames.isEmpty {
                Text("No exercise names found.").foregroundStyle(.secondary)
            } else {
                ForEach(wb.candidateNames, id: \.self) { name in
                    Button {
                        let key = name.lowercased()
                        if activityNames.contains(key) { activityNames.remove(key) }
                        else { activityNames.insert(key) }
                        reparse()
                    } label: {
                        HStack {
                            Image(systemName: activityNames.contains(name.lowercased())
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(activityNames.contains(name.lowercased()) ? .green : .secondary)
                            Text(name)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text("Rest-Day Activities")
        } footer: {
            Text("Tick any name that's really a rest-day activity rather than a lift — its Weights cell becomes the distance. Nothing is assumed: left unticked, a walk imports as a lifting log and would count toward lift days, both streaks and the rest bank.")
        }
    }

    @ViewBuilder
    private func librarySection(_ wb: ImportEngine.Workbook) -> some View {
        if !wb.library.isEmpty || !wb.equipment.isEmpty || !wb.program.isEmpty {
            Section("Also Restoring") {
                if !wb.library.isEmpty {
                    LabeledContent("Exercise library", value: "\(wb.library.count)")
                }
                if !wb.equipment.isEmpty {
                    LabeledContent("Equipment", value: "\(wb.equipment.count)")
                }
                if !wb.platesOwned.isEmpty {
                    LabeledContent("Plates owned", value: "\(wb.platesOwned.count) sizes")
                }
                if !wb.program.isEmpty {
                    LabeledContent("Phases", value: "\(wb.program.phases.count)")
                    LabeledContent("Phase days", value: "\(wb.program.days.count)")
                    LabeledContent("Planned exercises", value: "\(wb.program.planned.count)")
                    if !wb.program.recoveries.isEmpty {
                        LabeledContent("Rest-day credits", value: "\(wb.program.recoveries.count)")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func previewSection(_ wb: ImportEngine.Workbook) -> some View {
        let filtered = filteredRows(wb)
        let p = ImportEngine.preview(filtered,
                                     existingWeighIns: bodyWeights.map { ($0.date, $0.weight) },
                                     bodyweightExerciseNames: Set(exerciseDefs.filter(\.isBodyweight).map(\.name)))
        Section {
            LabeledContent("Sessions", value: "\(p.sessions)")
            LabeledContent("Exercise logs", value: "\(p.exerciseLogs)")
            LabeledContent("Sets", value: "\(p.sets)")
            LabeledContent("Weigh-ins", value: "\(p.weighIns)")
            LabeledContent("Rest activities", value: "\(p.restActivities)")
            if let first = p.firstDate, let last = p.lastDate {
                LabeledContent("Date range",
                               value: "\(Formatters.date.string(from: first)) – \(Formatters.date.string(from: last))")
            }
            if p.bodyweightSetsResolved + p.bodyweightSetsUnresolved > 0 {
                LabeledContent("Bodyweight sets resolved", value: "\(p.bodyweightSetsResolved)")
                LabeledContent("…with no prior weigh-in", value: "\(p.bodyweightSetsUnresolved)")
                    .foregroundStyle(p.bodyweightSetsUnresolved > 0 ? .orange : .primary)
            }
            // Itemised, never a bare total — a silent skip count is
            // what let 24 dropped weigh-ins look like a detail.
            LabeledContent("Rows in file", value: "\(wb.sourceRowCount)")
                .font(.caption).foregroundStyle(.secondary)
            if !wb.isFullyAccounted {
                Text("⚠︎ \(wb.sourceRowCount - filtered.count - wb.skipped.total) rows unaccounted for — do not import.")
                    .font(.caption).foregroundStyle(.red)
            }
            if wb.skipped.total > 0 {
                LabeledContent("Rows skipped", value: "\(wb.skipped.total)")
                    .foregroundStyle(.orange)
                ForEach(wb.skipped.breakdown, id: \.0) { reason, count in
                    LabeledContent("   \(reason)", value: "\(count)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Button {
                Task { await runImport(wb) }
            } label: {
                if importing { ProgressView() } else { Text("Import \(filtered.count) rows") }
            }
            .disabled(importing || filtered.isEmpty || result != nil)
        } header: {
            Text("Preview")
        } footer: {
            Text("Nothing is written until you tap Import. The import is additive and has no duplicate check — running it twice creates two of everything, so use the date floor rather than re-importing.")
        }
    }

    // MARK: - Work

    /// Already range-filtered during parsing, so this is just the rows.
    private func filteredRows(_ wb: ImportEngine.Workbook) -> [ImportEngine.ImportedEntry] {
        wb.historyRows
    }

    private func load(_ outcome: Result<[URL], Error>) {
        guard case .success(let urls) = outcome, let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { parseFailed = true; return }
        fileData = data
        fileName = url.lastPathComponent
        // "Walk" pre-ticked, since it's the name this app writes — but it
        // is still only a default, and still shown for confirmation.
        activityNames = ["walk"]
        // Unfiltered first, purely to learn the file's own last date for
        // the ceiling default.
        if let full = ImportEngine.parseWorkbook(xlsxData: data, restActivityNames: activityNames),
           let last = full.historyRows.map(\.date).max() {
            ceilingDate = last
        }
        reparse()
        parseFailed = (workbook == nil)
    }

    private func reparse() {
        guard let fileData else { return }
        workbook = ImportEngine.parseWorkbook(xlsxData: fileData, restActivityNames: activityNames,
                                              from: floorDate,
                                              through: useCeiling ? ceilingDate : nil)
    }

    private func runImport(_ wb: ImportEngine.Workbook) async {
        importing = true
        defer { importing = false }
        // Program FIRST: importIntoStore's resolvePhase matches a row's
        // Phase column against an EXISTING Phase, so a session imported
        // before its phase exists lands unattributed with no second pass
        // to fix it.
        ImportEngine.restoreProgram(wb.program, context: context)
        ImportEngine.restoreLibraryAndEquipment(wb, context: context)
        result = await ImportEngine.importIntoStore(filteredRows(wb), context: context)
    }
}
