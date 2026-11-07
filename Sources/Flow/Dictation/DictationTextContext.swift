import Foundation

/// A bounded snapshot of the draft, kept out of history and insertion results.
enum DictationTextContext {
    static func snapshot(text: String, selection: NSRange? = nil) -> String? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let parts: [String: String]
        if let selection, selection.location >= 0, selection.length >= 0,
           selection.location <= text.utf16.count,
           selection.length <= text.utf16.count - selection.location,
           let range = Range(selection, in: text) {
            parts = [
                "before_cursor": String(text[..<range.lowerBound].suffix(2000)),
                "selected_text": String(text[range].prefix(500)),
                "after_cursor": String(text[range.upperBound...].prefix(500)),
            ]
        } else {
            // Some editors expose their text but no usable selection offsets.
            parts = ["existing_text": String(text.suffix(3000))]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: parts, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }
}
