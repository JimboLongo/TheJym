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
    @Environment(\.modelContext) private var context
    @Query(sort: \Bar.name) private var allBars: [Bar]
    @Query private var settingsList: [AppSettings]

    @State private var newBarName = ""
    @State private var newBarWeightText = ""
    @State private var newPlateSizeText = ""
    @State private var newDumbbellSetName = ""
    @State private var newDumbbellWeightsText = ""

    private var bars: [Bar] { allBars.filter { !$0.isDumbbell } }
    private var dumbbellSets: [Bar] { allBars.filter(\.isDumbbell) }
    private var settings: AppSettings? { settingsList.first }

    var body: some View {
        NavigationStack {
            Form {
                Section("Bars") {
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

                Section("Dumbbells") {
                    ForEach(dumbbellSets, id: \.persistentModelID) { set in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(set.name).font(.headline)
                            Text(set.dumbbellWeights.isEmpty
                                 ? "No weights set"
                                 : set.dumbbellWeights.sorted().map { Formatters.trim($0) }.joined(separator: ", ") + " lb")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { idx in
                        for i in idx { context.delete(dumbbellSets[i]) }
                        try? context.save()
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Set name e.g. Dumbbells", text: $newDumbbellSetName)
                        TextField("Weights you have, comma separated e.g. 5,10,15,20,25,30",
                                  text: $newDumbbellWeightsText)
                            .keyboardType(.numbersAndPunctuation)
                        Button("Add Dumbbell Set") {
                            let weights = newDumbbellWeightsText.split(separator: ",")
                                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                            guard !newDumbbellSetName.isEmpty, !weights.isEmpty else { return }
                            context.insert(Bar(name: newDumbbellSetName, weight: 0,
                                               isDumbbell: true, dumbbellWeights: weights))
                            try? context.save()
                            newDumbbellSetName = ""; newDumbbellWeightsText = ""
                        }
                        .disabled(newDumbbellSetName.isEmpty || newDumbbellWeightsText.isEmpty)
                    }
                }
            }
            .navigationTitle("Equipment")
        }
    }
}
