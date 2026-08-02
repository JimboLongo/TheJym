//
//  BodyWeightView.swift
//  TheJym
//
//  Log body weight — weekly, dated to the nearest Monday, not any arbitrary
//  day — see the trend as a chart, and browse/delete past entries.
//

import SwiftUI
import SwiftData
import Charts

struct BodyWeightView: View {
    @Binding var overflowTab: OverflowTab?

    @Environment(\.modelContext) private var context
    @Query(sort: \BodyWeightEntry.date) private var weights: [BodyWeightEntry]

    @State private var newWeightText = ""
    @State private var selectedWeightDate = Formatters.nearestPastMonday()
    @FocusState private var weightFieldFocused: Bool

    private var existingEntryThisWeek: BodyWeightEntry? {
        weights.first { Calendar.current.isDate($0.date, inSameDayAs: selectedWeightDate) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // Weight is tracked weekly, not daily — whatever day is
                    // tapped snaps to that week's Monday, so only a Monday
                    // is ever actually selectable.
                    DatePicker("Week Starting Monday", selection: Binding(
                        get: { selectedWeightDate },
                        set: { selectedWeightDate = Formatters.nearestPastMonday(from: $0) }
                    ), in: ...Date(), displayedComponents: .date)
                    if existingEntryThisWeek != nil {
                        Text("Already logged this week — logging again updates it.")
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
        if let existing = existingEntryThisWeek {
            existing.weight = w
        } else {
            context.insert(BodyWeightEntry(date: selectedWeightDate, weight: w))
        }
        try? context.save()
        newWeightText = ""
        selectedWeightDate = Formatters.nearestPastMonday()
        weightFieldFocused = false
    }
}
