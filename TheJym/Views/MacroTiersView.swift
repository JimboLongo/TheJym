//
//  MacroTiersView.swift
//  TheJym
//
//  Define the named macro targets — "Cut", "Maintain", "Bulk" — that a
//  cycle gets tagged with and a day's logged totals are compared against.
//
//  Named rather than numbered: the name is what a tagged cycle and every
//  day of macro history ends up stamped with, and "Tier 3" six months on
//  is unreadable where "Cut" needs no decoding.
//

import SwiftUI
import SwiftData

struct MacroTiersView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \MacroTier.order) private var tiers: [MacroTier]

    @State private var editing: MacroTier?
    @State private var creating = false

    var body: some View {
        NavigationStack {
            List {
                if tiers.isEmpty {
                    ContentUnavailableView(
                        "No Tiers Yet", systemImage: "chart.pie",
                        description: Text("A tier is a named set of macro targets — Cut, Maintain, Bulk — that you tag a cycle with."))
                } else {
                    Section {
                        ForEach(tiers) { tier in
                            Button { editing = tier } label: { row(tier) }
                                .buttonStyle(.plain)
                        }
                        .onMove(perform: move)
                        .onDelete(perform: delete)
                    } footer: {
                        Text("Calories are 4×protein + 4×carbs + 9×fat. Sugar and fiber are part of carbs, so they're tracked but never added on top.")
                    }
                }
                Section {
                    Button { creating = true } label: { Label("Add a Tier", systemImage: "plus") }
                }
            }
            .navigationTitle("Macro Tiers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if !tiers.isEmpty { ToolbarItem(placement: .primaryAction) { EditButton() } }
            }
            .sheet(isPresented: $creating) {
                MacroTierEditSheet(tier: nil, existing: tiers, nextOrder: tiers.count)
            }
            .sheet(item: $editing) { tier in
                MacroTierEditSheet(tier: tier, existing: tiers, nextOrder: tier.order)
            }
        }
    }

    private func row(_ tier: MacroTier) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(tier.name).font(.headline)
                Spacer()
                Text("\(Formatters.trim(tier.calories)) cal")
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            // Every category on one line, each with the direction its
            // target points — so a tier reads as the intent it encodes
            // rather than five bare numbers.
            Text(MacroCategory.allCases
                    .map { "\($0.label) \($0.direction.symbol)\(Formatters.trim(tier.grams($0)))g" }
                    .joined(separator: " · "))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(tier.vintageLabel)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if let warning = tier.coherenceWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private func move(from source: IndexSet, to destination: Int) {
        var ordered = tiers
        ordered.move(fromOffsets: source, toOffset: destination)
        for (i, tier) in ordered.enumerated() { tier.order = i }
        try? context.save()
    }

    private func delete(_ offsets: IndexSet) {
        for i in offsets { context.delete(tiers[i]) }
        // Renumber so a later insert doesn't land on a used order.
        for (i, tier) in tiers.enumerated() where !offsets.contains(i) { tier.order = i }
        try? context.save()
    }
}

/// Create or edit one tier. Calories update as you type, so the number you
/// are actually steering by is visible while steering.
struct MacroTierEditSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let tier: MacroTier?
    let existing: [MacroTier]
    let nextOrder: Int

    @State private var name: String
    @State private var grams: [MacroCategory: String]

    init(tier: MacroTier?, existing: [MacroTier], nextOrder: Int) {
        self.tier = tier
        self.existing = existing
        self.nextOrder = nextOrder
        _name = State(initialValue: tier?.name ?? "")
        _grams = State(initialValue: Dictionary(uniqueKeysWithValues:
            MacroCategory.allCases.map { c in
                (c, tier.map { Formatters.trim($0.grams(c)) } ?? "")
            }))
    }

    private func value(_ c: MacroCategory) -> Double { Double(grams[c] ?? "") ?? 0 }

    private var calories: Double {
        4 * value(.protein) + 4 * value(.carbs) + 9 * value(.fat)
    }
    private var subsetsExceedCarbs: Bool {
        value(.sugar) + value(.fiber) > value(.carbs)
    }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var nameIsTaken: Bool {
        MacroTier.nameIsTaken(trimmedName, excluding: tier, in: existing)
    }
    private var canSave: Bool { !trimmedName.isEmpty && !nameIsTaken }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name e.g. Cut", text: $name)
                    if nameIsTaken {
                        Label("Another tier is already called \"\(trimmedName)\".",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } footer: {
                    // Uniqueness is enforced here rather than with
                    // @Attribute(.unique): that constraint is the one thing
                    // in this schema that would block CloudKit later (see
                    // ExerciseDef.name, which already carries that cost),
                    // and the export keys on this name — two tiers called
                    // "Bulk" would collapse into one on import.
                    Text("Names have to be unique — a tagged cycle and every logged day refer to a tier by name.")
                }

                Section {
                    ForEach(MacroCategory.allCases) { category in
                        HStack {
                            Text(category.label)
                            Text(category.direction.symbol)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(directionLabel(category))
                            Spacer()
                            TextField("0", text: Binding(
                                get: { grams[category] ?? "" },
                                set: { grams[category] = $0 }))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 70)
                                .font(.system(.body, design: .monospaced))
                            Text("g").foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("≥ means hit it or beat it, ≤ means stay under, ≈ means land near it. Which way each one points is fixed — protein is never \"at most\", fiber is never a ceiling.")
                }

                Section {
                    LabeledContent("Calories") {
                        Text("\(Formatters.trim(calories)) cal")
                            .font(.system(.body, design: .monospaced)).bold()
                    }
                    if subsetsExceedCarbs {
                        Label("Sugar + fiber is more than carbs. They're part of carbs, not extra — this tier can't be met as written.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } footer: {
                    // The reason this is a warning and not a block: label
                    // data rounds, and a prompt you hit on a typo is one you
                    // learn to fight.
                    Text("4×protein + 4×carbs + 9×fat. Sugar and fiber are inside the carb number, so they don't add calories of their own.")
                }
            }
            .navigationTitle(tier == nil ? "New Tier" : "Edit Tier")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!canSave)
                }
            }
        }
    }

    private func directionLabel(_ c: MacroCategory) -> String {
        switch c.direction {
        case .atLeast: return "at least"
        case .about:   return "about"
        case .atMost:  return "at most"
        }
    }

    private func save() {
        let newGrams = Dictionary(uniqueKeysWithValues:
            MacroCategory.allCases.map { ($0, value($0)) })
        guard let target = tier else {
            let created = MacroTier(name: trimmedName, order: nextOrder)
            for c in MacroCategory.allCases { created.setGrams(newGrams[c] ?? 0, for: c) }
            context.insert(created)
            try? context.save()
            dismiss()
            return
        }
        // modifiedAt moves only on a real change — re-opening a tier and
        // tapping Save without touching anything is not a revision, and
        // stamping it would make "edited" meaningless.
        if target.differs(name: trimmedName, grams: newGrams) {
            target.modifiedAt = .now
        }
        target.name = trimmedName
        for c in MacroCategory.allCases { target.setGrams(newGrams[c] ?? 0, for: c) }
        try? context.save()
        dismiss()
    }
}
