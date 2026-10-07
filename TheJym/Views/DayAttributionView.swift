//
//  DayAttributionView.swift
//  TheJym
//
//  Review-and-confirm for DayAttributionEngine. Nothing is written until
//  Apply, every row can be unticked, and the cycle projection updates as
//  you untick so the consequence is visible before the decision.
//

import SwiftUI
import SwiftData

struct DayAttributionView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Phase.number) private var phases: [Phase]
    @Query(sort: \WorkoutSession.date) private var allSessions: [WorkoutSession]

    let phase: Phase

    @State private var proposals: [DayAttributionEngine.Proposal] = []
    @State private var excluded: Set<PersistentIdentifier> = []
    @State private var undo: DayAttributionEngine.Snapshot?
    @State private var applied = false

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f
    }()

    private var selected: [DayAttributionEngine.Proposal] {
        proposals.filter { !excluded.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                if applied {
                    // The projection is only meaningful BEFORE applying.
                    // project() walks phase.sessions PLUS the proposals,
                    // and once applied those are the same sessions — so
                    // leaving it on screen double-counted them and the
                    // number climbed on its own (41 -> 45) with nothing
                    // touched. Reloading clears the stale proposals; this
                    // guard makes the stale state unreachable even so.
                    Section {
                        Label("Applied", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Relaunch to assign cycle numbers, then check the cycle count on the Phases screen.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if proposals.isEmpty {
                    Section {
                        Text("Nothing to attribute — every session in Phase \(phase.number)'s date range already has a day.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    projectionSection
                    proposalSection
                }
                if applied {
                    Section {
                        Button("Undo", role: .destructive) {
                            if let undo { DayAttributionEngine.revert(undo, context: context) }
                            self.undo = nil
                            applied = false
                            reload()
                        }
                    } footer: {
                        Text("Undo is available until you leave this screen or relaunch. Cycle numbers are assigned on next launch, so check the count first, then relaunch.")
                    }
                }
            }
            .navigationTitle("Attribute Days")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .onAppear(perform: reload)
        }
    }

    private var projectionSection: some View {
        let p = DayAttributionEngine.project(phase: phase, applying: selected)
        return Section {
            LabeledContent("Sessions selected", value: "\(selected.count) of \(proposals.count)")
            LabeledContent("Slots filled",
                           value: "\(p.filledBefore) → \(p.filledAfter) of \(p.totalSlots)")
            LabeledContent("Cycle", value: "\(p.cycleBefore) → \(p.cycleAfter) of \(phase.totalCycles)")
        } header: {
            Text("Phase \(phase.number)")
        } footer: {
            Text("A cycle completes only when every slot in the split is filled, rest days included. Projected by replaying the same slot-filling walk the phase itself uses.")
        }
    }

    private var proposalSection: some View {
        Section {
            ForEach(proposals) { proposal in
                Button {
                    if excluded.contains(proposal.id) { excluded.remove(proposal.id) }
                    else { excluded.insert(proposal.id) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: excluded.contains(proposal.id)
                              ? "circle" : "checkmark.circle.fill")
                            .foregroundStyle(excluded.contains(proposal.id) ? Color.secondary : Color.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.dayFormat.string(from: proposal.session.date))
                                .font(.subheadline)
                            Text(proposal.day.name)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(proposal.strengthText)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(proposal.isCertain ? Color.green
                                             : proposal.isWeak ? Color.orange : Color.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            if !applied {
                Button("Apply to \(selected.count) sessions") {
                    undo = DayAttributionEngine.apply(selected, to: phase, context: context)
                    applied = true
                    // Drop the now-stale proposals. Without this they stay
                    // live alongside the sessions they just wrote, and any
                    // re-render projects both populations.
                    proposals = []
                    excluded = []
                }
                .disabled(selected.isEmpty)
            }
        } header: {
            Text("Proposed")
        } footer: {
            Text("A rest-day session shows \"rest day\" — that's a fact, not a similarity score: a logged rest-day activity belongs on a Rest slot. Training sessions show how many of the day's planned exercises they logged; a partial match is amber.")
        }
    }

    private func reload() {
        let candidates = DayAttributionEngine.withAllSessions(allSessions) {
            DayAttributionEngine.candidates(for: phase, in: phases)
        }
        proposals = DayAttributionEngine.propose(for: phase, sessions: candidates)
        excluded = []
    }
}
