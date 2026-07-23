//
//  PlateCalcView.swift
//  TheJym
//
//  Pick a bar (with editable weights), enter a target, get plates per side.
//  Barbell 45 + target 100 -> 25 + 2.5 per side.
//  EZ Bar 15 + target 42.5 -> 10 + 2.5 + 1.25 per side.
//

import SwiftUI
import SwiftData

struct PlateCalcView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Bar.name) private var bars: [Bar]

    @State private var selectedBarID: PersistentIdentifier?
    @State private var targetText = ""
    @State private var newBarName = ""
    @State private var newBarWeightText = ""

    private var selectedBar: Bar? {
        bars.first { $0.persistentModelID == selectedBarID } ?? bars.first
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Bar") {
                    Picker("Bar", selection: Binding(
                        get: { selectedBar?.persistentModelID },
                        set: { selectedBarID = $0 })) {
                        ForEach(bars, id: \.persistentModelID) { bar in
                            Text("\(bar.name) (\(Formatters.trim(bar.weight)) lbs)")
                                .tag(Optional(bar.persistentModelID))
                        }
                    }
                    if let bar = selectedBar {
                        LabeledContent("Bar weight") {
                            TextField("lbs", value: Binding(
                                get: { bar.weight },
                                set: { bar.weight = $0; try? context.save() }),
                                format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                        }
                    }
                }

                Section("Target Weight") {
                    TextField("e.g. 100", text: $targetText)
                        .keyboardType(.decimalPad)
                        .font(.system(.title2, design: .monospaced))

                    if let target = Double(targetText), let bar = selectedBar {
                        if let (plates, leftover) = PlateCalculator.plates(target: target, barWeight: bar.weight) {
                            if plates.isEmpty && leftover == 0 {
                                Label("Empty bar — no plates needed", systemImage: "minus.circle")
                            }
                            ForEach(plates) { p in
                                LabeledContent("\(Formatters.trim(p.plate)) lb plate") {
                                    Text("× \(p.countPerSide) per side")
                                        .font(.system(.body, design: .monospaced)).bold()
                                }
                            }
                            if leftover > 0 {
                                Label("Can't hit exactly — \(Formatters.trim(leftover)) lbs/side short. Closest load: \(Formatters.trim(target - leftover * 2)) lbs.",
                                      systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        } else {
                            Label("Target is lighter than the bar.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                        }
                    }
                }

                Section("Add a Bar") {
                    HStack {
                        TextField("Name", text: $newBarName)
                        TextField("lbs", text: $newBarWeightText)
                            .keyboardType(.decimalPad)
                            .frame(width: 70)
                        Button("Add") {
                            if let w = Double(newBarWeightText), !newBarName.isEmpty {
                                context.insert(Bar(name: newBarName, weight: w))
                                try? context.save()
                                newBarName = ""; newBarWeightText = ""
                            }
                        }
                        .disabled(newBarName.isEmpty || Double(newBarWeightText) == nil)
                    }
                    ForEach(bars, id: \.persistentModelID) { bar in
                        Text("\(bar.name) — \(Formatters.trim(bar.weight)) lbs")
                            .foregroundStyle(.secondary)
                    }
                    .onDelete { idx in
                        for i in idx { context.delete(bars[i]) }
                        try? context.save()
                    }
                }
            }
            .navigationTitle("Plate Math")
        }
    }
}
