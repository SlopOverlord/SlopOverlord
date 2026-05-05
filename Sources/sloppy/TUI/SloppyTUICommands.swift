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
        let start = currentLine.index(currentLine.startIndex, offsetBy: cursorCol - safePrefixCount)
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
        SloppyTUIProjectPathTokens.tokenBeforeCursor(
            lines: lines,
            cursorLine: cursorLine,
            cursorColumn: cursorCol
        ) != nil
    }
}
