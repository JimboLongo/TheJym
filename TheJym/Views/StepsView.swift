//
//  StepsView.swift
//  TheJym
//
//  Step counts from HealthKit, grouped by day, month or year, each with its
//  daily average. Read-only — see HealthKitService.
//

import SwiftUI

/// Which grouping the list is showing. Raw values drive the segmented
/// picker's labels.
enum StepScale: String, CaseIterable, Identifiable {
    case day = "Day", month = "Month", year = "Year"
    var id: String { rawValue }
}

/// One rendered row: a label, that period's total, and how many days of
/// data it covers (so the average divides by days WITH data rather than
/// calendar length — a part-way-through month shouldn't read as a slump).
struct StepBucket: Identifiable, Hashable {
    let label: String
    let total: Double
    let days: Int
    var id: String { label }
    var dailyAverage: Double { days > 0 ? total / Double(days) : 0 }
}

struct StepsView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var scale: StepScale = .day
    @State private var daily: [DayCount] = []
    @State private var loaded = false

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d, yyyy"; return f
    }()
    private static let monthFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f
    }()

    var body: some View {
        List {
            Section {
                Picker("Group by", selection: $scale) {
                    ForEach(StepScale.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }

            if !loaded {
                Section { ProgressView().frame(maxWidth: .infinity) }
            } else if daily.isEmpty {
                // Deliberately NOT an error, and deliberately not a
                // "grant access" prompt: HealthKit makes a denied read
                // indistinguishable from an empty one, so claiming either
                // would be a guess. See HealthKitService.dailySteps.
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No step data").font(.headline)
                        Text("Steps come from Health. If you've never allowed access, you can turn it on in Settings › Privacy & Security › Health › The Jym.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }
            } else {
                summarySection
                Section(scale.rawValue) {
                    ForEach(buckets) { bucket in
                        row(bucket)
                    }
                }
            }
        }
        .navigationTitle("Steps")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !loaded else { return }
            await HealthKitService.shared.requestAuthorization()
            daily = await HealthKitService.shared.dailySteps()
            loaded = true
        }
        .refreshable {
            daily = await HealthKitService.shared.dailySteps()
        }
    }

    // MARK: - Sections

    private var summarySection: some View {
        let total = daily.reduce(0) { $0 + $1.value }
        let avg = daily.isEmpty ? 0 : total / Double(daily.count)
        let best = daily.max { $0.value < $1.value }
        return Section("All time") {
            labelled("Daily average", count(avg))
            labelled("Total steps", count(total))
            labelled("Days tracked", "\(daily.count)")
            if let best {
                labelled("Best day", count(best.value),
                         subtitle: Self.dayFormat.string(from: best.day))
            }
        }
    }

    @ViewBuilder
    private func row(_ bucket: StepBucket) -> some View {
        // Day rows have no meaningful "average" of their own — a single
        // day's average IS its total — so they show the count alone.
        if scale == .day {
            labelled(bucket.label, count(bucket.total))
        } else {
            labelled(bucket.label, count(bucket.total),
                     subtitle: "\(count(bucket.dailyAverage))/day · \(bucket.days) days")
        }
    }

    @ViewBuilder
    private func labelled(_ label: String, _ value: String, subtitle: String? = nil) -> some View {
        // Stacked at accessibility sizes, same fallback the Stats page
        // uses — a label and a long number side by side truncate one or
        // the other well before AX5.
        VStack(alignment: .leading, spacing: 2) {
            if dynamicTypeSize.isAccessibilitySize {
                Text(label).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(value).font(.system(.body, design: .monospaced)).bold()
            } else {
                HStack {
                    Text(label).font(.subheadline)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 8)
                    Text(value).font(.system(.subheadline, design: .monospaced)).bold()
                }
            }
            if let subtitle {
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Grouping

    /// Newest first, which is the order you actually read these in.
    private var buckets: [StepBucket] {
        let cal = Calendar.current
        switch scale {
        case .day:
            return daily.sorted { $0.day > $1.day }
                .map { StepBucket(label: Self.dayFormat.string(from: $0.day),
                                  total: $0.value, days: 1) }
        case .month:
            return group(by: { cal.dateInterval(of: .month, for: $0)?.start ?? $0 },
                         label: { Self.monthFormat.string(from: $0) })
        case .year:
            return group(by: { cal.dateInterval(of: .year, for: $0)?.start ?? $0 },
                         label: { "\(cal.component(.year, from: $0))" })
        }
    }

    private func group(by key: (Date) -> Date, label: (Date) -> String) -> [StepBucket] {
        Dictionary(grouping: daily) { key($0.day) }
            .sorted { $0.key > $1.key }
            .map { periodStart, days in
                StepBucket(label: label(periodStart),
                           total: days.reduce(0) { $0 + $1.value },
                           days: days.count)
            }
    }

    private func count(_ v: Double) -> String {
        v.rounded().formatted(.number.grouping(.automatic))
    }
}
