import Foundation
import TauTUI

enum SloppyTUIAutocompleteFeatureFlags {
    static let editorAutocompleteEnabled = false
    static let projectPathAutocompleteEnabled = false
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

final class SloppyTUIAutocompleteProvider: AutocompleteProvider {
    private let base: CombinedAutocompleteProvider
    private static let debugEnabled = ProcessInfo.processInfo.environment["SLOPPY_TUI_AUTOCOMPLETE_DEBUG"] == "1"

    init(basePath: String) {
        self.base = CombinedAutocompleteProvider(basePath: basePath)
        Self.debug("init basePath=\(basePath)")
    }

    private static func debug(_ message: @autoclosure () -> String) {
        guard debugEnabled else { return }
        FileHandle.standardError.write(Data(("[SloppyTUIAutocompleteProvider] \(message())\n").utf8))
    }

    func getSuggestions(lines: [String], cursorLine: Int, cursorCol: Int) -> AutocompleteSuggestion? {
        let attachmentToken = isAttachmentTokenAtCursor(lines: lines, cursorLine: cursorLine, cursorCol: cursorCol)
        Self.debug("getSuggestions cursor=\(cursorLine):\(cursorCol) attachmentToken=\(attachmentToken) line=\(Self.debugLine(lines, cursorLine))")
        guard !attachmentToken else {
            Self.debug("getSuggestions -> nil because attachment token is active")
            return nil
        }
        let suggestion = base.getSuggestions(lines: lines, cursorLine: cursorLine, cursorCol: cursorCol)
        Self.debug("getSuggestions -> \(Self.debugSuggestion(suggestion))")
        return suggestion
    }

    func applyCompletion(
        lines: [String],
        cursorLine: Int,
        cursorCol: Int,
        item: AutocompleteItem,
        prefix: String
    ) -> (lines: [String], cursorLine: Int, cursorCol: Int) {
        Self.debug("applyCompletion prefix=\(prefix.debugDescription) itemValue=\(item.value.debugDescription) cursor=\(cursorLine):\(cursorCol) lineBefore=\(Self.debugLine(lines, cursorLine))")
        guard prefix.hasPrefix("@") else {
            let result = base.applyCompletion(
                lines: lines,
                cursorLine: cursorLine,
                cursorCol: cursorCol,
                item: item,
                prefix: prefix
            )
            Self.debug("applyCompletion delegatedToBase -> cursor=\(result.cursorLine):\(result.cursorCol) lineAfter=\(Self.debugLine(result.lines, result.cursorLine))")
            return result
        }
        guard lines.indices.contains(cursorLine) else {
            Self.debug("applyCompletion aborted because cursorLine is out of bounds")
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
        Self.debug("applyCompletion tokenReplacement start=\(startOffset) end=\(cursorCol) safePrefixCount=\(safePrefixCount) replacement=\(replacement.debugDescription)")
        currentLine.replaceSubrange(start..<end, with: replacement)
        mutableLines[cursorLine] = currentLine
        let newCursor = cursorCol - safePrefixCount + replacement.count
        Self.debug("applyCompletion result cursor=\(cursorLine):\(max(0, newCursor)) lineAfter=\(currentLine.debugDescription)")
        return (mutableLines, cursorLine, max(0, newCursor))
    }

    func forceFileSuggestions(lines: [String], cursorLine: Int, cursorCol: Int) -> AutocompleteSuggestion? {
        let attachmentToken = isAttachmentTokenAtCursor(lines: lines, cursorLine: cursorLine, cursorCol: cursorCol)
        Self.debug("forceFileSuggestions cursor=\(cursorLine):\(cursorCol) attachmentToken=\(attachmentToken) line=\(Self.debugLine(lines, cursorLine))")
        guard !attachmentToken else {
            Self.debug("forceFileSuggestions -> nil because attachment token is active")
            return nil
        }
        let suggestion = base.forceFileSuggestions(lines: lines, cursorLine: cursorLine, cursorCol: cursorCol)
        Self.debug("forceFileSuggestions -> \(Self.debugSuggestion(suggestion))")
        return suggestion
    }

    func shouldTriggerFileCompletion(lines: [String], cursorLine: Int, cursorCol: Int) -> Bool {
        guard lines.indices.contains(cursorLine) else {
            Self.debug("shouldTriggerFileCompletion -> false because cursorLine is out of bounds")
            return false
        }
        let currentLine = lines[cursorLine]
        let prefixIndex = currentLine.index(currentLine.startIndex, offsetBy: min(cursorCol, currentLine.count))
        let textBeforeCursor = String(currentLine[..<prefixIndex])
        let result = textBeforeCursor.trimmingCharacters(in: .whitespaces).hasPrefix("/")
        Self.debug("shouldTriggerFileCompletion cursor=\(cursorLine):\(cursorCol) textBeforeCursor=\(textBeforeCursor.debugDescription) -> \(result)")
        return result
    }

    private func isAttachmentTokenAtCursor(lines: [String], cursorLine: Int, cursorCol: Int) -> Bool {
        let token = SloppyTUIProjectPathTokens.tokenBeforeCursor(
            lines: lines,
            cursorLine: cursorLine,
            cursorColumn: cursorCol
        )
        if let token {
            Self.debug("isAttachmentTokenAtCursor -> true token=raw:\(token.rawToken.debugDescription) path:\(token.path.debugDescription) span=\(token.line):\(token.startColumn)-\(token.endColumn)")
        }
        return token != nil
    }

    private static func debugLine(_ lines: [String], _ line: Int) -> String {
        guard lines.indices.contains(line) else { return "<line-out-of-range>" }
        return lines[line].debugDescription
    }

    private static func debugSuggestion(_ suggestion: AutocompleteSuggestion?) -> String {
        guard let suggestion else { return "nil" }
        let values = suggestion.items.prefix(5).map(\.value)
        return "prefix=\(suggestion.prefix.debugDescription) items=\(suggestion.items.count) sample=\(values)"
    }
}
