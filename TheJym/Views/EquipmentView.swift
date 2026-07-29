//
//  EquipmentView.swift
//  TheJym
//
//  Manage the bars you lift with, the plate sizes you own, and your dumbbell
//  sets. This is the source of truth the plate calculator (in the Workout
//  view) draws from.
//

import SwiftUI
import SwiftData

struct EquipmentView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \Bar.name) private var allBars: [Bar]
    @Query private var settingsList: [AppSettings]

    @State private var newBarName = ""
    @State private var newBarWeightText = ""
    @State private var newPlateSizeText = ""
    @State private var newDumbbellWeightText = ""

    private var bars: [Bar] { allBars.filter { !$0.isDumbbell } }
    private var dumbbellSets: [Bar] { allBars.filter(\.isDumbbell) }
    private var dumbbellBar: Bar? { dumbbellSets.first }
    private var settings: AppSettings? { settingsList.first }

    private func ensureDumbbellBar() -> Bar {
        if let existing = dumbbellBar { return existing }
        let bar = Bar(name: "Dumbbells", weight: 0, isDumbbell: true)
        context.insert(bar)
        return bar
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(bars, id: \.persistentModelID) { bar in
                        HStack {
                            Text(bar.name)
                            Spacer()
                            TextField("lbs", value: Binding(
                                get: { bar.weight },
                                set: { bar.weight = $0; try? context.save() }),
                                format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 70)
                            Picker("Sides", selection: Binding(
                                get: { bar.loadableSides },
                                set: { bar.loadableSides = $0; try? context.save() })) {
                                Text("1 side").tag(1)
                                Text("2 sides").tag(2)
                            }
                            .labelsHidden()
                            .frame(width: 100)
                        }
                    }
                    .onDelete { idx in
                        for i in idx { context.delete(bars[i]) }
                        try? context.save()
                    }
                    HStack {
                        TextField("Name e.g. Barbell", text: $newBarName)
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
                } header: {
                    Text("Bars")
                } footer: {
                    Text("Sides is how many sides of that bar you can load plates on — 2 for a standard barbell, 1 for something like a landmine attachment where all the plate weight loads on a single side.")
                }

                Section {
                    Toggle("1.25 lb Dumbbell Attachment", isOn: Binding(
                        get: { settings?.hasDumbbell125Attachment ?? false },
                        set: { settings?.hasDumbbell125Attachment = $0; try? context.save() }))
                    Toggle("2.5 lb Dumbbell Attachment", isOn: Binding(
                        get: { settings?.hasDumbbell25Attachment ?? false },
                        set: { settings?.hasDumbbell25Attachment = $0; try? context.save() }))
                } footer: {
                    Text("When on, the AI Assistant suggests dumbbell weight jumps as fine as the smallest attachment you have on, instead of only jumping by 5 lb.")
                }

                Section("Plate Sizes You Have") {
                    let sizes = (settings?.availablePlateSizes ?? []).sorted(by: >)
                    if sizes.isEmpty {
                        Text("No plate sizes added yet.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(sizes, id: \.self) { size in
                        HStack {
                            Text("\(Formatters.trim(size)) lb")
                            Spacer()
                            Button(role: .destructive) {
                                settings?.availablePlateSizes.removeAll { $0 == size }
                                try? context.save()
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                    }
                    HStack {
                        TextField("Add size e.g. 45", text: $newPlateSizeText)
                            .keyboardType(.decimalPad)
                        Button("Add") {
                            if let w = Double(newPlateSizeText), let s = settings, !s.availablePlateSizes.contains(w) {
                                s.availablePlateSizes.append(w)
                                try? context.save()
                                newPlateSizeText = ""
                            }
                        }
                        .disabled(Double(newPlateSizeText) == nil)
                    }
                }

                Section("Dumbbell Weights You Have") {
                    let weights = (dumbbellBar?.dumbbellWeights ?? []).sorted(by: >)
                    if weights.isEmpty {
                        Text("No dumbbell weights added yet.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(weights, id: \.self) { w in
                        HStack {
                            Text("\(Formatters.trim(w)) lb")
                            Spacer()
                            Button(role: .destructive) {
                                dumbbellBar?.dumbbellWeights.removeAll { $0 == w }
                                try? context.save()
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                    }
                    HStack {
                        TextField("Add weight e.g. 25", text: $newDumbbellWeightText)
                            .keyboardType(.decimalPad)
                        Button("Add") {
                            if let w = Double(newDumbbellWeightText) {
                                let bar = ensureDumbbellBar()
                                if !bar.dumbbellWeights.contains(w) {
                                    bar.dumbbellWeights.append(w)
                                }
                                try? context.save()
                                newDumbbellWeightText = ""
                            }
                        }
                        .disabled(Double(newDumbbellWeightText) == nil)
                    }
                }
            }
            .navigationTitle("Equipment")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
