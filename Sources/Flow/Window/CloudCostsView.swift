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

/// Shares Statistics' range rather than maintaining another sidebar page or date filter.
struct CloudCostSection: View {
    var requests: [CloudRequestRecord]
    var rangeLabel: String
    @State private var period = CostPeriod.day
    @State private var selectedBucket: Date?

    private var summary: CloudCostSummary { CloudCostSummary(requests: requests) }
    private var visibleRequests: [CloudRequestRecord] {
        selectedBucket.map { period.requests(requests, at: $0) } ?? requests
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Divider()
            Text("Cloud costs · \(rangeLabel)").font(.title2.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 32, verticalSpacing: 14) {
                GridRow {
                    metric("Estimated spend", RequestDisplay.money(summary.knownCost))
                    metric("LLM calls", String(summary.calls))
                }
                GridRow {
                    metric("Input tokens", String(summary.inputTokens))
                    metric("Output tokens", String(summary.outputTokens))
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if summary.unpricedCalls > 0 {
                Text("\(summary.unpricedCalls) calls have unknown cost and are excluded from the spend total.")
                    .font(.callout).foregroundStyle(.orange)
            }
            Text("USD estimates use provider-reported usage and saved pricing snapshots. Prices come from models.dev, with verified provider rates for missing entries. Output includes billed reasoning. Retries and parallel calls count separately. Recording time is excluded from request latency.")
                .font(.caption).foregroundStyle(.secondary)
            Link("Pricing source · models.dev", destination: URL(string: "https://models.dev/")!)
                .font(.caption)
            if requests.isEmpty {
                Text("No cloud calls in this statistics range. Older calls did not save usage.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(providerGroups, id: \.id) { group in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(group.name).font(.headline)
                        Text(costSummary(group.requests)).font(.caption).foregroundStyle(.secondary)
                        ForEach(modelGroups(group.requests), id: \.model) { model in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.model).font(.caption.weight(.medium))
                                Text(costSummary(model.requests)).font(.caption2)
                                Text(timingSummary(model.requests)).font(.caption2).foregroundStyle(.secondary)
                            }.padding(.leading, 12)
                        }
                    }
                }
                Divider()
                Picker("Cost breakdown", selection: $period) {
                    ForEach(CostPeriod.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(maxWidth: 220)
                Text(period == .day ? "Daily spend" : "Monthly spend").font(.headline)
                Text("Select a day or month to inspect its requests. Totals above cover the statistics range.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(buckets, id: \.date) { bucket in
                    Button { selectedBucket = selectedBucket == bucket.date ? nil : bucket.date } label: {
                        HStack {
                            Text(period == .day ? bucket.date.formatted(.dateTime.month().day().year())
                                 : bucket.date.formatted(.dateTime.month(.wide).year()))
                            Spacer()
                            Text(costSummary(bucket.requests)).monospacedDigit()
                            if selectedBucket == bucket.date { Image(systemName: "checkmark") }
                        }.font(.caption).contentShape(.rect)
                    }.buttonStyle(.borderless)
                    .accessibilityLabel("Inspect costs for " + bucket.date.formatted(date: .abbreviated, time: .omitted))
                }
                Divider()
                HStack {
                    Text(selectedBucket == nil ? "Every request" : "Requests in selected period").font(.headline)
                    Spacer()
                    if selectedBucket != nil {
                        Button("Show all requests") { selectedBucket = nil }.font(.caption)
                    }
                }
                ForEach(visibleRequests.sorted { $0.startedAt > $1.startedAt }) { request in
                    CloudRequestDetail(request: request)
                    Divider()
                }
            }
        }
        .onChange(of: period) { selectedBucket = nil }
        .onChange(of: rangeLabel) { selectedBucket = nil }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.medium)).monospacedDigit()
        }
    }
    private var providerGroups: [(id: UUID, name: String, requests: [CloudRequestRecord])] {
        Dictionary(grouping: requests, by: \.providerID).map { id, calls in
            (id, calls.first?.providerName ?? "Provider", calls)
        }.sorted { $0.name < $1.name }
    }
    private func modelGroups(_ calls: [CloudRequestRecord]) -> [(model: String, requests: [CloudRequestRecord])] {
        Dictionary(grouping: calls, by: \.modelID).map { (model: $0.key, requests: $0.value) }
            .sorted { $0.model < $1.model }
    }
    private var buckets: [(date: Date, requests: [CloudRequestRecord])] {
        Dictionary(grouping: requests) { Calendar.current.dateInterval(of: period.component, for: $0.startedAt)?.start
            ?? Calendar.current.startOfDay(for: $0.startedAt) }
            .map { (date: $0.key, requests: $0.value) }.sorted { $0.date > $1.date }
    }
    private func timingSummary(_ calls: [CloudRequestRecord]) -> String {
        func average(_ values: [Double]) -> String {
            RequestDisplay.seconds(values.isEmpty ? nil : values.reduce(0, +) / Double(values.count))
        }
        let finished = calls.filter { $0.status == .succeeded }
        let elapsed = finished.compactMap(\.elapsed)
        let first = finished.compactMap(\.firstTokenLatency)
        let speeds = finished.compactMap(\.tokensPerSecond)
        let speed = speeds.isEmpty ? nil : speeds.reduce(0, +) / Double(speeds.count)
        return "Successful calls: avg resolved \(average(elapsed)) · avg first token \(average(first)) across \(first.count) measured calls · avg generation \(RequestDisplay.speed(speed)) across \(speeds.count) measured calls"
    }
}

private func costSummary(_ requests: [CloudRequestRecord]) -> String {
    let summary = CloudCostSummary(requests: requests)
    return "\(summary.calls) calls · \(RequestDisplay.money(summary.knownCost))"
        + (summary.unpricedCalls > 0 ? " · \(summary.unpricedCalls) unknown" : "")
}

/// An explicit button also opens reliably inside selectable history rows.
struct CloudRequestList: View {
    var requests: [CloudRequestRecord]
    var title: String
    @State private var expanded = false

    var body: some View {
        if !requests.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Button { expanded.toggle() } label: {
                    Label("\(title) · \(costSummary(requests))", systemImage: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel((expanded ? "Hide " : "Show ") + title.lowercased())
                if expanded {
                    ForEach(requests) { CloudRequestDetail(request: $0) }
                }
            }
        }
    }
}

struct CloudRequestDetail: View {
    var request: CloudRequestRecord
    @State private var expanded = false
    private var headline: String {
        "\(request.providerName) · \(request.modelID) · \(request.stageLabel)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    Text(headline).lineLimit(2)
                    Spacer(minLength: 6)
                    Text(RequestDisplay.money(request.estimatedCost)).monospacedDigit()
                }.font(.caption.weight(.medium))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel((expanded ? "Hide request details · " : "Show request details · ") + headline)
            Text("\(request.startedAt.formatted(date: .omitted, time: .standard)) · \(request.status.rawValue) · \(RequestDisplay.seconds(request.elapsed)) · first token \(RequestDisplay.seconds(request.firstTokenLatency)) · \(RequestDisplay.speed(request.tokensPerSecond))")
                .font(.caption2).foregroundStyle(.secondary)
            if expanded {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                    row("Version", request.configLabel)
                    row("Input tokens", RequestDisplay.tokens(request.usage.input))
                    row("Output tokens, including reasoning", RequestDisplay.tokens(request.usage.output))
                    row("Reasoning tokens", request.usage.unseparatedThinking ? "Included in output, not separated" : String(request.usage.reasoning))
                    row("Cached input / cache writes", "\(request.usage.cachedInput) / \(request.usage.cacheWrite)")
                    row("Audio input / output tokens", "\(request.usage.audioInput) / \(request.usage.audioOutput)")
                    row("Input price per million tokens", RequestDisplay.money(request.price?.input))
                    row("Output price per million tokens", RequestDisplay.money(request.price?.output))
                    if request.usage.cachedInput > 0 { row("Cached input price per million", RequestDisplay.money(request.price?.cacheRead)) }
                    if request.usage.cacheWrite > 0 { row("Cache-write price per million", RequestDisplay.money(request.price?.cacheWrite)) }
                    if request.usage.audioInput > 0 { row("Audio input price per million", RequestDisplay.money(request.price?.inputAudio)) }
                    if request.usage.audioOutput > 0 { row("Audio output price per million", RequestDisplay.money(request.price?.outputAudio)) }
                    row("Input cost", RequestDisplay.money(request.inputCost))
                    row("Output cost", RequestDisplay.money(request.outputCost))
                    row("Request resolved", RequestDisplay.seconds(request.elapsed))
                    row("First visible token", RequestDisplay.seconds(request.firstTokenLatency))
                    row("Generation tokens per second", RequestDisplay.speed(request.tokensPerSecond))
                    row("Output tokens / whole request", RequestDisplay.speed(request.effectiveTokensPerSecond))
                    if let code = request.httpStatus { row("HTTP status", String(code)) }
                    if let error = request.error { row("Failure", error) }
                    if let price = request.price {
                        row("Pricing snapshot", "\(price.provider)/\(price.model) · \(price.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                        if let source = URL(string: price.sourceURL ?? "https://models.dev/") {
                            Link(price.sourceURL == nil ? "Price source · models.dev" : "Price source · provider documentation", destination: source)
                        }
                    }
                }
                .font(.caption2).textSelection(.enabled)
                Text("First-token latency measures the first visible streamed output. Generation speed excludes the initial wait and reasoning tokens. Non-streamed or one-chunk replies cannot report generation speed. Unknown usage or pricing stays unknown.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }
}
