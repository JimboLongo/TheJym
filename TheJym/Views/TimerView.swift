//
//  TimerView.swift
//  TheJym
//
//  A working set of timers (each with a duration + repeat count) you can
//  start, run straight through or one at a time (Continuous), and save as a
//  named template to reload later. The actual countdown/alarm lives in
//  TimerEngine (app-wide, not tied to this view) so it keeps going — and its
//  alarms keep firing — no matter which tab you switch to.
//

import SwiftUI
import SwiftData

/// One timer in the working set being edited — a plain Codable value (not a
/// SwiftData model) so it can be freely drafted/reordered/persisted to
/// UserDefaults without touching the store until explicitly saved as a
/// template.
struct TimerPresetDraft: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String = ""
    var seconds: Double = 30
    var repeatCount: Int = 1
}

struct TimerListView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \TimerTemplate.order) private var templates: [TimerTemplate]
    @ObservedObject private var engine = TimerEngine.shared

    @State private var drafts: [TimerPresetDraft] = []
    @State private var continuous = false
    @State private var workingSetName = "Timers"
    @State private var editingDraft: TimerPresetDraft?
    @State private var showingAddSheet = false
    @State private var showingLoadSheet = false
    @State private var showingSaveAlert = false
    @State private var saveNameText = ""

    private var totalSeconds: Double {
        drafts.reduce(0) { $0 + $1.seconds * Double(max(1, $1.repeatCount)) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Timers") { Text("\(drafts.count)") }
                    LabeledContent("Total Time") { Text(Formatters.duration(totalSeconds)) }
                    Toggle("Continuous", isOn: $continuous)
                        .onChange(of: continuous) { _, _ in saveWorkingSet() }
                } footer: {
                    Text("Continuous runs straight through every timer and repeat without stopping. Off, it pauses after each one until you tap Start Next. Either way, the alarm still sounds even if you leave this screen.")
                }

                Section("Timers") {
                    ForEach(drafts) { draft in
                        Button {
                            editingDraft = draft
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(draft.name.isEmpty ? "Timer" : draft.name)
                                    Text(draft.repeatCount > 1
                                         ? "\(Formatters.duration(draft.seconds)) × \(draft.repeatCount)"
                                         : Formatters.duration(draft.seconds))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                    }
                    .onDelete { idx in
                        drafts.remove(atOffsets: idx)
                        saveWorkingSet()
                    }
                    .onMove { from, to in
                        drafts.move(fromOffsets: from, toOffset: to)
                        saveWorkingSet()
                    }
                    Button {
                        showingAddSheet = true
                    } label: {
                        Label("Add Timer", systemImage: "plus")
                    }
                }

                Section {
                    if engine.isActive {
                        runningSection
                    } else {
                        Button {
                            startRun()
                        } label: {
                            Label("Start", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(drafts.isEmpty)
                    }
                }
            }
            .navigationTitle(workingSetName)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showingLoadSheet = true
                        } label: {
                            Label("Load Template…", systemImage: "tray.and.arrow.down")
                        }
                        .disabled(templates.isEmpty)
                        Button {
                            saveNameText = workingSetName == "Timers" ? "" : workingSetName
                            showingSaveAlert = true
                        } label: {
                            Label("Save as Template…", systemImage: "tray.and.arrow.up")
                        }
                        .disabled(drafts.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
            }
            .onAppear(perform: loadWorkingSet)
            .sheet(item: $editingDraft) { draft in
                TimerPresetEditSheet(draft: draft) { updated in
                    if let idx = drafts.firstIndex(where: { $0.id == updated.id }) {
                        drafts[idx] = updated
                    }
                    saveWorkingSet()
                }
            }
            .sheet(isPresented: $showingAddSheet) {
                TimerPresetEditSheet(draft: nil) { new in
                    drafts.append(new)
                    saveWorkingSet()
                }
            }
            .sheet(isPresented: $showingLoadSheet) {
                TemplatePickerSheet(templates: templates, onLoad: { template in
                    loadTemplate(template)
                    showingLoadSheet = false
                }, onDelete: { template in
                    context.delete(template)
                    try? context.save()
                })
            }
            .alert("Save as Template", isPresented: $showingSaveAlert) {
                TextField("Name", text: $saveNameText)
                Button("Save") { saveAsTemplate() }
                Button("Cancel", role: .cancel) { }
            }
        }
    }

    @ViewBuilder
    private var runningSection: some View {
        if let seg = engine.currentSegment {
            VStack(alignment: .leading, spacing: 6) {
                Text(seg.presetName).font(.headline)
                Text("Timer \(seg.presetIndex + 1)/\(seg.presetCount) · Rep \(seg.repIndex)/\(seg.repCount)")
                    .font(.caption).foregroundStyle(.secondary)
                Text(Formatters.duration(engine.remainingSeconds))
                    .font(.system(size: 44, weight: .bold, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 4)
                if engine.isAwaitingManualStart {
                    Button {
                        engine.startNext()
                    } label: {
                        Label("Start Next", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        } else if engine.isFinished {
            Text("All timers complete! 🎉")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        Button(role: .destructive) {
            engine.stop()
        } label: {
            Label("Stop", systemImage: "stop.fill")
                .frame(maxWidth: .infinity)
        }
    }

    private func startRun() {
        engine.start(templateName: workingSetName,
                     presets: drafts.map { (name: $0.name.isEmpty ? "Timer" : $0.name, seconds: $0.seconds, repeatCount: $0.repeatCount) },
                     continuous: continuous)
    }

    private func loadTemplate(_ template: TimerTemplate) {
        drafts = template.orderedPresets.map {
            TimerPresetDraft(name: $0.name, seconds: $0.seconds, repeatCount: $0.repeatCount)
        }
        continuous = template.continuous
        workingSetName = template.name
        saveWorkingSet()
    }

    /// Overwrites an existing template of the same name (case-insensitive)
    /// rather than creating a duplicate.
    private func saveAsTemplate() {
        let trimmed = saveNameText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let target: TimerTemplate
        if let existing = templates.first(where: { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) {
            for preset in existing.presets { context.delete(preset) }
            existing.presets = []
            target = existing
        } else {
            target = TimerTemplate(name: trimmed, order: templates.count)
            context.insert(target)
        }
        target.name = trimmed
        target.continuous = continuous
        for (i, draft) in drafts.enumerated() {
            let preset = TimerPreset(name: draft.name.isEmpty ? "Timer" : draft.name,
                                     seconds: draft.seconds, repeatCount: draft.repeatCount, order: i)
            preset.template = target
            context.insert(preset)
        }
        try? context.save()
        workingSetName = trimmed
        saveWorkingSet()
    }

    // MARK: Working-set persistence (survives tab switches / app close, same
    // pattern WorkoutLogView uses for its own in-progress draft).

    private struct WorkingSet: Codable {
        var name: String
        var drafts: [TimerPresetDraft]
        var continuous: Bool
    }
    private let workingSetKey = "TimerListView.workingSet"

    private func loadWorkingSet() {
        guard let data = UserDefaults.standard.data(forKey: workingSetKey),
              let saved = try? JSONDecoder().decode(WorkingSet.self, from: data) else { return }
        drafts = saved.drafts
        continuous = saved.continuous
        workingSetName = saved.name
    }

    private func saveWorkingSet() {
        let saved = WorkingSet(name: workingSetName, drafts: drafts, continuous: continuous)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        UserDefaults.standard.set(data, forKey: workingSetKey)
    }
}

/// Add/edit sheet for one timer in the working set — independent minutes
/// and seconds wheels for its duration, a repeat count, and an optional
/// name.
private struct TimerPresetEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var minutes: Int
    @State private var seconds: Int
    @State private var repeatCount: Int
    private let existingID: UUID
    private let isNew: Bool
    let onSave: (TimerPresetDraft) -> Void

    /// Short enough to keep the sheet compact — SwiftUI's default wheel
    /// height is much taller than this control needs.
    private let wheelHeight: CGFloat = 100

    init(draft: TimerPresetDraft?, onSave: @escaping (TimerPresetDraft) -> Void) {
        let d = draft ?? TimerPresetDraft()
        _name = State(initialValue: d.name)
        _minutes = State(initialValue: Int(d.seconds) / 60)
        _seconds = State(initialValue: Int(d.seconds) % 60)
        _repeatCount = State(initialValue: d.repeatCount)
        existingID = d.id
        isNew = draft == nil
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name (e.g. Sprint, Rest)", text: $name)
                HStack(spacing: 0) {
                    Picker("Minutes", selection: $minutes) {
                        ForEach(0..<60, id: \.self) { m in Text("\(m) min").tag(m) }
                    }
                    .pickerStyle(.wheel)
                    .frame(maxWidth: .infinity, maxHeight: wheelHeight)
                    .clipped()

                    Picker("Seconds", selection: $seconds) {
                        ForEach(0..<60, id: \.self) { s in Text("\(s) sec").tag(s) }
                    }
                    .pickerStyle(.wheel)
                    .frame(maxWidth: .infinity, maxHeight: wheelHeight)
                    .clipped()
                }
                Stepper("Repeat: \(repeatCount)×", value: $repeatCount, in: 1...50)
            }
            .navigationTitle(isNew ? "Add Timer" : "Edit Timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let total = Double(minutes * 60 + seconds)
                        onSave(TimerPresetDraft(id: existingID, name: name.trimmingCharacters(in: .whitespaces),
                                                seconds: total, repeatCount: repeatCount))
                        dismiss()
                    }
                    .disabled(minutes == 0 && seconds == 0)
                }
            }
        }
    }
}

/// Sheet listing every saved template — tap to load it into the working
/// set, swipe to delete it outright.
private struct TemplatePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let templates: [TimerTemplate]
    let onLoad: (TimerTemplate) -> Void
    let onDelete: (TimerTemplate) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(templates, id: \.persistentModelID) { template in
                    Button {
                        onLoad(template)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(template.name)
                                Text("\(template.presets.count) timer\(template.presets.count == 1 ? "" : "s") · \(Formatters.duration(template.totalSeconds))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                }
                .onDelete { idx in
                    for i in idx { onDelete(templates[i]) }
                }
            }
            .navigationTitle("Saved Templates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
