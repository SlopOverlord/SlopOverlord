import Foundation

enum SloppyTUIProjectPathTokens {
    struct Token: Equatable {
        var rawToken: String
        var path: String
        var line: Int
        var startColumn: Int
        var endColumn: Int
    }

    static func tokenBeforeCursor(lines: [String], cursorLine: Int, cursorColumn: Int) -> Token? {
        guard lines.indices.contains(cursorLine) else {
            return nil
        }
        let line = lines[cursorLine]
        let endColumn = min(cursorColumn, line.count)
        let end = line.index(line.startIndex, offsetBy: endColumn)
        return tokens(in: line, lineNumber: cursorLine, end: end, includeClosedTokens: false).last
    }

    static func attachmentPaths(in text: String) -> [String] {
        text
            .components(separatedBy: "\n")
            .enumerated()
            .flatMap { lineNumber, line in
                tokens(in: line, lineNumber: lineNumber, end: line.endIndex, includeClosedTokens: true).map(\.path)
            }
    }

    static func escapedTokenValue(_ path: String) -> String {
        var result = ""
        for character in path {
            if character == "\\" || character.isWhitespace {
                result.append("\\")
            }
            result.append(character)
        }
        return result
    }

    private static func tokens(
        in line: String,
        lineNumber: Int,
        end: String.Index,
        includeClosedTokens: Bool
    ) -> [Token] {
        var result: [Token] = []
        var tokenStart: String.Index?
        var index = line.startIndex

        while index < end {
            let character = line[index]
            if let start = tokenStart {
                if character.isWhitespace, !isEscapedTokenWhitespace(in: line, at: index, end: end) {
                    if includeClosedTokens {
                        appendToken(in: line, lineNumber: lineNumber, start: start, end: index, to: &result)
                    }
                    tokenStart = nil
                }
            } else if character == "@" {
                tokenStart = index
            }
            index = line.index(after: index)
        }

        if let start = tokenStart {
            appendToken(in: line, lineNumber: lineNumber, start: start, end: end, to: &result)
        }
        return result
    }

    private static func appendToken(
        in line: String,
        lineNumber: Int,
        start: String.Index,
        end: String.Index,
        to result: inout [Token]
    ) {
        let rawToken = String(line[start..<end])
        guard rawToken.hasPrefix("@"), rawToken.count > 1 else {
            return
        }
        result.append(Token(
            rawToken: rawToken,
            path: unescapedPath(String(rawToken.dropFirst())),
            line: lineNumber,
            startColumn: line.distance(from: line.startIndex, to: start),
            endColumn: line.distance(from: line.startIndex, to: end)
        ))
    }

    private static func isEscapedTokenWhitespace(in line: String, at index: String.Index, end: String.Index) -> Bool {
        if hasOddBackslashRunBefore(index, in: line) {
            return true
        }
        let next = line.index(after: index)
        return next < end && line[next] == "\\"
    }

    private static func hasOddBackslashRunBefore(_ index: String.Index, in line: String) -> Bool {
        var count = 0
        var cursor = index
        while cursor > line.startIndex {
            let previous = line.index(before: cursor)
            guard line[previous] == "\\" else {
                break
            }
            count += 1
            cursor = previous
        }
        return count % 2 == 1
    }

    private static func unescapedPath(_ raw: String) -> String {
        var result = ""
        var index = raw.startIndex
        while index < raw.endIndex {
            let character = raw[index]
            if character == "\\" {
                let next = raw.index(after: index)
                guard next < raw.endIndex else {
                    result.append(character)
                    index = next
                    continue
                }

                let nextCharacter = raw[next]
                if nextCharacter.isWhitespace || nextCharacter == "\\" {
                    result.append(nextCharacter)
                    index = raw.index(after: next)
                    continue
                }
                if result.last?.isWhitespace == true {
                    index = next
                    continue
                }
            }
            result.append(character)
            index = raw.index(after: index)
        }
        return result
    }
}

struct SloppyTUIProjectPathSearchSuppression: Equatable {
    var rawToken: String
    var line: Int
    var startColumn: Int

    init(token: SloppyTUIProjectPathTokens.Token) {
        self.rawToken = token.rawToken
        self.line = token.line
        self.startColumn = token.startColumn
    }

    init(rawToken: String, line: Int, startColumn: Int) {
        self.rawToken = rawToken
        self.line = line
        self.startColumn = startColumn
    }

    func matches(_ token: SloppyTUIProjectPathTokens.Token?) -> Bool {
        guard let token,
              token.line == line,
              token.startColumn == startColumn
        else {
            return false
        }

        return token.rawToken.hasPrefix(rawToken) || rawToken.hasPrefix(token.rawToken)
    }
}
