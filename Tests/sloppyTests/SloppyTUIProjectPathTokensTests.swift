import Foundation
import Testing
import TauTUI
@testable import sloppy

@Test
func projectPathTokenStopsAfterUnescapedSpace() {
    let token = SloppyTUIProjectPathTokens.tokenBeforeCursor(
        lines: ["please inspect @Sources/App.swift now"],
        cursorLine: 0,
        cursorColumn: "please inspect @Sources/App.swift now".count
    )

    #expect(token == nil)
}

@Test
func projectPathTokenKeepsBackslashEscapedSpace() throws {
    let line = "please inspect @Android\\ Studio/Main.swift"
    let token = try #require(SloppyTUIProjectPathTokens.tokenBeforeCursor(
        lines: [line],
        cursorLine: 0,
        cursorColumn: line.count
    ))

    #expect(token.rawToken == "@Android\\ Studio/Main.swift")
    #expect(token.path == "Android Studio/Main.swift")
}

@Test
func projectPathTokenKeepsSpaceBeforeBackslash() throws {
    let line = "please inspect @Android \\Studio/Main.swift"
    let token = try #require(SloppyTUIProjectPathTokens.tokenBeforeCursor(
        lines: [line],
        cursorLine: 0,
        cursorColumn: line.count
    ))

    #expect(token.rawToken == "@Android \\Studio/Main.swift")
    #expect(token.path == "Android Studio/Main.swift")
}

@Test
func projectPathTokenExtractorFindsEscapedAttachmentPaths() {
    let paths = SloppyTUIProjectPathTokens.attachmentPaths(
        in: "read @Android\\ Studio/Main.swift and @Sources/App.swift done"
    )

    #expect(paths == ["Android Studio/Main.swift", "Sources/App.swift"])
}

@Test
func tuiAutocompleteIgnoresEscapedSpaceAttachmentTokens() throws {
    let root = try temporaryAutocompleteRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("Android Studio", isDirectory: true),
        withIntermediateDirectories: true
    )
    try Data("swift".utf8).write(to: root.appendingPathComponent("Android Studio/Main.swift"))

    let provider = SloppyTUIAutocompleteProvider(basePath: root.path)
    let line = "inspect @Android\\ Studio/M"
    let suggestion = provider.getSuggestions(
        lines: [line],
        cursorLine: 0,
        cursorCol: line.count
    )

    #expect(suggestion == nil)
}

@Test
func tuiAutocompleteEscapesAttachmentCompletionSpaces() throws {
    let root = try temporaryAutocompleteRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let provider = SloppyTUIAutocompleteProvider(basePath: root.path)
    let result = provider.applyCompletion(
        lines: ["inspect @Android\\ S"],
        cursorLine: 0,
        cursorCol: "inspect @Android\\ S".count,
        item: AutocompleteItem(
            value: "Android Studio/Main.swift",
            label: "Main.swift"
        ),
        prefix: "@Android\\ S"
    )

    #expect(result.lines == ["inspect @Android\\ Studio/Main.swift "])
    #expect(result.cursorLine == 0)
    #expect(result.cursorCol == "inspect @Android\\ Studio/Main.swift ".count)
}

@Test
func projectPathSearchSuppressionSurvivesTypingInsideSameToken() throws {
    let original = try #require(SloppyTUIProjectPathTokens.tokenBeforeCursor(
        lines: ["inspect @Classes/SharedComponents"],
        cursorLine: 0,
        cursorColumn: "inspect @Classes/SharedComponents".count
    ))
    let suppression = SloppyTUIProjectPathSearchSuppression(token: original)

    let extended = SloppyTUIProjectPathTokens.tokenBeforeCursor(
        lines: ["inspect @Classes/SharedComponentsx"],
        cursorLine: 0,
        cursorColumn: "inspect @Classes/SharedComponentsx".count
    )
    let shortened = SloppyTUIProjectPathTokens.tokenBeforeCursor(
        lines: ["inspect @Classes/Shared"],
        cursorLine: 0,
        cursorColumn: "inspect @Classes/Shared".count
    )
    let closed = SloppyTUIProjectPathTokens.tokenBeforeCursor(
        lines: ["inspect @Classes/SharedComponents done"],
        cursorLine: 0,
        cursorColumn: "inspect @Classes/SharedComponents done".count
    )
    let differentToken = SloppyTUIProjectPathTokens.tokenBeforeCursor(
        lines: ["inspect @Classes/SharedComponents and @Sources/App.swift"],
        cursorLine: 0,
        cursorColumn: "inspect @Classes/SharedComponents and @Sources/App.swift".count
    )

    #expect(suppression.matches(extended))
    #expect(suppression.matches(shortened))
    #expect(!suppression.matches(closed))
    #expect(!suppression.matches(differentToken))
}

private func temporaryAutocompleteRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("sloppy-tui-autocomplete-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
