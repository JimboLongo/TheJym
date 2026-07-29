//
//  BodyWeightView.swift
//  TheJym
//
//  Log body weight (any date, defaults to today), see the trend as a chart,
//  and browse/delete past entries.
//

import SwiftUI
import SwiftData
import Charts

struct BodyWeightView: View {
    @Binding var overflowTab: OverflowTab?

    @Environment(\.modelContext) private var context
    @Query(sort: \BodyWeightEntry.date) private var weights: [BodyWeightEntry]

    @State private var newWeightText = ""
    @State private var newWeightDate = Date()
    @FocusState private var weightFieldFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    DatePicker("Date", selection: $newWeightDate, in: ...Date(), displayedComponents: .date)
                    HStack {
                        TextField("Weight (lbs)", text: $newWeightText)
                            .keyboardType(.decimalPad)
                            .focused($weightFieldFocused)
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
        context.insert(BodyWeightEntry(date: newWeightDate, weight: w))
        try? context.save()
        newWeightText = ""
        newWeightDate = Date()
        weightFieldFocused = false
    }
}
