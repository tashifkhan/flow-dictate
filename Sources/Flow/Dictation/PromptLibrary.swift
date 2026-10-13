import Foundation
import OSLog

/// One named prompt from `Prompts/*.txt`, with `{placeholder}` slots in the style of a
/// Python format string. `{{` and `}}` are literal braces. A line that holds only a
/// placeholder disappears when that placeholder renders empty, so optional pieces
/// leave no blank lines behind.
struct PromptTemplate: Sendable, Equatable {
    enum Piece: Sendable, Equatable {
        case text(String)
        case slot(String)
    }

    let id: String
    let lines: [[Piece]]

    var placeholders: Set<String> {
        Set(lines.joined().compactMap { if case .slot(let name) = $0 { name } else { nil } })
    }

    init(id: String, source: String) throws {
        self.id = id
        lines = try source.components(separatedBy: "\n").enumerated().map { number, line in
            try Self.parse(line, id: id, line: number + 1)
        }
    }

    /// Every placeholder needs a value. Extra values are an error too, because a typo
    /// in either the file or the code would otherwise drop text silently.
    func render(_ values: [String: String] = [:]) throws -> String {
        if let missing = placeholders.subtracting(values.keys).sorted().first {
            throw PromptError.missingValue(id, missing)
        }
        if let extra = Set(values.keys).subtracting(placeholders).sorted().first {
            throw PromptError.unusedValue(id, extra)
        }
        var rendered: [String] = []
        for line in lines {
            let text = line.map { piece in
                switch piece {
                case .text(let text): text
                case .slot(let name): values[name] ?? ""
                }
            }.joined()
            if line.count == 1, case .slot = line[0], text.isEmpty { continue }
            rendered.append(text)
        }
        return rendered.joined(separator: "\n")
    }

    private static func parse(_ line: String, id: String, line number: Int) throws -> [Piece] {
        var pieces: [Piece] = []
        var text = ""
        var index = line.startIndex
        func next(_ i: String.Index) -> Character? { line.index(after: i) < line.endIndex ? line[line.index(after: i)] : nil }
        while index < line.endIndex {
            let character = line[index]
            if (character == "{" || character == "}"), next(index) == character {
                text.append(character)
                index = line.index(index, offsetBy: 2)
                continue
            }
            if character == "}" { throw PromptError.strayBrace(id, number) }
            guard character == "{" else {
                text.append(character)
                index = line.index(after: index)
                continue
            }
            guard let close = line[index...].firstIndex(of: "}") else { throw PromptError.strayBrace(id, number) }
            let name = String(line[line.index(after: index)..<close])
            guard name.range(of: #"^[a-z][a-z0-9_]*$"#, options: .regularExpression) != nil else {
                throw PromptError.badPlaceholder(id, number, name)
            }
            if !text.isEmpty { pieces.append(.text(text)); text = "" }
            pieces.append(.slot(name))
            index = line.index(after: close)
        }
        if !text.isEmpty || pieces.isEmpty { pieces.append(.text(text)) }
        return pieces
    }
}

enum PromptError: Error, LocalizedError, Equatable {
    case strayBrace(String, Int)
    case badPlaceholder(String, Int, String)
    case missingValue(String, String)
    case unusedValue(String, String)
    case unknownPrompt(String)
    case badFile(String, Int)

    var errorDescription: String? {
        switch self {
        case .strayBrace(let id, let line): "\(id), line \(line): a lone brace. Write {{ or }} for a literal one."
        case .badPlaceholder(let id, let line, let name): "\(id), line \(line): \"{\(name)}\" is not a placeholder name."
        case .missingValue(let id, let name): "\(id) needs a value for {\(name)}."
        case .unusedValue(let id, let name): "\(id) has no {\(name)} placeholder."
        case .unknownPrompt(let id): "There is no prompt named \(id)."
        case .badFile(let file, let line): "\(file), line \(line): text before the first [section]."
        }
    }
}

/// Every prompt Flow sends, loaded once from the `Prompts` folder. A file holds named
/// sections: a `[name]` line starts one, and `;` starts a comment line. A prompt's id
/// is its file name and section, such as `cloud.refine`.
enum PromptLibrary {
    private static let log = Logger(subsystem: "sh.taf.flow", category: "prompts")

    static let templates: [String: PromptTemplate] = {
        do { return try load(from: directory) } catch {
            log.fault("prompts failed to load: \(error.localizedDescription, privacy: .public)")
            assertionFailure(error.localizedDescription)
            return [:]
        }
    }()

    /// The app bundle's copy, or the source folder for a bare `swift run`.
    static var directory: URL {
        if let bundled = Bundle.main.resourceURL?.appending(path: "Prompts"),
           FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Prompts")
    }

    static func load(from directory: URL) throws -> [String: PromptTemplate] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "txt" }
        var templates: [String: PromptTemplate] = [:]
        for file in files {
            let prefix = file.deletingPathExtension().lastPathComponent
            for (section, body) in try sections(in: String(contentsOf: file, encoding: .utf8), file: file.lastPathComponent) {
                let id = prefix + "." + section
                templates[id] = try PromptTemplate(id: id, source: body)
            }
        }
        return templates
    }

    /// Section bodies keep their inner line breaks and lose blank lines at either end.
    static func sections(in source: String, file: String) throws -> [(String, String)] {
        var result: [(String, String)] = []
        var name: String?
        var body: [String] = []
        func flush() {
            guard let name else { return }
            while body.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { body.removeFirst() }
            while body.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { body.removeLast() }
            result.append((name, body.joined(separator: "\n")))
        }
        for (number, line) in source.components(separatedBy: "\n").enumerated() {
            if line.hasPrefix(";") { continue }
            if let match = line.firstMatch(of: /^\[([a-z0-9_.]+)\]\s*$/) {
                flush()
                name = String(match.1)
                body = []
            } else if name == nil {
                guard line.trimmingCharacters(in: .whitespaces).isEmpty else { throw PromptError.badFile(file, number + 1) }
            } else {
                body.append(line)
            }
        }
        flush()
        return result
    }

    /// Every prompt id the code renders, so the self-check can catch a missing or an
    /// orphaned section.
    static let instructionIDs: Set<String> = {
        var ids: Set<String> = [
            "policy.rules", "policy.terms", "policy.term", "policy.term.described", "policy.replacements",
            "policy.replacement", "policy.speaker", "policy.speaker.detail", "policy.speaker.detail.described",
            "cloud.transcribe", "cloud.transcribe.hinglish", "cloud.one_pass", "cloud.refine", "cloud.hinglish",
            "local.instructions", "local.hinglish", "local.examples", "local.last_insert", "local.terms.near_miss",
            "local.commands", "local.schema.mode", "local.schema.text", "local.schema.target",
            "local.summary", "local.summary.title", "local.summary.summary",
        ]
        for style in ["chat", "email", "development", "document", "general"] {
            ids.insert("cloud.style." + style)
            ids.insert("local.style." + style)
        }
        return ids
    }()

    /// A bad prompt id or placeholder is a bug. Debug builds stop; release builds log
    /// it and leave that piece out.
    static func render(_ id: String, _ values: [String: String] = [:]) -> String {
        do {
            guard let template = templates[id] else { throw PromptError.unknownPrompt(id) }
            return try template.render(values)
        } catch {
            log.fault("prompt \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            assertionFailure(error.localizedDescription)
            return ""
        }
    }
}
