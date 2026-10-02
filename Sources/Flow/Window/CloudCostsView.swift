import Charts
import SwiftUI

enum CostPeriod: String, CaseIterable, Identifiable {
    case day = "Daily", month = "Monthly"
    var id: String { rawValue }
    var component: Calendar.Component { self == .day ? .day : .month }

    func requests(_ all: [CloudRequestRecord], at date: Date, calendar: Calendar = .current) -> [CloudRequestRecord] {
        guard let interval = calendar.dateInterval(of: component, for: date) else { return [] }
        return all.filter { $0.isInference && $0.startedAt >= interval.start && $0.startedAt < interval.end }
    }
}

/// Cloud spend and performance for the Statistics range: headline numbers, spend
/// over time by model, a per-model table, and every request.
///
/// Shares Statistics' range rather than keeping its own date filter, so every number
/// on the page covers the same window.
struct CloudCostSection: View {
    /// Inference requests inside the range.
    var requests: [CloudRequestRecord]
    /// Every request ever, so a model keeps its colour when the range changes.
    var allRequests: [CloudRequestRecord]
    var range: StatsRange

    @State private var metric: Metric = .spend
    @State private var hovered: Date?
    @State private var pinnedBucket: Date?
    @State private var modelSort = [KeyPathComparator(\ModelRow.spend, order: .reverse)]
    @State private var requestSort = [KeyPathComparator(\CloudRequestRecord.startedAt, order: .reverse)]
    @State private var selectedRequest: CloudRequestRecord.ID?
    @State private var chartWidth: CGFloat = 600
    @Environment(\.colorScheme) private var scheme

    enum Metric: String, CaseIterable, Identifiable {
        case spend = "Spend", calls = "Requests"
        var id: String { rawValue }
    }

    private var summary: CloudCostSummary { CloudCostSummary(requests: requests) }
    private var component: Calendar.Component { range.bucket }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Cloud").font(.title2.weight(.semibold))
                Text(range.label).font(.title3).foregroundStyle(.secondary)
                Spacer()
                if summary.unpricedCalls > 0 {
                    Chip("\(summary.unpricedCalls) unknown cost", systemImage: "questionmark.circle", tint: .orange)
                        .help("\(Fmt.count(summary.unpricedCalls, "request")) had no usage or price on record. They are left out of the spend total rather than guessed.")
                }
                InfoButton(text: Self.pricingNote, link: ("Prices from models.dev", URL(string: "https://models.dev/")!))
            }
            kpis
            trendCard
            modelCard
            requestCard
        }
        .onChange(of: range) {
            pinnedBucket = nil
            selectedRequest = nil
        }
    }

    static let pricingNote = "USD estimates use provider-reported usage and the price saved with each request. Prices come from models.dev, with verified provider rates for missing entries. Output includes billed reasoning. Retries and parallel calls count separately. Request latency excludes recording time."

    // MARK: Headline numbers

    private var previous: [CloudRequestRecord]? {
        guard let window = range.previousWindow() else { return nil }
        return allRequests.filter { $0.isInference && $0.startedAt >= window.start && $0.startedAt < window.end }
    }

    private var kpis: some View {
        let finished = requests.filter { $0.status != .running }
        let succeeded = finished.filter { $0.status == .succeeded }
        let latencies = succeeded.compactMap(\.elapsed)
        let before = previous.map { CloudCostSummary(requests: $0) }
        let previousLatency = previous.flatMap { calls in
            median(calls.filter { $0.status == .succeeded }.compactMap(\.elapsed))
        }
        let latency = median(latencies)
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            StatCard(title: "Estimated spend", value: Fmt.money(summary.knownCost),
                     delta: change(summary.knownCost, before?.knownCost), higherIsBetter: false,
                     help: "Known cost of every cloud request in this range. Requests without usage or a price are left out.")
            StatCard(title: "Requests", value: summary.calls.formatted(),
                     delta: change(Double(summary.calls), before.map { Double($0.calls) }), higherIsBetter: false,
                     help: "Every inference request, including retries, failures, and parallel configs.")
            StatCard(title: "Success rate",
                     value: finished.isEmpty ? "n/a" : Fmt.percent(Double(succeeded.count) / Double(finished.count)),
                     help: "Share of finished requests that returned a result.")
            StatCard(title: "Median latency", value: Fmt.duration(latency),
                     delta: latency.flatMap { now in previousLatency.map { (now - $0) / $0 } }, higherIsBetter: false,
                     help: "Median time from sending a successful request to its last byte. Recording time is not included.")
        }
    }

    private func change(_ now: Double, _ before: Double?) -> Double? {
        guard let before, before > 0 else { return nil }
        return (now - before) / before
    }

    private func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    // MARK: Series identity

    /// Models in order of first use, so colours follow the model, never its rank.
    private var seriesOrder: [String] {
        var seen: [String] = []
        for request in allRequests.filter(\.isInference).sorted(by: { $0.startedAt < $1.startedAt }) {
            let key = Self.seriesKey(request)
            if !seen.contains(key) { seen.append(key) }
        }
        return seen
    }

    static func seriesKey(_ request: CloudRequestRecord) -> String { request.modelID }

    /// Slots run out before models do; the rest share one neutral "Other".
    private var colorSlots: Int { VizPalette.seriesCount - 1 }

    private func seriesName(_ key: String) -> String {
        let index = seriesOrder.firstIndex(of: key) ?? .max
        return index < colorSlots ? key : "Other"
    }

    private func color(for key: String) -> Color {
        guard let index = seriesOrder.firstIndex(of: key), index < colorSlots else { return VizPalette.other }
        return VizPalette.series(index, scheme: scheme)
    }

    // MARK: Over time

    private struct Bar: Identifiable {
        var bucket: Date
        var series: String
        var spend: Double
        var calls: Int
        var id: String { "\(bucket.timeIntervalSince1970)-\(series)" }
    }

    private var bars: [Bar] {
        let calendar = Calendar.current
        var totals: [String: Bar] = [:]
        for request in requests {
            guard let bucket = calendar.dateInterval(of: component, for: request.startedAt)?.start else { continue }
            let series = seriesName(Self.seriesKey(request))
            let id = "\(bucket.timeIntervalSince1970)-\(series)"
            totals[id, default: Bar(bucket: bucket, series: series, spend: 0, calls: 0)].spend += request.estimatedCost ?? 0
            totals[id]?.calls += 1
        }
        return totals.values.sorted { $0.bucket < $1.bucket }
    }

    private var domain: ClosedRange<Date> {
        let calendar = Calendar.current
        let start = range.cutoff ?? requests.map(\.startedAt).min() ?? .now
        let first = calendar.dateInterval(of: component, for: start)?.start ?? start
        let last = calendar.dateInterval(of: component, for: .now)?.end ?? .now
        return first...last
    }

    private var legend: [String] {
        let present = Set(bars.map(\.series))
        var names = seriesOrder.prefix(colorSlots).filter(present.contains)
        if present.contains("Other") { names.append("Other") }
        return names
    }

    private func bucket(containing date: Date?) -> Date? {
        guard let date else { return nil }
        return Calendar.current.dateInterval(of: component, for: date)?.start
    }

    private var barWidth: CGFloat {
        let count = max(1, Calendar.current.dateComponents([component], from: domain.lowerBound, to: domain.upperBound)
            .value(for: component) ?? 1)
        return max(2, min(24, chartWidth / CGFloat(count) * 0.7))
    }

    private var trendCard: some View {
        let hoveredBucket = bucket(containing: hovered)
        let names = legend
        return SectionCard(title: metric == .spend ? "Spend over time" : "Requests over time",
                           subtitle: pinnedBucket.map { "Showing requests from \(bucketLabel($0)). Click the bar again to clear." }
                               ?? "Hover a bar for the breakdown. Click one to filter the requests below.") {
            Picker("Measure", selection: $metric) {
                ForEach(Metric.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        } content: {
            Chart {
                ForEach(bars) { bar in
                    BarMark(x: .value("Date", bar.bucket, unit: component),
                            y: .value(metric.rawValue, metric == .spend ? bar.spend : Double(bar.calls)),
                            width: .fixed(barWidth))
                        .foregroundStyle(by: .value("Model", bar.series))
                        .cornerRadius(2)
                        .opacity(pinnedBucket == nil || pinnedBucket == bar.bucket ? 1 : 0.3)
                }
                if let hoveredBucket {
                    RuleMark(x: .value("Date", hoveredBucket, unit: component))
                        .foregroundStyle(.secondary.opacity(0.25))
                        .lineStyle(StrokeStyle(lineWidth: max(barWidth + 6, 8)))
                        .zIndex(-1)
                        .annotation(position: .top, spacing: 4,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                            tooltip(for: hoveredBucket)
                        }
                }
            }
            .chartForegroundStyleScale(domain: names, range: names.map { color(for: $0) })
            .chartXScale(domain: domain)
            .chartXSelection(value: $hovered)
            .chartLegend(names.count > 1 ? .visible : .hidden)
            .chartLegend(position: .bottom, alignment: .leading, spacing: 10)
            .quietXAxis()
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(ChartInk.grid)
                    AxisValueLabel {
                        if let amount = value.as(Double.self) {
                            Text(metric == .spend ? Fmt.money(amount) : Int(amount).formatted())
                        }
                    }
                    .foregroundStyle(ChartInk.label)
                }
            }
            .frame(height: 200)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { chartWidth = $0 - 50 }
            .onTapGesture {
                guard let hoveredBucket else { return }
                pinnedBucket = pinnedBucket == hoveredBucket ? nil : hoveredBucket
                selectedRequest = nil
            }
            .overlay {
                if requests.isEmpty {
                    Text("No cloud requests in this range.").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func bucketLabel(_ date: Date) -> String {
        switch component {
        case .hour: date.formatted(.dateTime.hour())
        case .weekOfYear: "the week of " + date.formatted(.dateTime.month(.abbreviated).day())
        case .month: date.formatted(.dateTime.month(.wide).year())
        default: date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }
    }

    private func tooltip(for bucket: Date) -> some View {
        let inBucket = bars.filter { $0.bucket == bucket }
        let total = metric == .spend
            ? Fmt.money(inBucket.reduce(0) { $0 + $1.spend })
            : inBucket.reduce(0) { $0 + $1.calls }.formatted()
        var rows = inBucket
            .sorted { metric == .spend ? $0.spend > $1.spend : $0.calls > $1.calls }
            .map { ChartTooltip.Row(color: color(for: $0.series), label: $0.series,
                                    value: metric == .spend ? Fmt.money($0.spend) : $0.calls.formatted()) }
        if rows.count > 1 { rows.insert(ChartTooltip.Row(label: "total", value: total), at: 0) }
        if rows.isEmpty { rows = [ChartTooltip.Row(label: "", value: "No requests")] }
        return ChartTooltip(title: bucketLabel(bucket).capitalizedFirst, rows: rows,
                            hint: inBucket.isEmpty ? nil : (pinnedBucket == bucket ? "Click to clear the filter" : "Click to filter requests"))
    }

    // MARK: By model

    struct ModelRow: Identifiable {
        var id: String
        var provider: String
        var model: String
        var calls: Int
        var failures: Int
        var spend: Double
        var unknown: Int
        var latency: Double
        var firstToken: Double
        var speed: Double
    }

    private var modelRows: [ModelRow] {
        Dictionary(grouping: requests) { "\($0.providerID.uuidString)|\($0.modelID)" }.map { id, calls in
            let summary = CloudCostSummary(requests: calls)
            let succeeded = calls.filter { $0.status == .succeeded }
            let speeds = succeeded.compactMap(\.tokensPerSecond)
            return ModelRow(
                id: id,
                provider: calls.first?.providerName ?? "Provider",
                model: calls.first?.modelID ?? "",
                calls: summary.calls,
                failures: calls.filter { $0.status == .failed || $0.status == .interrupted }.count,
                spend: summary.knownCost,
                unknown: summary.unpricedCalls,
                latency: median(succeeded.compactMap(\.elapsed)) ?? .infinity,
                firstToken: median(succeeded.compactMap(\.firstTokenLatency)) ?? .infinity,
                speed: speeds.isEmpty ? 0 : speeds.reduce(0, +) / Double(speeds.count)
            )
        }
        .sorted(using: modelSort)
    }

    private var modelCard: some View {
        let rows = modelRows
        return SectionCard(title: "By model", subtitle: "Click a column to sort. Latency columns are medians over successful requests.") {
            Table(rows, sortOrder: $modelSort) {
                TableColumn("Model", value: \.model) { row in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(color(for: row.model)).frame(width: 8, height: 8)
                        Text(row.model).lineLimit(1)
                        Text(row.provider).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .help("\(row.model) on \(row.provider)")
                }
                .width(min: 160, ideal: 220)
                TableColumn("Requests", value: \.calls) { row in
                    Text(row.calls.formatted()).monospacedDigit()
                }
                .width(min: 60, ideal: 70)
                TableColumn("Failed", value: \.failures) { row in
                    Text(row.failures.formatted()).monospacedDigit()
                        .foregroundStyle(row.failures > 0 ? AnyShapeStyle(VizPalette.critical) : AnyShapeStyle(.secondary))
                }
                .width(min: 50, ideal: 56)
                TableColumn("Spend", value: \.spend) { row in
                    Text(row.unknown == row.calls ? "Unknown" : Fmt.money(row.spend, column: true) + (row.unknown > 0 ? " +?" : ""))
                        .monospacedDigit()
                        .foregroundStyle(row.unknown == row.calls ? .secondary : .primary)
                        .help(row.unknown > 0 ? "\(Fmt.count(row.unknown, "request")) with unknown cost not included" : "Known cost")
                }
                .width(min: 70, ideal: 80)
                TableColumn("Latency", value: \.latency) { row in
                    Text(Fmt.duration(row.latency.isFinite ? row.latency : nil)).monospacedDigit()
                }
                .width(min: 60, ideal: 70)
                TableColumn("First token", value: \.firstToken) { row in
                    Text(Fmt.duration(row.firstToken.isFinite ? row.firstToken : nil)).monospacedDigit()
                        .help("Time until the first visible streamed text")
                }
                .width(min: 70, ideal: 80)
                TableColumn("Speed", value: \.speed) { row in
                    Text(row.speed > 0 ? "\(Stats.compactCount(Int(row.speed.rounded()))) tok/s" : "n/a").monospacedDigit()
                        .help("Average generation speed after the first token, where the stream reported it")
                }
                .width(min: 60, ideal: 76)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .scrollContentBackground(.hidden)
            .frame(height: CGFloat(max(rows.count, 1)) * 26 + 34)
        }
    }

    // MARK: Requests

    private var visibleRequests: [CloudRequestRecord] {
        let filtered = pinnedBucket.map { bucket in requests.filter { self.bucket(containing: $0.startedAt) == bucket } }
            ?? requests
        return filtered.sorted(using: requestSort)
    }

    private var requestCard: some View {
        let rows = visibleRequests
        let selected = selectedRequest.flatMap { id in requests.first { $0.id == id } }
        return SectionCard(title: pinnedBucket == nil ? "Requests" : "Requests in \(bucketLabel(pinnedBucket!))",
                           subtitle: "\(Fmt.count(rows.count, "request")). Select one for tokens, prices, and timing.") {
            if pinnedBucket != nil {
                Button("Show all") { pinnedBucket = nil }
                    .controlSize(.small)
            }
        } content: {
            Table(rows, selection: $selectedRequest, sortOrder: $requestSort) {
                TableColumn("Time", value: \.startedAt) { request in
                    Text(component == .hour
                         ? request.startedAt.formatted(date: .omitted, time: .standard)
                         : request.startedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                        .monospacedDigit()
                }
                .width(min: 90, ideal: 120)
                TableColumn("Model", value: \.modelID) { request in
                    Text(request.modelID).lineLimit(1).help("\(request.modelID) on \(request.providerName)")
                }
                .width(min: 120, ideal: 170)
                TableColumn("Stage", value: \.stageLabel) { request in
                    Text(request.stageLabel).foregroundStyle(.secondary)
                }
                .width(min: 80, ideal: 110)
                TableColumn("Status", value: \.status.rawValue) { request in
                    RequestStatusLabel(status: request.status)
                }
                .width(min: 80, ideal: 96)
                TableColumn("Latency", value: \.elapsedSortKey) { request in
                    Text(Fmt.duration(request.elapsed)).monospacedDigit()
                }
                .width(min: 56, ideal: 64)
                TableColumn("Cost", value: \.costSortKey) { request in
                    Text(Fmt.money(request.estimatedCost, column: true)).monospacedDigit()
                        .foregroundStyle(request.estimatedCost == nil ? .secondary : .primary)
                }
                .width(min: 60, ideal: 72)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .scrollContentBackground(.hidden)
            .frame(height: min(320, CGFloat(max(rows.count, 1)) * 26 + 34))

            if let selected {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("\(selected.providerName) · \(selected.modelID) · \(selected.stageLabel)")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Button { selectedRequest = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Close request details")
                    }
                    CloudRequestFacts(request: selected)
                }
                .padding(12)
                .background(.background.opacity(0.6), in: .rect(cornerRadius: 10))
                .transition(.opacity)
            }
        }
    }
}

private extension CloudRequestRecord {
    /// Unknown sorts last in either direction's natural reading: slowest and priciest.
    var elapsedSortKey: Double { elapsed ?? .infinity }
    var costSortKey: Double { estimatedCost ?? -1 }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - Request pieces

/// A status with an icon, so colour never carries it alone.
struct RequestStatusLabel: View {
    var status: CloudRequestRecord.Status
    var showsText = true
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(color)
            if showsText { Text(title) }
        }
        .help(title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }

    private var title: String {
        switch status {
        case .running: "Running"
        case .succeeded: "Succeeded"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .interrupted: "Interrupted"
        }
    }

    private var icon: String {
        switch status {
        case .running: "circle.dotted"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "minus.circle.fill"
        case .interrupted: "exclamationmark.circle.fill"
        }
    }

    private var color: Color {
        switch status {
        case .succeeded: VizPalette.good(scheme)
        case .failed: VizPalette.critical
        case .interrupted: VizPalette.warning
        case .running, .cancelled: .secondary
        }
    }
}

/// One request as a compact row that opens into its full accounting.
struct RequestDisclosure: View {
    var request: CloudRequestRecord
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    RequestStatusLabel(status: request.status, showsText: false)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(request.modelID).font(.callout.weight(.medium)).lineLimit(1)
                        Text("\(request.providerName) · \(request.stageLabel)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(Fmt.money(request.estimatedCost)).font(.callout)
                        Text(Fmt.duration(request.elapsed)).font(.caption).foregroundStyle(.secondary)
                    }
                    .monospacedDigit()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide request details" : "Show tokens, prices, and timing for this request")
            .accessibilityLabel("\(request.modelID), \(request.stageLabel)")
            if expanded {
                CloudRequestFacts(request: request)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 8))
    }
}

/// The full accounting for one request, grouped the way you would check a bill:
/// what went in and out, what it cost, and how long it took.
struct CloudRequestFacts: View {
    var request: CloudRequestRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                group("Tokens")
                row("Input", RequestDisplay.tokens(request.usage.input))
                row("Output, with reasoning", RequestDisplay.tokens(request.usage.output))
                row("Reasoning", request.usage.unseparatedThinking ? "Included in output" : String(request.usage.reasoning))
                if request.usage.cachedInput > 0 || request.usage.cacheWrite > 0 {
                    row("Cache read / write", "\(request.usage.cachedInput) / \(request.usage.cacheWrite)")
                }
                if request.usage.audioInput > 0 || request.usage.audioOutput > 0 {
                    row("Audio in / out", "\(request.usage.audioInput) / \(request.usage.audioOutput)")
                }

                group("Cost")
                row("Input", RequestDisplay.money(request.inputCost))
                row("Output", RequestDisplay.money(request.outputCost))
                row("Price in / out per 1M", "\(Fmt.money(request.price?.input)) / \(Fmt.money(request.price?.output))")
                if request.usage.cachedInput > 0 { row("Cached input per 1M", Fmt.money(request.price?.cacheRead)) }
                if request.usage.cacheWrite > 0 { row("Cache write per 1M", Fmt.money(request.price?.cacheWrite)) }
                if request.usage.audioInput > 0 { row("Audio input per 1M", Fmt.money(request.price?.inputAudio)) }
                if request.usage.audioOutput > 0 { row("Audio output per 1M", Fmt.money(request.price?.outputAudio)) }

                group("Timing")
                row("Started", request.startedAt.formatted(date: .abbreviated, time: .standard))
                row("Resolved in", RequestDisplay.seconds(request.elapsed))
                row("First visible token", RequestDisplay.seconds(request.firstTokenLatency))
                row("Generation speed", RequestDisplay.speed(request.tokensPerSecond))
                row("Output over whole request", RequestDisplay.speed(request.effectiveTokensPerSecond))

                group("Request")
                row("Version", request.configLabel)
                if let code = request.httpStatus { row("HTTP status", String(code)) }
                if let error = request.error { row("Failure", error) }
                if let price = request.price {
                    row("Pricing snapshot", "\(price.provider)/\(price.model) · \(price.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                }
            }
            .font(.caption)
            .textSelection(.enabled)
            if let price = request.price, let source = URL(string: price.sourceURL ?? "https://models.dev/") {
                Link(price.sourceURL == nil ? "Price source: models.dev" : "Price source: provider documentation",
                     destination: source)
                    .font(.caption)
            }
            Text("First-token latency measures the first visible streamed output. Generation speed excludes the initial wait and reasoning tokens. Non-streamed or one-chunk replies cannot report it.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func group(_ title: String) -> some View {
        GridRow {
            Text(title).font(.caption.weight(.semibold)).padding(.top, 4)
                .gridCellColumns(2)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }
}
