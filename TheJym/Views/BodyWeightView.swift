//
//  BodyWeightView.swift
//  TheJym
//
//  Log body weight — dated to the day it's taken (7220a8d; it used to snap
//  to the week's Monday) — see the trend as a chart, and browse/delete past
//  entries.
//

import SwiftUI
import SwiftData
import Charts

struct BodyWeightView: View {
    @Binding var overflowTab: OverflowTab?

    @Environment(\.modelContext) private var context
    @Query(sort: \BodyWeightEntry.date) private var weights: [BodyWeightEntry]

    @State private var newWeightText = ""
    @State private var selectedWeightDate = Calendar.current.startOfDay(for: .now)
    @FocusState private var weightFieldFocused: Bool

    /// One entry per calendar day — logging twice on a day updates it,
    /// two different days in one week are two entries.
    private var existingEntryOnSelectedDay: BodyWeightEntry? {
        BodyWeightEntry.entry(on: selectedWeightDate, in: weights)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // Weigh-ins are recorded to the day they're taken
                    // (7220a8d; they used to snap to the week's Monday).
                    //
                    // Normalised to midnight rather than stored raw: a
                    // date-only picker carries the bound value's time
                    // along, and BodyWeightEntry.resolved(asOf:) matches
                    // `entry.date <= date`, so an entry stamped 3pm would
                    // not resolve for a workout logged at 9am the same
                    // day.
                    DatePicker("Date", selection: Binding(
                        get: { selectedWeightDate },
                        set: { selectedWeightDate = Calendar.current.startOfDay(for: $0) }
                    ), in: ...Date(), displayedComponents: .date)
                    if existingEntryOnSelectedDay != nil {
                        Text("Already logged on this date — logging again updates it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        TextField("Weight (lbs)", text: $newWeightText)
                            .keyboardType(.decimalPad)
                            .focused($weightFieldFocused)
                            .onSubmit { logWeight() }
                            .toolbar {
                                ToolbarItemGroup(placement: .keyboard) {
                                    Button {
                                        weightFieldFocused = false
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                    }
                                    Spacer()
                                    Button("Log") { logWeight() }
                                        .disabled(Double(newWeightText) == nil)
                                }
                            }
                        Button("Log") {
                            logWeight()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(Double(newWeightText) == nil)
                    }
                }

                if weights.count >= 2 {
                    Section {
                        Chart(weights, id: \.persistentModelID) { entry in
                            LineMark(x: .value("Date", entry.date),
                                     y: .value("Weight", entry.weight))
                            PointMark(x: .value("Date", entry.date),
                                      y: .value("Weight", entry.weight))
                        }
                        .chartYScale(domain: .automatic(includesZero: false))
                        .frame(height: 180)
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    ForEach(weights.reversed(), id: \.persistentModelID) { e in
                        LabeledContent(Formatters.date.string(from: e.date),
                                      value: "\(Formatters.trim(e.weight)) lbs")
                    }
                    .onDelete { idx in
                        let reversed = Array(weights.reversed())
                        for i in idx { context.delete(reversed[i]) }
                        try? context.save()
                    }
                }
            }
            .navigationTitle("Body Weight")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    OverflowMenuButton(overflowTab: $overflowTab)
                }
            }
        }
    }

    private func logWeight() {
        guard let w = Double(newWeightText) else { return }
        // The shared upsert, so this screen and the Body table can't drift
        // into two different per-day write rules.
        BodyWeightEntry.upsert(weight: w, on: selectedWeightDate, in: weights, context: context)
        try? context.save()
        newWeightText = ""
        selectedWeightDate = Calendar.current.startOfDay(for: .now)
        weightFieldFocused = false
    }
}
