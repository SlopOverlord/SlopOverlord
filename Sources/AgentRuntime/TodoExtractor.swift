import Foundation

public enum TodoExtractor {
    /// Extracts actionable todo candidates from prompt lines.
    public static func extractCandidates(from prompt: String) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []

        for rawLine in prompt.components(separatedBy: .newlines) {
            let line = normalizeWhitespace(rawLine)
            guard let candidate = candidate(from: line) else {
                continue
            }

            let normalizedCandidate = normalizeWhitespace(candidate)
            guard normalizedCandidate.count >= 6 else {
                continue
            }

            let key = normalizedCandidate.lowercased()
            if seen.insert(key).inserted {
                result.append(normalizedCandidate)
            }
        }

        return result
    }

    private static func candidate(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if let checklist = capture(trimmed, pattern: #"(?i)^[-*]\s*\[\s*\]\s*(.+)$"#) {
            return checklist
        }

        if let todoWithColon = capture(trimmed, pattern: #"(?i)^todo\s*:\s*(.+)$"#) {
            return todoWithColon
        }

        if let todoLine = capture(trimmed, pattern: #"(?i)^todo\s+(.+)$"#) {
            return todoLine
        }

        let lower = trimmed.lowercased()
        if lower.hasPrefix("сделай ") || lower.hasPrefix("нужно ") || lower.hasPrefix("надо ") {
            return trimmed
        }

        return nil
    }

    private static func capture(_ source: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let nsSource = source as NSString
        let range = NSRange(location: 0, length: nsSource.length)
        guard let match = regex.firstMatch(in: source, options: [], range: range),
              match.numberOfRanges > 1
        else {
            return nil
        }

        let captureRange = match.range(at: 1)
        guard captureRange.location != NSNotFound else {
            return nil
        }

        return nsSource.substring(with: captureRange)
    }

    private static func normalizeWhitespace(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
