import AppKit
import SwiftUI

/// Dictations, as a Messages-style list or a grid of glass cards, with the details
/// of the selected one in an inspector on the right.
///
/// Rows stay short: the text and one line of facts. Raw transcripts, model versions,
/// timing, and cloud requests live in the inspector, so they are one click away
/// without repeating under every row.
struct DictationBrowser: View {
    @Bindable var env: AppEnvironment
    var mode: ViewMode
    var items: [DictationRecord]
    var title: String
    @AppStorage("showsDictationInspector") private var showsInspector = true
    @State private var pendingDelete: DictationRecord?

    /// Selection lives on the environment so ⇧⌘V can reach it from the menu bar.
    private var selection: Binding<UUID?> {
        Binding(get: { env.selectedDictationID }, set: { env.selectedDictationID = $0 })
    }

    private var selectedItem: DictationRecord? {
        env.selectedDictationID.flatMap { id in items.first { $0.id == id } }
    }

    var body: some View {
        // Looked up once per render rather than once per row.
        let requests = Dictionary(grouping: env.library.cloudRequests.filter(\.isInference)) { $0.dictationID }
        Group {
            if items.isEmpty {
                ContentUnavailableView {
                    Label(env.library.query.isEmpty ? "Nothing here yet" : "No matches",
                          systemImage: "waveform")
                } description: {
                    Text(env.library.query.isEmpty
                         ? "Hold \(Settings.shared.hotkey.label) anywhere and talk."
                         : "Nothing matches \"\(env.library.query)\".")
                }
            } else if mode == .list {
                list(requests)
            } else {
                grid(requests)
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(Fmt.count(items.count, "dictation"))
        .inspector(isPresented: $showsInspector) {
            DictationInspector(env: env, item: selectedItem)
                .inspectorColumnWidth(min: 280, ideal: 340, max: 520)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsInspector.toggle()
                } label: {
                    Label("Details", systemImage: "sidebar.right")
                }
                .help(showsInspector ? "Hide details" : "Show details for the selected dictation")
            }
        }
        .onDeleteCommand { pendingDelete = selectedItem }
        .confirmationDialog("Delete this dictation?", isPresented: deleteBinding, presenting: pendingDelete) { item in
            Button("Delete", role: .destructive) { env.library.delete(item) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its text and versions are removed. Statistics keep counting it.")
        }
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var days: [(day: Date, items: [DictationRecord])] {
        let calendar = Calendar.current
        let buckets = Dictionary(grouping: items) { calendar.startOfDay(for: $0.createdAt) }
        return buckets.keys.sorted(by: >).map { ($0, buckets[$0] ?? []) }
    }

    private func list(_ requests: [UUID?: [CloudRequestRecord]]) -> some View {
        List(selection: selection) {
            ForEach(days, id: \.day) { group in
                Section {
                    ForEach(group.items) { item in
                        DictationRow(item: item, requests: requests[item.id] ?? [], env: env)
                            .tag(item.id)
                    }
                } header: {
                    DayHeader(day: group.day, count: group.items.count, noun: "dictation",
                              words: group.items.reduce(0) { $0 + Stats.wordCount($1.inserted) })
                }
            }
        }
        .listStyle(.inset)
    }

    private func grid(_ requests: [UUID?: [CloudRequestRecord]]) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 16)], alignment: .leading, spacing: 16,
                      pinnedViews: [.sectionHeaders]) {
                ForEach(days, id: \.day) { group in
                    Section {
                        ForEach(group.items) { item in
                            DictationCard(item: item, requests: requests[item.id] ?? [], env: env,
                                          selected: env.selectedDictationID == item.id)
                                .onTapGesture { env.selectedDictationID = item.id }
                        }
                    } header: {
                        DayHeader(day: group.day, count: group.items.count, noun: "dictation",
                                  words: group.items.reduce(0) { $0 + Stats.wordCount($1.inserted) })
                            .padding(.vertical, 6)
                            .background(.background)
                    }
                }
            }
            .padding(20)
        }
    }
}

/// "Today" on the left, the day's totals on the right.
private struct DayHeader: View {
    var day: Date
    var count: Int
    var noun: String
    var words: Int?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(Fmt.dayTitle(day))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer()
            Text([Fmt.count(count, noun), words.map { "\(Stats.compactCount($0)) words" }]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

// MARK: - Rows and cards

private struct DictationRow: View {
    var item: DictationRecord
    var requests: [CloudRequestRecord]
    @Bindable var env: AppEnvironment
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AppIconView(bundleID: item.appBundleID, size: 22)
                .padding(.top, 1)
                .help(item.appName)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.inserted.preview)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                DictationMeta(item: item, requests: requests)
            }
        }
        .padding(.vertical, 5)
        .contentShape(.rect)
        .overlay(alignment: .topTrailing) {
            if hovering {
                DictationQuickActions(item: item, env: env)
                    .transition(.opacity)
            }
        }
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
        }
        .contextMenu { DictationMenu(item: item, env: env) }
        .accessibilityElement(children: .combine)
        .accessibilityActions { DictationMenu(item: item, env: env) }
    }
}

private struct DictationCard: View {
    var item: DictationRecord
    var requests: [CloudRequestRecord]
    @Bindable var env: AppEnvironment
    var selected: Bool
    @State private var hovering = false

    private var lines: Int {
        let setting = Settings.shared.previewLines
        return setting == 0 ? 4 : setting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                AppIconView(bundleID: item.appBundleID, size: 18)
                Text(item.appName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            Text(item.inserted.preview)
                .font(.callout)
                .lineLimit(lines)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            DictationMeta(item: item, requests: requests, showsApp: false)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
        .contentShape(.rect)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 16).strokeBorder(.tint, lineWidth: 2)
            }
        }
        .overlay(alignment: .topTrailing) {
            if hovering {
                DictationQuickActions(item: item, env: env)
                    .padding(8)
                    .transition(.opacity)
            }
        }
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
        }
        .contextMenu { DictationMenu(item: item, env: env) }
    }
}

/// App, time, and only the chips that say something about this dictation.
private struct DictationMeta: View {
    var item: DictationRecord
    var requests: [CloudRequestRecord]
    var showsApp = true

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                if showsApp {
                    Text(item.appName).lineLimit(1)
                    Text("·")
                }
                Text(item.createdAt, format: .dateTime.hour().minute())
            }
            if item.duration > 0 {
                meta("waveform", Fmt.duration(item.duration))
                    .help("You spoke for \(Fmt.duration(item.duration))")
            }
            if let processing = item.processingDuration {
                meta("bolt.fill", Fmt.duration(processing))
                    .help("The text was ready \(Fmt.duration(processing)) after you stopped speaking")
            }
            if !item.wasCleaned {
                Chip("Raw", tint: .orange)
                    .help("Inserted as transcribed, without cleanup")
            }
            if !requests.isEmpty {
                let summary = CloudCostSummary(requests: requests)
                Chip(summary.unpricedCalls == summary.calls ? "Cloud" : Fmt.money(summary.knownCost),
                     systemImage: "cloud")
                    .help("\(Fmt.count(summary.calls, "cloud request")) for this dictation"
                          + (summary.unpricedCalls > 0 ? ", \(summary.unpricedCalls) with unknown cost" : ""))
            }
            if item.pinned {
                Image(systemName: "pin.fill").foregroundStyle(.orange).help("Pinned")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .lineLimit(1)
    }

    private func meta(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).imageScale(.small)
            Text(text)
        }
    }
}

/// The few things you do to a dictation often enough to deserve a hover button.
/// Delete stays in the context menu, the inspector, and ⌫, out of reach of a stray click.
private struct DictationQuickActions: View {
    var item: DictationRecord
    @Bindable var env: AppEnvironment

    var body: some View {
        HStack(spacing: 2) {
            CopyButton(text: item.inserted, label: "Copy text", iconOnly: true)
                .frame(width: 24, height: 22)
            Button { env.controller.reinsert(item.inserted) } label: {
                Image(systemName: "text.insert").frame(width: 24, height: 22)
            }
            .help("Insert at the cursor (⇧⌘V)")
            .accessibilityLabel("Insert at the cursor")
            Button { env.library.togglePin(item) } label: {
                Image(systemName: item.pinned ? "pin.slash" : "pin").frame(width: 24, height: 22)
            }
            .help(item.pinned ? "Unpin" : "Pin, so retention never removes it")
            .accessibilityLabel(item.pinned ? "Unpin" : "Pin")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
    }
}

private struct DictationMenu: View {
    var item: DictationRecord
    @Bindable var env: AppEnvironment

    var body: some View {
        Button("Insert at Cursor") { env.controller.reinsert(item.inserted) }
        Button("Copy") { Pasteboard.copy(item.inserted) }
        Button("Copy Raw Transcription") { Pasteboard.copy(item.rawTranscription) }
        if item.availableVersions.count > 1 {
            Menu("Copy Version") {
                ForEach(item.availableVersions) { version in
                    Button(version.displayLabel) { Pasteboard.copy(version.text) }
                }
            }
        }
        Divider()
        Button(item.pinned ? "Unpin" : "Pin") { env.library.togglePin(item) }
        Divider()
        Button("Delete", role: .destructive) { env.library.delete(item) }
    }
}

// MARK: - Inspector

/// Everything about one dictation: what was inserted, what was heard, what each
/// model returned, how long it took, and what the cloud charged.
struct DictationInspector: View {
    @Bindable var env: AppEnvironment
    var item: DictationRecord?
    @State private var tab: Tab = .inserted
    @State private var confirmingDelete = false

    enum Tab: Hashable { case inserted, raw, versions }

    var body: some View {
        if let item {
            content(item)
        } else {
            ContentUnavailableView {
                Label("No dictation selected", systemImage: "text.bubble")
            } description: {
                Text("Select one to see its raw transcript, each model's version, timing, and cloud cost.")
            }
        }
    }

    private func content(_ item: DictationRecord) -> some View {
        let requests = env.library.requests(for: item.id).filter(\.isInference)
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(item)
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Show", selection: $tab) {
                        Text("Inserted").tag(Tab.inserted)
                        Text("Raw").tag(Tab.raw)
                        Text("Versions · \(item.availableVersions.count)").tag(Tab.versions)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    switch tab {
                    case .inserted: textBlock(item.inserted, caption: item.wasCleaned ? "Cleaned up" : "Inserted as transcribed")
                    case .raw:
                        textBlock(item.rawTranscription, caption: item.rawLabel,
                                  placeholder: "Apple speech recognition returned no text for this recording.")
                    case .versions: versions(item, requests: requests)
                    }
                }
                TimingBar(speaking: item.duration, processing: item.processingDuration)
                facts(item)
                if !requests.isEmpty { requestList(requests) }
            }
            .padding(16)
        }
        .confirmationDialog("Delete this dictation?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                env.library.delete(item)
                env.selectedDictationID = nil
            }
        } message: {
            Text("Its text and versions are removed. Statistics keep counting it.")
        }
    }

    private func header(_ item: DictationRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AppIconView(bundleID: item.appBundleID, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.appName).font(.headline).lineLimit(1)
                    Text(item.createdAt.formatted(date: .complete, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button {
                    env.controller.reinsert(item.inserted)
                } label: {
                    Label("Insert", systemImage: "text.insert")
                }
                .buttonStyle(.borderedProminent)
                .help("Insert at the cursor in the app you were last using (⇧⌘V)")
                CopyButton(text: item.inserted)
                    .buttonStyle(.bordered)
                Spacer(minLength: 0)
                Button { env.library.togglePin(item) } label: {
                    Image(systemName: item.pinned ? "pin.fill" : "pin")
                }
                .buttonStyle(.borderless)
                .help(item.pinned ? "Unpin" : "Pin, so retention never removes it")
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete this dictation")
            }
            .controlSize(.small)
        }
    }

    private func textBlock(_ text: String, caption: String, placeholder: String = "No text.") -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(caption).font(.caption).foregroundStyle(.secondary)
                Spacer()
                CopyButton(text: text, iconOnly: true).buttonStyle(.borderless)
            }
            Text(text.isEmpty ? placeholder : text)
                .foregroundStyle(text.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 10))
    }

    private func versions(_ item: DictationRecord, requests: [CloudRequestRecord]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(item.availableVersions) { version in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(version.displayLabel)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        if version.text == item.inserted {
                            Chip("Inserted", systemImage: "checkmark")
                                .help("This is the text that reached the cursor")
                        }
                        Spacer(minLength: 0)
                        CopyButton(text: version.text, label: "Copy " + version.displayLabel, iconOnly: true)
                            .buttonStyle(.borderless)
                    }
                    Text(version.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if version.source == .cloud, let configID = version.configID {
                        let own = requests.filter { $0.configID == configID }
                        if !own.isEmpty {
                            let summary = CloudCostSummary(requests: own)
                            Text("\(Fmt.count(summary.calls, "request")) · \(Fmt.money(summary.knownCost))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(12)
                .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 10))
            }
        }
    }

    private func facts(_ item: DictationRecord) -> some View {
        let words = Stats.wordCount(item.inserted)
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            fact("Words", words.formatted())
            if item.duration > 0 {
                fact("Pace", "\(Int((Double(words) / (item.duration / 60)).rounded())) wpm")
                    .help("Words per minute while you were speaking")
            }
            fact("Cleanup", item.wasCleaned ? "Applied" : "Not applied")
            if item.pinned { fact("Retention", "Pinned, kept forever") }
        }
        .font(.callout)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }

    private func requestList(_ requests: [CloudRequestRecord]) -> some View {
        let summary = CloudCostSummary(requests: requests)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Cloud requests").font(.subheadline.weight(.semibold))
                Spacer()
                Text(Fmt.money(summary.knownCost)).font(.callout).monospacedDigit()
                    .help(summary.unpricedCalls > 0
                          ? "\(summary.unpricedCalls) requests have unknown cost and are left out"
                          : "Estimated from provider-reported usage")
            }
            ForEach(requests) { request in
                RequestDisclosure(request: request)
            }
        }
    }
}

/// Speaking and processing as two segments of one bar, with a legend.
private struct TimingBar: View {
    var speaking: TimeInterval
    var processing: TimeInterval?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Timing").font(.subheadline.weight(.semibold))
            if let processing, speaking + processing > 0 {
                let total = speaking + processing
                GeometryReader { geometry in
                    let width = geometry.size.width - 2
                    HStack(spacing: 2) {
                        UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 4)
                            .fill(VizPalette.series(0, scheme: scheme))
                            .frame(width: max(4, width * speaking / total))
                            .help("Speaking: \(Fmt.duration(speaking))")
                        UnevenRoundedRectangle(bottomTrailingRadius: 4, topTrailingRadius: 4)
                            .fill(VizPalette.series(1, scheme: scheme))
                            .frame(width: max(4, width * processing / total))
                            .help("Processing after you stopped: \(Fmt.duration(processing))")
                    }
                }
                .frame(height: 10)
                HStack(spacing: 14) {
                    legend(VizPalette.series(0, scheme: scheme), "Speaking", Fmt.duration(speaking))
                    legend(VizPalette.series(1, scheme: scheme), "Processing", Fmt.duration(processing))
                    Spacer(minLength: 0)
                    Text("\(Fmt.duration(total)) total").foregroundStyle(.secondary)
                }
                .font(.caption)
                .monospacedDigit()
            } else {
                Text(speaking > 0
                     ? "Spoke for \(Fmt.duration(speaking)). Dictations this old did not record processing time."
                     : "No timing was recorded.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func legend(_ color: Color, _ label: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(value).fontWeight(.medium)
            Text(label).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Notes

/// The scratchpad, same two view modes.
struct NoteBrowser: View {
    @Bindable var env: AppEnvironment
    var mode: ViewMode

    var body: some View {
        Group {
            if env.library.notes.isEmpty {
                ContentUnavailableView {
                    Label("No notes yet", systemImage: "square.and.pencil")
                } description: {
                    Text("Capture a shower thought by voice; find it next week by search.")
                } actions: {
                    Button("New Note") {
                        let note = env.library.newNote()
                        env.openNoteID = note.id
                    }
                }
            } else if mode == .list {
                List {
                    ForEach(env.library.notesByDay(), id: \.day) { group in
                        Section {
                            ForEach(group.notes) { note in
                                Button {
                                    env.openNoteID = note.id
                                } label: {
                                    NoteRow(note: note, env: env)
                                }
                                .buttonStyle(.plain)
                                .contextMenu { NoteMenu(note: note, env: env) }
                            }
                        } header: {
                            DayHeader(day: group.day, count: group.notes.count, noun: "note")
                        }
                    }
                }
                .listStyle(.inset)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 16)], spacing: 16) {
                        ForEach(env.library.notes) { note in
                            Button { env.openNoteID = note.id } label: {
                                NoteCard(note: note)
                            }
                            .buttonStyle(.plain)
                            .help("Open note")
                            .contextMenu { NoteMenu(note: note, env: env) }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .navigationTitle("Scratchpad")
        .navigationSubtitle(Fmt.count(env.library.notes.count, "note"))
    }
}

private struct NoteRow: View {
    var note: NoteRecord
    @Bindable var env: AppEnvironment
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: note.pinned ? "pin.fill" : "doc.text")
                .foregroundStyle(note.pinned ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .frame(width: 22)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(note.displayTitle).font(.body.weight(.medium)).lineLimit(1)
                if let preview = (note.summary?.nilIfEmpty ?? note.body.nilIfEmpty) {
                    Text(preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(note.updatedAt, format: .dateTime.hour().minute())
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if hovering {
                HStack(spacing: 2) {
                    CopyButton(text: note.text, label: "Copy note", iconOnly: true)
                    Button { env.library.togglePin(note) } label: {
                        Image(systemName: note.pinned ? "pin.slash" : "pin")
                    }
                    .help(note.pinned ? "Unpin" : "Pin")
                }
                .buttonStyle(.borderless)
                .transition(.opacity)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
        }
    }
}

private struct NoteCard: View {
    var note: NoteRecord

    private var lines: Int {
        let setting = Settings.shared.previewLines
        return setting == 0 ? 4 : setting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(note.displayTitle).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer()
                if note.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange) }
            }
            Text(note.summary?.nilIfEmpty ?? note.body)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(lines)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            Text(note.updatedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .contentShape(.rect)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}

private struct NoteMenu: View {
    var note: NoteRecord
    @Bindable var env: AppEnvironment

    var body: some View {
        Button("Open") { env.openNoteID = note.id }
        Button("Copy") { Pasteboard.copy(note.text) }
        Button(note.pinned ? "Unpin" : "Pin") { env.library.togglePin(note) }
        Divider()
        Button("Delete", role: .destructive) { env.library.delete(note) }
    }
}

private extension String {
    /// Paragraph breaks waste a preview line, so a preview runs paragraphs together.
    var preview: String {
        split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}
