//
//  BodyLogView.swift
//  TheJym
//
//  One dated table carrying weight AND the five macros, because they're
//  entered in the same sitting and splitting them across tabs would mean
//  switching screens to do half the job.
//
//  A ROW IS A VIEW OVER TWO MODELS, not a stored thing: BodyWeightEntry
//  (which already existed, with its own per-day upsert) and MacroLog.
//  Both are optional on any given day and neither implies the other — this
//  store has 31 weigh-ins against 667 session days, and 500+ days that
//  predate any phase. Absent is nil everywhere, never 0: a day with no
//  fiber entry is a day you didn't record fiber, not a day you ate none.
//
//  WHY THE ROW EXPANDS RATHER THAN SHOWING SIX COLUMNS. Measured at
//  .caption monospaced: a date column plus six 3-digit fields and their
//  gaps needs 276pt against a 288pt budget at 320pt — and that's with no
//  labels and before weight's decimal ("181.5" is five characters, taking
//  it to 300pt). At an accessibility size the same row wants ~890pt
//  against 361pt. Six unlabelled columns would also mean remembering which
//  position is sugar and which is fiber, every day, forever. Expanded, the
//  six fields are labelled, fit every width, and reflow to one column at
//  AX sizes — one tap against typing six numbers.
//

import SwiftUI
import SwiftData

struct BodyLogView: View {
    @Binding var overflowTab: OverflowTab?

    @Environment(\.modelContext) private var context
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Query(sort: \BodyWeightEntry.date) private var weights: [BodyWeightEntry]
    @Query(sort: \MacroLog.date) private var macroLogs: [MacroLog]

    @State private var expanded: Date?

    /// Days to show: every day with either kind of entry, plus today, newest
    /// first. Deliberately not a continuous calendar — a blank row for every
    /// day since Feb 2025 would bury the ones with data.
    private var days: [Date] {
        let cal = Calendar.current
        var set = Set(weights.map { cal.startOfDay(for: $0.date) })
        set.formUnion(macroLogs.map { cal.startOfDay(for: $0.date) })
        set.insert(cal.startOfDay(for: .now))
        return set.sorted(by: >)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(days, id: \.self) { day in
                    DayLogRow(day: day,
                              weight: BodyWeightEntry.entry(on: day, in: weights),
                              macros: MacroLog.log(on: day, in: macroLogs),
                              isExpanded: expanded == day,
                              onToggle: { expanded = expanded == day ? nil : day })
                }
            }
            .navigationTitle("Body")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // The weight chart and swipe-to-delete history still
                    // live in BodyWeightView — this table is for entry.
                    NavigationLink { BodyWeightView(overflowTab: $overflowTab) } label: {
                        Image(systemName: "chart.xyaxis.line")
                    }
                    OverflowMenuButton(overflowTab: $overflowTab)
                }
            }
        }
    }
}

/// One day. Collapsed it shows the two figures worth scanning for — weight
/// and the day's calories — and omits either when it wasn't logged rather
/// than showing a zero.
private struct DayLogRow: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Query(sort: \BodyWeightEntry.date) private var allWeights: [BodyWeightEntry]
    @Query(sort: \MacroLog.date) private var allMacroLogs: [MacroLog]

    let day: Date
    let weight: BodyWeightEntry?
    let macros: MacroLog?
    let isExpanded: Bool
    let onToggle: () -> Void

    @State private var draft: [MacroCategory: String] = [:]
    @State private var weightDraft = ""
    @FocusState private var focused: MacroCategory?

    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onToggle) { summary }.buttonStyle(.plain)
            if isExpanded { editor }
        }
        .padding(.vertical, 2)
        .onChange(of: isExpanded) { _, nowExpanded in
            if nowExpanded { seedDrafts() } else { commit() }
        }
    }

    private var summary: some View {
        HStack {
            Text(isToday ? "Today" : Formatters.date.string(from: day))
                .font(.subheadline.weight(isToday ? .semibold : .regular))
            Spacer()
            // Each figure appears only when it exists. A day with weight and
            // no macros is normal, as is the reverse; neither should read as
            // a zero.
            if let w = weight {
                Text("\(Formatters.trim(w.weight)) lb")
                    .font(.system(.subheadline, design: .monospaced))
            }
            if let cal = macros?.calories {
                Text("\(Formatters.trim(cal)) cal")
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .foregroundStyle(weight == nil && macros == nil ? .secondary : .primary)
    }

    @ViewBuilder
    private var editor: some View {
        // Two columns normally, one at an accessibility size — six labelled
        // fields fit either way, which six columns never could.
        let columns = dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible(), alignment: .leading)]
            : [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            field(label: "Weight", unit: "lb", text: $weightDraft, focus: nil)
            ForEach(MacroCategory.allCases) { category in
                field(label: category.label, unit: "g",
                      text: Binding(get: { draft[category] ?? "" },
                                    set: { draft[category] = $0 }),
                      focus: category)
            }
        }
        if let cal = draftCalories {
            Text("\(Formatters.trim(cal)) cal")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func field(label: String, unit: String,
                       text: Binding<String>, focus: MacroCategory?) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 2)
            TextField("—", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.system(.subheadline, design: .monospaced))
                .frame(width: 58)
                .focused($focused, equals: focus)
            Text(unit).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var draftCalories: Double? {
        let p = Double(draft[.protein] ?? ""), c = Double(draft[.carbs] ?? ""), f = Double(draft[.fat] ?? "")
        guard p != nil || c != nil || f != nil else { return nil }
        return (p ?? 0) * 4 + (c ?? 0) * 4 + (f ?? 0) * 9
    }

    private func seedDrafts() {
        weightDraft = weight.map { Formatters.trim($0.weight) } ?? ""
        draft = Dictionary(uniqueKeysWithValues: MacroCategory.allCases.map { c in
            (c, macros?.grams(c).map(Formatters.trim) ?? "")
        })
    }

    /// Written on collapse rather than per keystroke, so a half-typed "18"
    /// on the way to "185" never lands in the store.
    private func commit() {
        if let w = Double(weightDraft) {
            BodyWeightEntry.upsert(weight: w, on: day, in: allWeights, context: context)
        }
        let values = Dictionary(uniqueKeysWithValues: MacroCategory.allCases.map { c in
            // An emptied field clears that category back to nil — "not
            // logged" is a real answer and has to be reachable.
            (c, Double((draft[c] ?? "").trimmingCharacters(in: .whitespaces)))
        })
        let log = MacroLog.log(on: day, in: allMacroLogs)
        if values.values.allSatisfy({ $0 == nil }) {
            // Nothing left — drop the row rather than keeping an empty one.
            if let log { context.delete(log) }
        } else {
            let target = log ?? {
                let created = MacroLog(date: day)
                context.insert(created)
                return created
            }()
            for c in MacroCategory.allCases { target.setGrams(values[c] ?? nil, for: c) }
        }
        try? context.save()
    }
}
