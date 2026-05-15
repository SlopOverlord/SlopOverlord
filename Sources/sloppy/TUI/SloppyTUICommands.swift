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

struct SloppyTUIShortcutDescriptor: Equatable {
    var key: String
    var description: String

    init(_ key: String, _ description: String) {
        self.key = key
        self.description = description
    }
}

enum SloppyTUIShortcutCatalog {
    static let all: [SloppyTUIShortcutDescriptor] = [
        SloppyTUIShortcutDescriptor("/", "commands"),
        SloppyTUIShortcutDescriptor("@", "project paths"),
        SloppyTUIShortcutDescriptor("#", "project tasks"),
        SloppyTUIShortcutDescriptor("/btw", "side question"),
        SloppyTUIShortcutDescriptor("Tab", "cycle mode"),
        SloppyTUIShortcutDescriptor("Shift+Enter", "newline"),
        SloppyTUIShortcutDescriptor("Option+Enter", "newline"),
        SloppyTUIShortcutDescriptor("Esc", "interrupt run"),
        SloppyTUIShortcutDescriptor("Ctrl+V", "attach clipboard"),
        SloppyTUIShortcutDescriptor("Ctrl+O", "verbose transcript"),
        SloppyTUIShortcutDescriptor("Ctrl+B", "cancel queue"),
        SloppyTUIShortcutDescriptor("Ctrl+P", "parent session"),
        SloppyTUIShortcutDescriptor("Ctrl+G", "newest subagent"),
        SloppyTUIShortcutDescriptor("Option+P", "model picker"),
        SloppyTUIShortcutDescriptor("Ctrl+T", "project tasks"),
        SloppyTUIShortcutDescriptor("Option+E", "open editor"),
        SloppyTUIShortcutDescriptor("Option+U", "undo turn"),
        SloppyTUIShortcutDescriptor("Option+R", "redo turn"),
    ]
}

enum SloppyTUIGlobalShortcutAction: Equatable {
    case modelPicker
    case projectTasks
    case codeEditor
    case undo
    case redo

    static func match(input: TerminalInput) -> SloppyTUIGlobalShortcutAction? {
        guard case let .key(.character(character), modifiers) = input else {
            return nil
        }

        let key = String(character).lowercased()
        if modifiers.contains(.control), !modifiers.contains(.option), !modifiers.contains(.command) {
            switch key {
            case "t":
                return .projectTasks
            default:
                return nil
            }
        }

        if modifiers.contains(.option), !modifiers.contains(.control), !modifiers.contains(.command) {
            switch key {
            case "p":
                return .modelPicker
            case "e":
                return .codeEditor
            case "u":
                return .undo
            case "r":
                return .redo
            default:
                return nil
            }
        }

        return nil
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

enum SloppyTUIScrollbackCommand: Equatable {
    case status
    case update(mode: SloppyTUIScrollbackMode, lineLimit: Int?)
    case failure(String)

    static let usage = "Usage: `/scrollback [status|auto [lines]|viewport|limited <lines>|full]`"

    static func parse(_ args: [String]) -> SloppyTUIScrollbackCommand {
        guard let rawMode = args.first?.lowercased() else {
            return .status
        }

        switch rawMode {
        case "status":
            return args.count == 1 ? .status : .failure(usage)
        case "auto":
            guard args.count <= 2 else { return .failure(usage) }
            if args.count == 2 {
                guard let lineLimit = parseLineLimit(args[1]) else {
                    return .failure("Scrollback line limit must be a positive integer.\n\n\(usage)")
                }
                return .update(mode: .auto, lineLimit: lineLimit)
            }
            return .update(mode: .auto, lineLimit: nil)
        case "viewport":
            return args.count == 1 ? .update(mode: .viewport, lineLimit: nil) : .failure(usage)
        case "limited":
            guard args.count == 2 else { return .failure(usage) }
            guard let lineLimit = parseLineLimit(args[1]) else {
                return .failure("Scrollback line limit must be a positive integer.\n\n\(usage)")
            }
            return .update(mode: .limited, lineLimit: lineLimit)
        case "full":
            return args.count == 1 ? .update(mode: .full, lineLimit: nil) : .failure(usage)
        default:
            return .failure(usage)
        }
    }

    private static func parseLineLimit(_ raw: String) -> Int? {
        guard let value = Int(raw), value > 0 else {
            return nil
        }
        return value
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
