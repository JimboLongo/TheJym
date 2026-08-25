//
//  TimerView.swift
//  TheJym
//
//  Timer templates — each a named set of timers (a duration + repeat count
//  apiece) you can edit, then run straight through or one at a time
//  (Continuous). The actual countdown/alarm lives in TimerEngine (app-wide,
//  not tied to any one view) so it keeps going — and its alarms keep firing
//  — no matter which tab you switch to.
//

import SwiftUI
import SwiftData

/// Entry point from the hamburger menu — every saved template, tap one to
/// open it for editing/running, or add a new one. A run already in progress
/// (however it was started) surfaces here too, so it's never stranded
/// off-screen just because you navigated away from its template.
struct TimerTemplatesListView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \TimerTemplate.order) private var templates: [TimerTemplate]
    @ObservedObject private var engine = TimerEngine.shared

    @State private var newTemplate: TimerTemplate?

    private var activeTemplate: TimerTemplate? {
        guard engine.isActive else { return nil }
        return templates.first { $0.name == engine.templateName }
    }

    var body: some View {
        NavigationStack {
            List {
                if let activeTemplate {
                    Section {
                        NavigationLink {
                            TimerTemplateDetailView(template: activeTemplate)
                        } label: {
                            runningSummaryRow
                        }
                    }
                }

                Section {
                    ForEach(templates) { template in
                        NavigationLink {
                            TimerTemplateDetailView(template: template)
                        } label: {
                            templateRow(template)
                        }
                    }
                    .onDelete(perform: deleteTemplates)
                    Button {
                        addTemplate()
                    } label: {
                        Label("New Template", systemImage: "plus")
                    }
                } header: {
                    Text("Templates")
                }
            }
            .navigationTitle("Timers")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(item: $newTemplate) { template in
                TimerTemplateDetailView(template: template)
            }
        }
    }

    private func templateRow(_ template: TimerTemplate) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(template.name)
                Text("\(template.presets.count) timer\(template.presets.count == 1 ? "" : "s") · \(Formatters.duration(template.totalSeconds))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if engine.isActive, engine.templateName == template.name {
                Image(systemName: "timer").foregroundStyle(.green)
            }
        }
    }

    private var runningSummaryRow: some View {
        HStack {
            Image(systemName: "timer").foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.templateName ?? "Running").font(.subheadline.bold())
                if let seg = engine.currentSegment {
                    Text("\(seg.presetName) · \(Formatters.duration(engine.remainingSeconds))")
                        .font(.caption).foregroundStyle(.secondary)
                } else if engine.isFinished {
                    Text("Complete").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private func addTemplate() {
        let template = TimerTemplate(name: "New Template", order: templates.count)
        context.insert(template)
        try? context.save()
        newTemplate = template
    }

    private func deleteTemplates(_ idx: IndexSet) {
        for i in idx { context.delete(templates[i]) }
        try? context.save()
    }
}

/// One template's own timers — edit its name, its timers (add/edit/delete/
/// reorder), Continuous, and start/monitor its run.
struct TimerTemplateDetailView: View {
    @Environment(\.modelContext) private var context
    @Bindable var template: TimerTemplate
    @ObservedObject private var engine = TimerEngine.shared
    @State private var editingPreset: TimerPreset?
    @State private var showingAddSheet = false

    private var isThisTemplateRunning: Bool {
        engine.isActive && engine.templateName == template.name
    }

    var body: some View {
        List {
            Section {
                TextField("Name", text: $template.name)
                    .onChange(of: template.name) { _, _ in try? context.save() }
                LabeledContent("Summary") {
                    Text("\(template.presets.count) timer\(template.presets.count == 1 ? "" : "s") · \(Formatters.duration(template.totalSeconds))")
                }
                Toggle("Continuous", isOn: $template.continuous)
                    .onChange(of: template.continuous) { _, _ in try? context.save() }
            }

            Section {
                if isThisTemplateRunning {
                    runningSection
                } else {
                    Button {
                        startRun()
                    } label: {
                        Label("Start", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(template.presets.isEmpty)
                }
            }

            Section("Timers") {
                ForEach(Array(template.orderedPresets.enumerated()), id: \.element.persistentModelID) { index, preset in
                    Button {
                        editingPreset = preset
                    } label: {
                        HStack {
                            Text("\(index + 1).")
                                .foregroundStyle(.secondary)
                                .fixedSize()
                                .frame(width: 28, alignment: .leading)
                            if preset.isRest {
                                Image(systemName: "figure.cooldown")
                                    .foregroundStyle(.blue)
                            }
                            Text(preset.name)
                            Spacer()
                            Text(preset.repeatCount > 1
                                 ? "\(Formatters.duration(preset.seconds)) × \(preset.repeatCount)"
                                 : Formatters.duration(preset.seconds))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .contextMenu {
                        Button {
                            duplicatePreset(preset)
                        } label: {
                            Label("Duplicate", systemImage: "plus.square.on.square")
                        }
                    }
                }
                .onDelete(perform: deletePresets)
                .onMove(perform: movePresets)
                Button {
                    showingAddSheet = true
                } label: {
                    Label("Add Timer", systemImage: "plus")
                }
            }
        }
        .navigationTitle(template.name.isEmpty ? "Timer" : template.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .sheet(item: $editingPreset) { preset in
            TimerPresetEditSheet(draft: TimerPresetDraft(name: preset.name, seconds: preset.seconds,
                                                          repeatCount: preset.repeatCount, isRest: preset.isRest)) { updated in
                preset.name = updated.name.isEmpty ? (updated.isRest ? "Rest" : "Timer") : updated.name
                preset.seconds = updated.seconds
                preset.repeatCount = updated.repeatCount
                preset.isRest = updated.isRest
                try? context.save()
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            TimerPresetEditSheet(draft: nil) { draft in
                let preset = TimerPreset(name: draft.name.isEmpty ? (draft.isRest ? "Rest" : "Timer") : draft.name,
                                         seconds: draft.seconds, repeatCount: draft.repeatCount,
                                         order: template.presets.count, isRest: draft.isRest)
                preset.template = template
                context.insert(preset)
                try? context.save()
            }
        }
    }

    private func deletePresets(_ idx: IndexSet) {
        let ordered = template.orderedPresets
        for i in idx { context.delete(ordered[i]) }
        try? context.save()
    }

    private func movePresets(from: IndexSet, to: Int) {
        var ordered = template.orderedPresets
        ordered.move(fromOffsets: from, toOffset: to)
        for (i, preset) in ordered.enumerated() { preset.order = i }
        try? context.save()
    }

    /// Long-press a timer to copy it, inserted right after the original.
    private func duplicatePreset(_ preset: TimerPreset) {
        var ordered = template.orderedPresets
        guard let idx = ordered.firstIndex(where: { $0.persistentModelID == preset.persistentModelID }) else { return }
        let copy = TimerPreset(name: preset.name, seconds: preset.seconds,
                               repeatCount: preset.repeatCount, order: 0, isRest: preset.isRest)
        copy.template = template
        context.insert(copy)
        ordered.insert(copy, at: idx + 1)
        for (i, p) in ordered.enumerated() { p.order = i }
        try? context.save()
    }

    @ViewBuilder
    private var runningSection: some View {
        if let seg = engine.currentSegment {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if seg.isRest {
                        Image(systemName: "figure.cooldown").foregroundStyle(.blue)
                    }
                    Text(seg.presetName).font(.headline)
                }
                Text("Timer \(seg.presetIndex + 1)/\(seg.presetCount) · Rep \(seg.repIndex)/\(seg.repCount)")
                    .font(.caption).foregroundStyle(.secondary)
                Text(Formatters.duration(engine.remainingSeconds))
                    .font(.system(size: 44, weight: .bold, design: .monospaced))
                    .foregroundStyle(seg.isRest ? .blue : .primary)
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
        engine.start(templateName: template.name,
                     presets: template.orderedPresets.map { (name: $0.name, seconds: $0.seconds, repeatCount: $0.repeatCount, isRest: $0.isRest) },
                     continuous: template.continuous)
    }
}

/// A single timer's edit form — a plain value (not bound directly to a
/// SwiftData model) so the same sheet works for both adding a brand new
/// timer and editing an existing one; the caller decides what to do with
/// the result.
struct TimerPresetDraft: Equatable {
    var name: String = ""
    var seconds: Double = 30
    var repeatCount: Int = 1
    /// A rest timer between work timers — see TimerPreset.isRest.
    var isRest: Bool = false
}

/// Add/edit sheet for one timer — independent minutes and seconds wheels
/// for its duration, a repeat count, and an optional name.
private struct TimerPresetEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var minutes: Int
    @State private var seconds: Int
    @State private var repeatCount: Int
    @State private var isRest: Bool
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
        _isRest = State(initialValue: d.isRest)
        isNew = draft == nil
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Type", selection: $isRest) {
                    Text("Timer").tag(false)
                    Text("Rest").tag(true)
                }
                .pickerStyle(.segmented)
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
                        onSave(TimerPresetDraft(name: name.trimmingCharacters(in: .whitespaces),
                                                seconds: total, repeatCount: repeatCount, isRest: isRest))
                        dismiss()
                    }
                    .disabled(minutes == 0 && seconds == 0)
                }
            }
        }
    }
}
