import AppKit
import Foundation

/// README screenshots, with made-up people, dictations, and costs. Runs only in a copy
/// renamed to `sh.taf.flow.demo` (see `scripts/screenshots.sh`), so its defaults, window
/// frames, and vocabulary are its own, history lives in memory, and nothing touches the
/// Keychain or the microphone.
enum DemoScreenshots {
    private static let samples: [(app: String, bundle: String, text: String)] = [
        ("Slack", "com.tinyspeck.slackmacgap", "Hey, can we push the design review to Thursday afternoon? I want to finish the onboarding flow first."),
        ("Mail", "com.apple.mail", "Hi Priya,\n\nThanks for sending the contract. I've signed it and attached the copy. Let me know if you need anything else before Friday."),
        ("Notes", "com.apple.Notes", "Groceries for the weekend:\n- Oat milk\n- Basil\n- Two lemons\n- Sourdough"),
        ("Xcode", "com.apple.dt.Xcode", "Move the retry logic into the network client so every request gets the same backoff."),
        ("Linear", "com.linear", "The export button stays disabled after the upload finishes. It should enable as soon as the file is ready."),
        ("Safari", "com.apple.Safari", "Best hiking trails near Lake Tahoe that are open in October"),
        ("Messages", "com.apple.MobileSMS", "Running ten minutes late, save me a seat."),
        ("Slack", "com.tinyspeck.slackmacgap", "Shipped the fix for the login loop. It was a stale token in the keychain cache."),
        ("Notion", "notion.id", "We need three things before launch:\n1. Final pricing page.\n2. A support macro for refunds.\n3. The status page linked from the footer."),
        ("Mail", "com.apple.mail", "Could you resend the invoice for September? The PDF in the last email won't open."),
    ]

    private static let fillers = [
        "Let's sync on the roadmap after lunch.", "Draft the release notes for version two.",
        "Remind me to call the dentist tomorrow morning.", "The staging build is green, merging now.",
        "Can you review the pull request when you get a minute?", "Book a table for four at seven thirty.",
    ]

    private static let providerID = UUID(uuidString: "6B1F3C2A-0000-4000-8000-000000000001")!
    private static let modelID = UUID(uuidString: "6B1F3C2A-0000-4000-8000-000000000002")!
    private static let configID = UUID(uuidString: "6B1F3C2A-0000-4000-8000-000000000003")!

    /// About a year of dictations, busier on weekdays and in recent weeks.
    static func store() -> MemoryStore {
        let store = MemoryStore()
        var generator = SeededGenerator(seed: 42)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let price = ModelPrice(provider: "google", model: "gemini-2.5-flash", fetchedAt: .now,
                               input: 0.30, output: 2.50, inputAudio: 1.00)
        for dayOffset in 0..<365 {
            guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: today) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            let weekend = weekday == 1 || weekday == 7
            let recent = dayOffset < 60
            var count = Int.random(in: weekend ? 0...2 : 1...6, using: &generator) + (recent ? 2 : 0)
            if Int.random(in: 0..<10, using: &generator) == 0 { count = 0 }
            for index in 0..<count {
                var sample = samples[dayOffset == 0 && index < samples.count ? index
                                     : Int.random(in: 0..<samples.count, using: &generator)]
                if dayOffset > 0, Int.random(in: 0..<3, using: &generator) > 0 {
                    sample.text = fillers[Int.random(in: 0..<fillers.count, using: &generator)]
                }
                let hour = Int.random(in: 8...19, using: &generator)
                let created = calendar.date(bySettingHour: dayOffset == 0 ? max(8, 17 - index) : hour,
                                            minute: Int.random(in: 0...59, using: &generator), second: 0, of: day) ?? day
                let words = Stats.wordCount(sample.text)
                let duration = Double(words) / 2.6 + Double.random(in: 0.5...2, using: &generator)
                let processing = Double.random(in: 0.9...2.4, using: &generator)
                let id = UUID()
                let raw = sample.text.lowercased().replacingOccurrences(of: ".", with: "").replacingOccurrences(of: "\n", with: " ")
                try? store.insert(DictationRecord(
                    id: id, raw: "um " + raw, cleaned: sample.text, appBundleID: sample.bundle, appName: sample.app,
                    createdAt: created, duration: duration,
                    versions: [DictationVersion(source: .cloud, label: "Cloud · 1. Google · gemini-2.5-flash", text: sample.text)],
                    appleRaw: "um " + raw, processingDuration: processing))
                var usage = TokenUsage(input: 700 + words * 4, output: words + 12)
                usage.audioInput = Int(duration * 25)
                try? store.saveRequest(CloudRequestRecord(
                    dictationID: id, configID: configID, configLabel: "1. Google · gemini-2.5-flash",
                    providerID: providerID, providerName: "Google",
                    modelID: "gemini-2.5-flash", stage: .onePass, startedAt: created.addingTimeInterval(duration),
                    elapsed: processing, firstTokenLatency: processing * 0.7, generationDuration: processing * 0.25,
                    outputWords: words, status: Int.random(in: 0..<40, using: &generator) == 0 ? .failed : .succeeded,
                    httpStatus: 200, usage: usage, price: price))
            }
        }
        try? store.upsert(NoteRecord(title: "Launch checklist", text: "Launch checklist\nPricing page, support macro, status page link."))
        return store
    }

    @MainActor
    static func run(directory: String) async {
        let folder = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let env = AppEnvironment.shared
        defer { NSApp.terminate(nil) }
        seedSettings(env)

        // The window opens on launch; give SwiftUI time to lay it out.
        try? await Task.sleep(for: .seconds(2))
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains(FlowApp.mainWindowID) == true })
            ?? NSApp.windows.filter({ $0.isVisible && $0.styleMask.contains(.titled) }).max(by: { $0.frame.width < $1.frame.width })
        else { print("no main window"); return }
        if let screen = window.screen ?? NSScreen.main {
            let size = CGSize(width: 1280, height: 820)
            window.setFrame(NSRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2,
                                   width: size.width, height: size.height), display: true)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        for (name, item) in [("dictations", SidebarItem.dictations), ("statistics", .stats),
                             ("vocabulary", .settings(.vocabulary)), ("models", .settings(.models))] {
            env.openSidebarItem = item
            if case .dictations = item { env.selectedDictationID = env.library.dictations.first?.id }
            try? await Task.sleep(for: .seconds(1.5))
            capture(window, to: folder.appending(path: name + ".png"))
        }
        window.orderOut(nil)

        let controller = env.controller
        let presenter = env.presenter
        await controller.previewPanelForCheck(.recording)
        for level: Float in [0.15, 0.3, 0.55, 0.8, 0.6, 0.4, 0.7, 0.35, 0.2] { controller.levels.push(level) }
        presenter.show()
        try? await Task.sleep(for: .seconds(1.2))
        if let panel = presenter.diagnosticWindow { capture(panel, to: folder.appending(path: "pill-recording.png")) }
        let answer = "Hey, can we push the design review to Thursday afternoon? I want to finish the onboarding flow first, "
            + "and I'd like Maya to look at the empty states before we show it to the wider team."
        await controller.previewPanelForCheck(.processing, text: "")
        for end in Array(stride(from: 12, to: answer.count, by: 12)) + [answer.count] {
            await controller.previewPanelForCheck(.processing, text: String(answer.prefix(end)))
            try? await Task.sleep(for: .milliseconds(30))
        }
        try? await Task.sleep(for: .milliseconds(600))
        if let panel = presenter.diagnosticWindow { capture(panel, to: folder.appending(path: "pill-streaming.png")) }
        await controller.previewPanelForCheck(.inserted(answer))
        try? await Task.sleep(for: .milliseconds(900))
        if let panel = presenter.diagnosticWindow { capture(panel, to: folder.appending(path: "pill-inserted.png")) }
        presenter.hide()
        print("wrote screenshots to \(folder.path)")
    }

    @MainActor
    private static func seedSettings(_ env: AppEnvironment) {
        let lexicon = env.lexicon
        var details = Lexicon.PersonalDetails()
        details.name = "Alex Rivera"
        details.email = "alex@example.com"
        details.company = "Northwind Labs"
        details.custom = [
            .init(label: "GitHub", description: "personal profile link", value: "github.com/alexrivera", alwaysInPrompt: true),
            .init(label: "Work address", description: "office for deliveries", value: "500 Market St, San Francisco"),
        ]
        lexicon.personalDetails = details
        lexicon.addWords("Northwind\nSwiftUI\nPostgres\nKubernetes")
        lexicon.setDescription("the company Alex works at", for: "Northwind")
        lexicon.setDescription("container orchestration, often said as K8s", for: "Kubernetes")
        lexicon.record(from: "post gress", to: "Postgres")

        var cloud = CloudSettings()
        if let index = cloud.providers.firstIndex(where: { $0.api == .google }) {
            cloud.providers[index].id = providerID
            cloud.providers[index].enabled = true
            // Held in memory only: demo mode never writes to the Keychain.
            cloud.providers[index].apiKey = "demo-key"
            var model = CloudModel(providerID: providerID, name: "", modelID: "gemini-2.5-flash", reasoning: .low)
            model.id = modelID
            var config = CloudConfig(kind: .onePass, model: modelID)
            config.id = configID
            cloud.models = [model]
            cloud.configs = [config]
            cloud.useCloud = true
        }
        Settings.shared.cloud = cloud
    }

    @MainActor
    private static func capture(_ window: NSWindow, to url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
        try? process.run()
        process.waitUntilExit()
    }
}

/// Same data on every run, so screenshots only change when the app does.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
