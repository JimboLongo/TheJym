//
//  StepsView.swift
//  TheJym
//
//  Step counts from HealthKit, grouped by day, week, month or year, each
//  with its daily average. Read-only — see HealthKitService.
//

import SwiftUI

/// Which grouping the list is showing. Raw values drive the segmented
/// picker's labels.
enum StepScale: String, CaseIterable, Identifiable {
    case day = "Day", week = "Week", month = "Month", year = "Year"
    var id: String { rawValue }
}

/// One rendered row: a label, that period's total, and how many days of
/// data it covers.
///
/// `days` is days WITH DATA inside the visible window, not the calendar
/// length of the period, which matters twice over: a month two days in
/// shouldn't read as a collapse, and a bucket the Since date cuts into
/// must not divide by days that were excluded from the window.
struct StepBucket: Identifiable, Hashable {
    let label: String
    let total: Double
    let days: Int
    /// Highest and lowest single day INSIDE this bucket, after the Since
    /// filter. Both are days that actually have data: HealthKit only
    /// returns days with a non-zero count, so a day you left the phone at
    /// home is absent rather than zero, and "worst" therefore means worst
    /// RECORDED day — not "the day you moved least".
    let best: Double
    let worst: Double
    var id: String { label }
    var dailyAverage: Double { days > 0 ? total / Double(days) : 0 }
}

extension StepBucket {
    static let dayFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d, yyyy"; return f
    }()
    static let monthFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f
    }()
    /// Week labels read as a span ("Sep 29 – Oct 5"); a week number would
    /// be shorter but you'd have to translate it to know what it covers.
    static let weekEndpointFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f
    }()

    /// Everything on or after the Since floor. `max(since, earliest)` is
    /// implicit: `days` already starts at the earliest sample on record,
    /// so filtering can only narrow it, never extend it backwards.
    static func visible(_ days: [DayCount], since: Date?,
                        cal: Calendar = .current) -> [DayCount] {
        guard let since else { return days }
        let floor = cal.startOfDay(for: since)
        return days.filter { $0.day >= floor }
    }

    /// Newest first, which is the order you actually read these in.
    ///
    /// Callers pass already-filtered days, which is what makes a partially
    /// included period correct: a bucket the Since date cuts into contains
    /// only its included days and therefore averages over exactly those.
    /// A Since of Thursday yields one short week, still labelled with its
    /// true span ("Sep 29 – Oct 5") so you can see it's a partial week,
    /// but dividing by the 4 days inside the window rather than 7.
    ///
    /// Free function rather than a view computed property so this rule is
    /// testable without standing up a View.
    static func buckets(from days: [DayCount], scale: StepScale,
                        cal: Calendar = .current) -> [StepBucket] {
        func group(by key: (Date) -> Date, label: (Date) -> String) -> [StepBucket] {
            Dictionary(grouping: days) { key($0.day) }
                .sorted { $0.key > $1.key }
                .map { periodStart, inPeriod in
                    let values = inPeriod.map(\.value)
                    return StepBucket(label: label(periodStart),
                                      total: values.reduce(0, +),
                                      days: inPeriod.count,
                                      best: values.max() ?? 0,
                                      worst: values.min() ?? 0)
                }
        }
        switch scale {
        case .day:
            return days.sorted { $0.day > $1.day }
                .map { StepBucket(label: dayFormat.string(from: $0.day),
                                  total: $0.value, days: 1,
                                  best: $0.value, worst: $0.value) }
        case .week:
            // Monday-start, matching Formatters.nearestPastMonday, which
            // is what BodyWeightView/TodayView already snap weigh-ins to.
            // Calendar's own .weekOfYear interval follows the locale's
            // first weekday (Sunday in the US), so using it here would put
            // a Sunday in a different week than the weight screen does.
            return group(by: { Formatters.nearestPastMonday(from: $0) },
                         label: { monday in
                             let sunday = cal.date(byAdding: .day, value: 6, to: monday) ?? monday
                             return "\(weekEndpointFormat.string(from: monday)) – \(weekEndpointFormat.string(from: sunday))"
                         })
        case .month:
            return group(by: { cal.dateInterval(of: .month, for: $0)?.start ?? $0 },
                         label: { monthFormat.string(from: $0) })
        case .year:
            return group(by: { cal.dateInterval(of: .year, for: $0)?.start ?? $0 },
                         label: { "\(cal.component(.year, from: $0))" })
        }
    }
}

struct StepsView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var scale: StepScale = .day
    @State private var daily: [DayCount] = []
    @State private var loaded = false

    /// A lens on the data, not a fact about training — so @AppStorage
    /// rather than an AppSettings field like the Stats page's
    /// trainingStartDate. Narrowing the view of your own step history
    /// changes nothing about what happened, nothing else in the app reads
    /// it, and it shouldn't ride along in the SwiftData store or any
    /// future sync. Stored as a timeInterval because @AppStorage has no
    /// Date overload.
    @AppStorage("stepsSinceDate") private var sinceStamp: Double = 0
    @State private var showSincePicker = false
    @State private var pendingSince = Date()

    private var sinceDate: Date? {
        sinceStamp > 0 ? Date(timeIntervalSince1970: sinceStamp) : nil
    }

    /// Everything on or after the Since floor. `max(since, earliest)` is
    /// implicit: `daily` already starts at the earliest sample, so
    /// filtering can only narrow it, never extend it backwards.
    private var visible: [DayCount] { StepBucket.visible(daily, since: sinceDate) }

    var body: some View {
        List {
            Section {
                Picker("Group by", selection: $scale) {
                    ForEach(StepScale.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                sinceRow
            }

            if !loaded {
                Section { ProgressView().frame(maxWidth: .infinity) }
            } else if visible.isEmpty {
                emptySection
            } else {
                summarySection
                Section(scale.rawValue) {
                    if scale == .day {
                        // Unchanged: a single day's average IS its total,
                        // so a three-column row would be one real number
                        // and one duplicate of it.
                        ForEach(buckets) { labelled($0.label, count($0.total)) }
                    } else {
                        StepPeriodTable(buckets: buckets)
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
        .refreshable { daily = await HealthKitService.shared.dailySteps() }
        .sheet(isPresented: $showSincePicker) {
            NavigationStack {
                DatePicker("Since", selection: $pendingSince, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .padding()
                    .navigationTitle("Show Steps Since")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        if sinceDate != nil {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("All Time") {
                                    sinceStamp = 0
                                    showSincePicker = false
                                }
                            }
                        }
                    }
            }
            .presentationDetents([.medium])
            .onChange(of: pendingSince) { _, newValue in
                sinceStamp = newValue.timeIntervalSince1970
                showSincePicker = false
            }
        }
    }

    // MARK: - Sections

    /// Same idiom as the Stats page's Training Start Date row: a tappable
    /// LabeledContent that opens a graphical DatePicker in a sheet and
    /// dismisses on selection.
    private var sinceRow: some View {
        Button {
            pendingSince = sinceDate ?? daily.first?.day ?? .now
            showSincePicker = true
        } label: {
            LabeledContent("Since") {
                Text(sinceDate.map(Formatters.date.string(from:)) ?? "All time")
            }
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
    }

    private var emptySection: some View {
        // Deliberately NOT an error and NOT a "grant access" prompt:
        // HealthKit makes a denied read indistinguishable from an empty
        // one, so claiming either would be a guess. See
        // HealthKitService.dailySteps.
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(daily.isEmpty ? "No step data" : "No steps in this range").font(.headline)
                Text(daily.isEmpty
                     ? "Steps come from Health. If you've never allowed access, you can turn it on in Settings › Privacy & Security › Health › The Jym."
                     : "Nothing on or after the Since date. Tap it to widen the range.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        }
    }

    /// Kept even though the table now shows per-period averages: this
    /// answers a different question. A row tells you how one week or year
    /// went; this is the figure across the whole Since range, which no
    /// single row carries and which you can't get by eye from a column of
    /// them.
    private var summarySection: some View {
        let total = visible.reduce(0) { $0 + $1.value }
        let avg = visible.isEmpty ? 0 : total / Double(visible.count)
        let best = visible.max { $0.value < $1.value }
        return Section(sinceDate == nil ? "All time" : "Since \(Formatters.date.string(from: sinceDate!))") {
            labelled("Daily average", count(avg))
            labelled("Total steps", count(total))
            labelled("Days tracked", "\(visible.count)")
            if let best {
                labelled("Best day", count(best.value),
                         subtitle: StepBucket.dayFormat.string(from: best.day))
            }
        }
    }

    @ViewBuilder
    private func labelled(_ label: String, _ value: String, subtitle: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if dynamicTypeSize.isAccessibilitySize {
                Text(label).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(value).font(.system(.body, design: .monospaced)).bold()
            } else {
                HStack {
                    Text(label).font(.subheadline).lineLimit(1).minimumScaleFactor(0.7)
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

    private var buckets: [StepBucket] { StepBucket.buckets(from: visible, scale: scale) }

    private func count(_ v: Double) -> String {
        v.rounded().formatted(.number.grouping(.automatic))
    }
}

/// Period | Average | Total, one row per bucket.
///
/// Same Grid/GridRow structure and accessibility fallback as the Stats
/// page's tables — a label column plus value columns at standard sizes,
/// unrolling to one labelled row per cell where a 3-column grid has no
/// room. Deliberately NOT built on YearlyTotalsTable: that one is typed to
/// YearTotal and transposed (periods as COLUMNS), which is the wrong
/// orientation for an unbounded number of weeks.
struct StepPeriodTable: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let buckets: [StepBucket]

    private func value(_ v: Double) -> String {
        v.rounded().formatted(.number.grouping(.automatic))
    }

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            // Label ABOVE value, not LabeledContent's side-by-side. These
            // values run to seven digits, and side-by-side at AX5 squeezed
            // the number column hard enough to wrap mid-figure — "512,1 /
            // 80", "2,771 / ,928" — which is worse than any amount of
            // vertical space. Same stacked treatment the summary rows use.
            ForEach(buckets) { bucket in
                ForEach([("Average", bucket.dailyAverage), ("Total", bucket.total),
                         ("Best day", bucket.best), ("Worst day", bucket.worst)], id: \.0) { pair in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(bucket.label) — \(pair.0)")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(value(pair.1))
                            .font(.system(.body, design: .monospaced)).bold()
                    }
                }
            }
        } else {
            // 8, not the 14 the Stats tables use: five columns of
            // grouped digits is tighter than anything there, and at 375pt
            // the extra 24pt across four gaps is the difference between
            // "Sep 28 – Oct 4" fitting and truncating to "Sep 28 – Oct…".
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("")
                    ForEach(["Average", "Total", "Best", "Worst"], id: \.self) { h in
                        Text(h).font(.caption2.bold()).foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                    }
                }
                ForEach(buckets) { bucket in
                    GridRow {
                        Text(bucket.label).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.6)
                            .gridColumnAlignment(.leading)
                        ForEach([bucket.dailyAverage, bucket.total,
                                 bucket.best, bucket.worst], id: \.self) { v in
                            Text(value(v))
                                .font(.system(.subheadline, design: .monospaced)).bold()
                                .fixedSize()
                        }
                    }
                }
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        }
    }
}
