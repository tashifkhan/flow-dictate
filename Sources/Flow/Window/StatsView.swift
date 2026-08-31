import SwiftUI

/// Statistics: three headline numbers, or a year of activity.
struct StatsView: View {
    @Bindable var env: AppEnvironment
    @State private var range: StatsRange = .allTime
    @State private var mode: Mode = .overview

    enum Mode: String, CaseIterable { case overview, activity }

    private var stats: Stats {
        Stats.compute(from: env.library.dailyStats, range: range)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                controls
                if mode == .overview {
                    tiles
                    breakdown
                } else {
                    ContributionGraph(stats: stats)
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .navigationTitle("Statistics")
    }

    private var controls: some View {
        HStack {
            Picker("Statistics", selection: $range) {
                ForEach(StatsRange.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(mode == .activity)

            Spacer()

            Picker("View", selection: $mode) {
                Text("Overview").tag(Mode.overview)
                Text("Activity").tag(Mode.activity)
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
    }

    // MARK: - Overview

    private var tiles: some View {
        let saved = Stats.humanDuration(stats.timeSaved)
        return HStack(spacing: 0) {
            tile("WPM", value: "\(stats.wordsPerMinute)", unit: "")
            divider
            tile("Time Saved", value: saved.value, unit: saved.unit)
            divider
            tile("Total Words", value: Stats.compactCount(stats.totalWords), unit: "")
        }
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 12))
    }

    /// A hero number wears text tokens, not a series colour — nothing here encodes a
    /// category, so nothing here is coloured.
    private func tile(_ label: String, value: String, unit: String) -> some View {
        VStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 40, weight: .light))
                    .monospacedDigit()
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var divider: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(width: 1, height: 44)
    }

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(range.label).font(.headline)
            row("Dictations", "\(stats.dictationCount)")
            row("Time speaking", Stats.humanDuration(stats.totalDuration).value
                + Stats.humanDuration(stats.totalDuration).unit)
            row("Words", "\(stats.totalWords)")
            Text("Time saved compares speaking against typing at \(Int(Stats.typingWordsPerMinute)) wpm. It is an estimate, not a measurement.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 12))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }
}
