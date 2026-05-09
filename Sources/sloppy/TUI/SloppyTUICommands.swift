import Foundation
import TauTUI

enum SloppyTUIAutocompleteFeatureFlags {
    static let editorAutocompleteEnabled = false
    static let projectPathAutocompleteEnabled = true
    static let projectTaskAutocompleteEnabled = true
}

struct SloppyTUISlashCommand: SlashCommand {
    let name: String
    let description: String?
    let argument: String?
    var requiresArgument: Bool {
        if name == "model" || name == "effort" || name == "fork" {
            return false
        }
        return argument != nil || name == "anthropic-callback"
    }

    init(_ name: String, _ description: String?, argument: String? = nil) {
        self.name = name
        self.description = description
        self.argument = argument
    }

    func argumentCompletions(prefix: String) -> [AutocompleteItem] {
        []
    }
}

enum SloppyTUISlashCommandRouter {
    static func commandName(in raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("/") else { return nil }
        let token = value.split(separator: " ", omittingEmptySubsequences: true).first ?? ""
        let name = String(token.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return name.lowercased()
    }

    static func shouldHandle(
        _ raw: String,
        commandNames: Set<String>,
        skillCommandNames: Set<String>
    ) -> Bool {
        guard let name = commandName(in: raw) else { return false }
        return commandNames.contains(name) || skillCommandNames.contains(name)
    }
}

struct SloppyTUIDoubleEscapeDetector {
    static let defaultInterval: TimeInterval = 0.75

    var interval: TimeInterval = Self.defaultInterval
    private var lastEscapeAt: Date?

    init(interval: TimeInterval = Self.defaultInterval) {
        self.interval = interval
    }

    mutating func shouldInterrupt(input: TerminalInput, now: Date = Date(), isInterruptible: Bool) -> Bool {
        guard isInterruptible else {
            lastEscapeAt = nil
            return false
        }
        guard case .key(.escape, let modifiers) = input, modifiers.isEmpty else {
            lastEscapeAt = nil
            return false
        }

        defer { lastEscapeAt = now }
        guard let lastEscapeAt else {
            return false
        }
        let elapsed = now.timeIntervalSince(lastEscapeAt)
        return elapsed >= 0 && elapsed <= interval
    }

    mutating func reset() {
        lastEscapeAt = nil
    }
}

struct SloppyTUIControlCExitDetector {
    static let defaultInterval: TimeInterval = 2

    var interval: TimeInterval = Self.defaultInterval
    private var lastControlCAt: Date?

    init(interval: TimeInterval = Self.defaultInterval) {
        self.interval = interval
    }

    mutating func shouldExit(now: Date = Date()) -> Bool {
        defer { lastControlCAt = now }
        guard let lastControlCAt else {
            return false
        }

        let elapsed = now.timeIntervalSince(lastControlCAt)
        return elapsed >= 0 && elapsed <= interval
    }

    mutating func reset() {
        lastControlCAt = nil
    }
}

final class SloppyTUIAutocompleteProvider: AutocompleteProvider {
    private let base: CombinedAutocompleteProvider

    init(basePath: String) {
        self.base = CombinedAutocompleteProvider(basePath: basePath)
    }

    func getSuggestions(lines: [String], cursorLine: Int, cursorCol: Int) -> AutocompleteSuggestion? {
        guard !isAttachmentTokenAtCursor(lines: lines, cursorLine: cursorLine, cursorCol: cursorCol) else {
            return nil
        }
        return base.getSuggestions(lines: lines, cursorLine: cursorLine, cursorCol: cursorCol)
    }

    func applyCompletion(
        lines: [String],
        cursorLine: Int,
        cursorCol: Int,
        item: AutocompleteItem,
        prefix: String
    ) -> (lines: [String], cursorLine: Int, cursorCol: Int) {
        guard prefix.hasPrefix("@") else {
            return base.applyCompletion(
                lines: lines,
                cursorLine: cursorLine,
                cursorCol: cursorCol,
                item: item,
                prefix: prefix
            )
        }
        guard lines.indices.contains(cursorLine) else {
            return (lines, cursorLine, cursorCol)
        }

        var mutableLines = lines
        var currentLine = lines[cursorLine]
        let safePrefixCount = min(prefix.count, cursorCol)
        let startOffset = cursorCol - safePrefixCount
        let start = currentLine.index(currentLine.startIndex, offsetBy: startOffset)
        let end = currentLine.index(start, offsetBy: safePrefixCount)
        let value = item.value.hasPrefix("@") ? String(item.value.dropFirst()) : item.value
        let replacement = "@\(SloppyTUIProjectPathTokens.escapedTokenValue(value)) "
        currentLine.replaceSubrange(start..<end, with: replacement)
        mutableLines[cursorLine] = currentLine
        let newCursor = cursorCol - safePrefixCount + replacement.count
        return (mutableLines, cursorLine, max(0, newCursor))
    }

    func forceFileSuggestions(lines: [String], cursorLine: Int, cursorCol: Int) -> AutocompleteSuggestion? {
        guard !isAttachmentTokenAtCursor(lines: lines, cursorLine: cursorLine, cursorCol: cursorCol) else {
            return nil
        }
        return base.forceFileSuggestions(lines: lines, cursorLine: cursorLine, cursorCol: cursorCol)
    }

    func shouldTriggerFileCompletion(lines: [String], cursorLine: Int, cursorCol: Int) -> Bool {
        guard lines.indices.contains(cursorLine) else {
            return false
        }
        let currentLine = lines[cursorLine]
        let prefixIndex = currentLine.index(currentLine.startIndex, offsetBy: min(cursorCol, currentLine.count))
        let textBeforeCursor = String(currentLine[..<prefixIndex])
        return textBeforeCursor.trimmingCharacters(in: .whitespaces).hasPrefix("/")
    }

    private func isAttachmentTokenAtCursor(lines: [String], cursorLine: Int, cursorCol: Int) -> Bool {
        let token = SloppyTUIProjectPathTokens.tokenBeforeCursor(
            lines: lines,
            cursorLine: cursorLine,
            cursorColumn: cursorCol
        )
        return token != nil
    }
}
