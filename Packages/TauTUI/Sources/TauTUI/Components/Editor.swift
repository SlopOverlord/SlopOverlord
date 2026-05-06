import Foundation

public struct TextEditorConfig {
    public init() {}
}

public struct EditorTheme: Sendable {
    public var borderColor: AnsiStyling.Style
    public var selectList: SelectListTheme

    public init(borderColor: @escaping AnsiStyling.Style, selectList: SelectListTheme) {
        self.borderColor = borderColor
        self.selectList = selectList
    }

    public static let `default` = EditorTheme(
        borderColor: { "\u{001B}[90m\($0)\u{001B}[0m" },
        selectList: .default)
}

public struct CursorPosition: Sendable, Equatable {
    public let line: Int
    public let col: Int

    public init(line: Int, col: Int) {
        self.line = line
        self.col = col
    }
}

public struct TextSelection: Sendable, Equatable {
    public let anchor: CursorPosition
    public let focus: CursorPosition

    public init(anchor: CursorPosition, focus: CursorPosition) {
        self.anchor = anchor
        self.focus = focus
    }
}

public final class Editor: Component {
    // Pure, Sendable buffer keeps mutations testable and UI-free.
    var buffer = EditorBuffer()
    var config = TextEditorConfig()

    // Autocomplete is optional and pluggable (slash commands + file completion).
    var autocompleteProvider: AutocompleteProvider?
    var autocompleteList: SelectList?
    var isAutocompleting = false
    var autocompletePrefix = ""

    // Large pastes are stored and replaced by markers until submit, mirroring pi-tui.
    var pastes: [Int: String] = [:]
    var pasteCounter = 0

    // Store last render width for cursor navigation + history rules.
    var lastWidth: Int = 80

    // Selection anchor is nil when there is no active selection. Focus is always
    // the buffer cursor.
    var selectionAnchor: CursorPosition?

    // Prompt history for up/down navigation (pi-mono parity).
    var history: [String] = []
    var historyIndex: Int = -1 // -1 = not browsing, 0 = most recent, 1 = older, etc.

    public var disableSubmit = false
    public var onSubmit: ((String) -> Void)?
    public var onChange: ((String) -> Void)?

    public var theme: EditorTheme

    public init(config: TextEditorConfig = TextEditorConfig(), theme: EditorTheme = .default) {
        self.config = config
        self.theme = theme
    }

    public func configure(_ config: TextEditorConfig) {
        self.config = config
    }

    public func setAutocompleteProvider(_ provider: AutocompleteProvider) {
        self.autocompleteProvider = provider
    }

    public func render(width: Int) -> [String] {
        self.lastWidth = width
        let horizontal = self.theme.borderColor(String(repeating: "─", count: width))
        var result: [String] = [horizontal]
        result.append(contentsOf: self.renderContent(width: width))
        result.append(horizontal)
        if self.isAutocompleting, let list = autocompleteList {
            result.append(contentsOf: list.render(width: width))
        }
        return result
    }

    public func handle(input: TerminalInput) {
        switch input {
        case let .paste(text):
            self.handlePaste(text)
        case let .key(key, modifiers):
            self.handleKey(key, modifiers: modifiers)
        case .raw:
            break
        case .terminalCellSize:
            break
        }
    }

    public func setText(_ text: String) {
        self.historyIndex = -1 // exit history browsing mode
        self.selectionAnchor = nil
        self.buffer.setText(text)
        self.onChange?(self.getText())
    }

    public func getText() -> String {
        self.buffer.text
    }

    // MARK: - History + cursor movement helpers (pi-mono parity)

    private func isEditorEmpty() -> Bool {
        self.buffer.lines.count == 1 && self.buffer.lines[0].isEmpty
    }

    private func navigateHistory(_ direction: Int) {
        guard !self.history.isEmpty else { return }
        guard direction == -1 || direction == 1 else { return }

        let newIndex = self.historyIndex - direction
        guard newIndex >= -1, newIndex < self.history.count else { return }

        self.historyIndex = newIndex
        self.selectionAnchor = nil
        let text = self.historyIndex == -1 ? "" : (self.history[self.historyIndex])
        self.buffer.setText(text)
        self.onChange?(self.getText())
    }

    private func moveCursorVisual(deltaLine: Int) {
        let moved = EditorLayoutEngine.moveCursorVertically(
            lines: self.buffer.lines,
            width: self.lastWidth,
            cursorLine: self.buffer.cursorLine,
            cursorCol: self.buffer.cursorCol,
            deltaLine: deltaLine)

        self.buffer = self.withMutatingBuffer { buf in
            buf.cursorLine = moved.line
            buf.cursorCol = moved.col
        }
    }

    private func moveCursorHorizontal(deltaCol: Int) {
        let moved = EditorLayoutEngine.moveCursorHorizontally(
            lines: self.buffer.lines,
            cursorLine: self.buffer.cursorLine,
            cursorCol: self.buffer.cursorCol,
            deltaCol: deltaCol)

        self.buffer = self.withMutatingBuffer { buf in
            buf.cursorLine = moved.line
            buf.cursorCol = moved.col
        }
    }

    private func isOnFirstVisualLine() -> Bool {
        EditorLayoutEngine.isOnFirstVisualLine(
            lines: self.buffer.lines,
            width: self.lastWidth,
            cursorLine: self.buffer.cursorLine,
            cursorCol: self.buffer.cursorCol)
    }

    private func isOnLastVisualLine() -> Bool {
        EditorLayoutEngine.isOnLastVisualLine(
            lines: self.buffer.lines,
            width: self.lastWidth,
            cursorLine: self.buffer.cursorLine,
            cursorCol: self.buffer.cursorCol)
    }

    private func renderContent(width: Int) -> [String] {
        EditorLayoutEngine.renderContent(
            lines: self.buffer.lines,
            cursorLine: self.buffer.cursorLine,
            cursorCol: self.buffer.cursorCol,
            selection: self.normalizedSelection(),
            width: width)
    }

    public func getLines() -> [String] {
        Array(self.buffer.lines)
    }

    public func getCursor() -> CursorPosition {
        CursorPosition(line: self.buffer.cursorLine, col: self.buffer.cursorCol)
    }

    public func getSelection() -> TextSelection? {
        guard let selectionAnchor else { return nil }
        let focus = self.getCursor()
        guard selectionAnchor != focus else { return nil }
        return TextSelection(anchor: selectionAnchor, focus: focus)
    }

    public func addToHistory(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let first = self.history.first, first == trimmed { return }
        self.history.insert(trimmed, at: 0)
        if self.history.count > 100 {
            self.history.removeLast(self.history.count - 100)
        }
    }

    // swiftlint:disable cyclomatic_complexity
    private func handleKey(_ key: TerminalKey, modifiers: KeyModifiers) {
        if self.isAutocompleting {
            switch key {
            case .arrowUp, .arrowDown:
                self.autocompleteList?.handle(input: .key(key, modifiers: modifiers))
                return
            case .enter, .tab:
                self.applySelectedAutocompleteItem()
                return
            case .escape:
                self.cancelAutocomplete()
                return
            default:
                break
            }
        }
        switch key {
        case .enter:
            if modifiers.contains(.shift) || modifiers.contains(.option) || modifiers.contains(.meta) {
                self.insertNewLine()
            } else if self.disableSubmit {
                return
            } else {
                self.submit()
            }
        case .tab:
            self.handleTabCompletion()
        case .escape:
            self.cancelAutocomplete()
            self.selectionAnchor = nil
        case .backspace:
            self.historyIndex = -1
            if modifiers.contains(.option) {
                self.deleteWordBackwards()
            } else {
                self.backspace()
            }
        case .delete:
            self.historyIndex = -1
            if modifiers.contains(.option) {
                self.deleteWordForward()
            } else {
                self.deleteForward()
            }
        case .arrowUp:
            if modifiers.contains(.command) {
                self.moveWithSelection(modifiers: modifiers) { self.moveToDocumentBoundary(-1) }
            } else if self.isEditorEmpty(), !modifiers.contains(.shift) {
                self.navigateHistory(-1)
            } else if self.historyIndex > -1, self.isOnFirstVisualLine(), !modifiers.contains(.shift) {
                self.navigateHistory(-1)
            } else {
                self.moveWithSelection(modifiers: modifiers) { self.moveCursorVisual(deltaLine: -1) }
            }
        case .arrowDown:
            if modifiers.contains(.command) {
                self.moveWithSelection(modifiers: modifiers) { self.moveToDocumentBoundary(1) }
            } else if self.historyIndex > -1, self.isOnLastVisualLine(), !modifiers.contains(.shift) {
                self.navigateHistory(1)
            } else {
                self.moveWithSelection(modifiers: modifiers) { self.moveCursorVisual(deltaLine: 1) }
            }
        case .arrowLeft:
            if modifiers.contains(.command) {
                self.moveWithSelection(modifiers: modifiers) { self.moveToLineBoundary(-1) }
            } else if modifiers.contains(.option) || modifiers.contains(.control) {
                self.moveWithSelection(modifiers: modifiers) { self.moveByWord(-1) }
            } else {
                self.moveWithSelection(modifiers: modifiers) { self.moveCursorHorizontal(deltaCol: -1) }
            }
        case .arrowRight:
            if modifiers.contains(.command) {
                self.moveWithSelection(modifiers: modifiers) { self.moveToLineBoundary(1) }
            } else if modifiers.contains(.option) || modifiers.contains(.control) {
                self.moveWithSelection(modifiers: modifiers) { self.moveByWord(1) }
            } else {
                self.moveWithSelection(modifiers: modifiers) { self.moveCursorHorizontal(deltaCol: 1) }
            }
        case .home:
            self.moveWithSelection(modifiers: modifiers) { self.buffer = self.withMutatingBuffer { buf in buf.moveToLineStart() } }
        case .end:
            self.moveWithSelection(modifiers: modifiers) { self.buffer = self.withMutatingBuffer { buf in buf.moveToLineEnd() } }
        case let .character(char):
            if modifiers.contains(.control) {
                switch char.lowercased() {
                case "u":
                    self.historyIndex = -1
                    self.deleteToStartOfLine()
                case "k":
                    self.historyIndex = -1
                    self.deleteToEndOfLine()
                case "w":
                    self.historyIndex = -1
                    self.deleteWordBackwards()
                case "a":
                    self.moveWithSelection(modifiers: modifiers) { self.buffer = self.withMutatingBuffer { buf in buf.moveToLineStart() } }
                case "e":
                    self.moveWithSelection(modifiers: modifiers) { self.buffer = self.withMutatingBuffer { buf in buf.moveToLineEnd() } }
                default:
                    self.insertCharacter(String(char))
                }
            } else {
                self.insertCharacter(String(char))
            }
        default:
            break
        }
    }

    // swiftlint:enable cyclomatic_complexity

    private func insertCharacter(_ character: String) {
        self.historyIndex = -1
        _ = self.deleteSelectionIfNeeded()
        self.buffer = self.withMutatingBuffer { buf in buf.insertCharacter(character) }
        self.onChange?(self.getText())
        if !self.isAutocompleting {
            self.triggerAutocomplete(explicit: false)
        } else {
            self.updateAutocomplete()
        }
    }

    private func insertNewLine() {
        _ = self.deleteSelectionIfNeeded()
        self.buffer = self.withMutatingBuffer { buf in buf.insertNewLine() }
        self.onChange?(self.getText())
    }

    private func backspace() {
        if self.deleteSelectionIfNeeded() {
            self.onChange?(self.getText())
            return
        }
        self.buffer = self.withMutatingBuffer { buf in buf.backspace() }
        self.onChange?(self.getText())
    }

    private func deleteForward() {
        if self.deleteSelectionIfNeeded() {
            self.onChange?(self.getText())
            return
        }
        self.buffer = self.withMutatingBuffer { buf in buf.deleteForward() }
        self.onChange?(self.getText())
    }

    private func deleteWordForward() {
        self.buffer = self.withMutatingBuffer { buf in
            buf.deleteWordForward(isBoundary: self.isBoundary)
        }
        self.onChange?(self.getText())
    }

    private func moveCursor(lineDelta: Int, columnDelta: Int) {
        self.buffer = self.withMutatingBuffer { buf in buf.moveCursor(lineDelta: lineDelta, columnDelta: columnDelta) }
    }

    private func submit() {
        var text = self.getText().trimmingCharacters(in: .whitespacesAndNewlines)
        for (id, paste) in self.pastes {
            let pattern = "\\[paste #\(id)(?: [^\\]]+)?\\]"
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let range = NSRange(location: 0, length: text.utf16.count)
                text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: paste)
            }
        }
        self.buffer = EditorBuffer()
        self.selectionAnchor = nil
        self.pastes.removeAll()
        self.pasteCounter = 0
        self.historyIndex = -1
        self.addToHistory(text)
        self.onChange?("")
        self.onSubmit?(text)
    }

    private func deleteToStartOfLine() {
        self.buffer = self.withMutatingBuffer { buf in buf.deleteToStartOfLine() }
        self.onChange?(self.getText())
    }

    private func deleteToEndOfLine() {
        self.buffer = self.withMutatingBuffer { buf in buf.deleteToEndOfLine() }
        self.onChange?(self.getText())
    }

    private func deleteWordBackwards() {
        self.buffer = self.withMutatingBuffer { buf in
            buf.deleteWordBackwards(isBoundary: self.isBoundary)
        }
        self.onChange?(self.getText())
    }

    private func moveByWord(_ direction: Int) {
        self.buffer = self.withMutatingBuffer { buf in buf.moveByWord(direction, isBoundary: self.isBoundary) }
    }

    private func isPunctuation(_ ch: Character) -> Bool {
        let punctuation: Set<Character> = Set("(){}[]<>.,;:'\"!?+-=*/\\|&%^$#@~`")
        return punctuation.contains(ch)
    }

    private func isWordCharacter(_ ch: Character) -> Bool {
        ch.isLetter || ch.isNumber || ch == "_"
    }

    private func isBoundary(_ ch: Character) -> Bool {
        ch.isWhitespace || self.isPunctuation(ch)
    }

    private func handlePaste(_ text: String) {
        self.historyIndex = -1
        _ = self.deleteSelectionIfNeeded()
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let spacesExpanded = normalized.replacingOccurrences(of: "\t", with: "    ")
        var sanitized = spacesExpanded.reduce(into: "") { partial, char in
            if char == "\n" {
                partial.append(char)
                return
            }
            // Keep any printable Unicode character; drop control chars (< 0x20).
            let hasControl = char.unicodeScalars.contains { $0.value < 32 }
            if !hasControl {
                partial.append(char)
            }
        }

        // If pasting a file path and the character before the cursor is a word character, prepend a space.
        if let first = sanitized.first,
           first == "/" || first == "~" || first == "."
        {
            let currentLine = self.buffer.lines[self.buffer.cursorLine]
            if self.buffer.cursorCol > 0, self.buffer.cursorCol <= currentLine.count {
                let beforeIndex = currentLine.index(currentLine.startIndex, offsetBy: self.buffer.cursorCol - 1)
                let charBeforeCursor = currentLine[beforeIndex]
                if self.isWordCharacter(charBeforeCursor) {
                    sanitized = " " + sanitized
                }
            }
        }

        let lines = sanitized.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > 10 || sanitized.count > 1000 {
            self.pasteCounter += 1
            self.pastes[self.pasteCounter] = sanitized
            let marker = if lines.count > 10 {
                "[paste #\(self.pasteCounter) +\(lines.count) lines]"
            } else {
                "[paste #\(self.pasteCounter) \(sanitized.count) chars]"
            }
            for char in marker {
                self.insertCharacter(String(char))
            }
            return
        }
        if lines.count == 1 {
            for char in sanitized {
                self.insertCharacter(String(char))
            }
            return
        }
        let currentLine = self.buffer.lines[self.buffer.cursorLine]
        let before = currentLine.prefix(self.buffer.cursorCol)
        let after = currentLine.suffix(currentLine.count - self.buffer.cursorCol)
        self.buffer = self.withMutatingBuffer { buf in
            buf.lines[buf.cursorLine] = String(before) + String(lines.first ?? "")
        }
        var insertionIndex = self.buffer.cursorLine + 1
        for middle in lines.dropFirst().dropLast() {
            self.buffer = self.withMutatingBuffer { buf in buf.lines.insert(String(middle), at: insertionIndex) }
            insertionIndex += 1
        }
        if let last = lines.last {
            self.buffer = self.withMutatingBuffer { buf in
                buf.lines.insert(String(last) + String(after), at: insertionIndex)
                buf.cursorLine = insertionIndex
                buf.cursorCol = String(last).count
            }
        }
        self.onChange?(self.getText())
    }

    /// Helper to mutate the value-type buffer while keeping `Editor` reference semantics.
    func withMutatingBuffer(_ mutate: (inout EditorBuffer) -> Void) -> EditorBuffer {
        var copy = self.buffer
        mutate(&copy)
        return copy
    }

    private func moveWithSelection(modifiers: KeyModifiers, move: () -> Void) {
        let originalCursor = self.getCursor()
        if modifiers.contains(.shift), self.selectionAnchor == nil {
            self.selectionAnchor = originalCursor
        }
        move()
        if modifiers.contains(.shift) {
            if self.selectionAnchor == self.getCursor() {
                self.selectionAnchor = nil
            }
        } else {
            self.selectionAnchor = nil
        }
    }

    private func moveToLineBoundary(_ direction: Int) {
        self.buffer = self.withMutatingBuffer { buf in
            if direction < 0 {
                buf.moveToLineStart()
            } else {
                buf.moveToLineEnd()
            }
        }
    }

    private func moveToDocumentBoundary(_ direction: Int) {
        self.buffer = self.withMutatingBuffer { buf in
            if direction < 0 {
                buf.cursorLine = 0
                buf.cursorCol = 0
            } else {
                buf.cursorLine = max(0, buf.lines.count - 1)
                buf.cursorCol = buf.lines[buf.cursorLine].count
            }
        }
    }

    private func normalizedSelection() -> EditorTextRange? {
        guard let selection = self.getSelection() else { return nil }
        let start: CursorPosition
        let end: CursorPosition
        if selection.anchor.line < selection.focus.line ||
            (selection.anchor.line == selection.focus.line && selection.anchor.col <= selection.focus.col)
        {
            start = selection.anchor
            end = selection.focus
        } else {
            start = selection.focus
            end = selection.anchor
        }
        return EditorTextRange(start: start, end: end)
    }

    @discardableResult
    private func deleteSelectionIfNeeded() -> Bool {
        guard let selection = self.normalizedSelection() else { return false }
        self.buffer = self.withMutatingBuffer { buf in
            buf.deleteRange(start: selection.start, end: selection.end)
        }
        self.selectionAnchor = nil
        return true
    }

    public func invalidate() {
        // Stateless renderer; nothing cached.
    }

    @MainActor public func apply(theme: ThemePalette) {
        self.theme = theme.editor
        // If an autocomplete list is already visible, refresh its theme.
        self.autocompleteList?.theme = theme.selectList
    }
}
