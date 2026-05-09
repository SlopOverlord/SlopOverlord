import Protocols
import Testing
import TauTUI
@testable import sloppy

@Test
func composerHighlightsSlashCommandsAndAtPaths() {
    let lines = [
        "\u{001B}[38;2;82;211;194m────────\u{001B}[39m",
        "/help /123_skill @Sources/sloppy/TUI/SloppyTUITheme.swift",
        "\u{001B}[38;2;82;211;194m────────\u{001B}[39m",
    ]

    let highlighted = SloppyTUITheme.highlightedComposerLines(lines)

    #expect(highlighted[1].contains("\u{001B}[38;2;103;232;249m"))
    #expect(highlighted[1].contains("\u{001B}[38;2;250;204;21m"))
    #expect(stripANSI(highlighted[1]) == lines[1])
}

@Test
func composerHighlightsPasteMarkersAndTaskReferences() {
    let lines = [
        "\u{001B}[38;2;82;211;194m────────\u{001B}[39m",
        "Please inspect [paste #1 +12 lines] for #task-123",
        "\u{001B}[38;2;82;211;194m────────\u{001B}[39m",
    ]

    let highlighted = SloppyTUITheme.highlightedComposerLines(lines)

    #expect(highlighted[1].contains("\u{001B}[38;2;251;178;123m"))
    #expect(highlighted[1].contains("\u{001B}[38;2;74;222;128m"))
    #expect(stripANSI(highlighted[1]) == lines[1])
}

@Test
func composerDoesNotHighlightAutocompleteAfterEditorBorder() {
    let lines = [
        "\u{001B}[38;2;82;211;194m────────\u{001B}[39m",
        "/help",
        "\u{001B}[38;2;82;211;194m────────\u{001B}[39m",
        "/model  Switch model",
    ]

    let highlighted = SloppyTUITheme.highlightedComposerLines(lines)

    #expect(highlighted[1].contains("\u{001B}[38;2;103;232;249m"))
    #expect(highlighted[3] == lines[3])
}

@Test
func userMessageHighlightsTaskReferences() {
    let lines = SloppyTUITheme.userMessageLines("Handle #task-123 with @Sources/sloppy/TUI", width: 80)
    let rendered = lines.joined(separator: "\n")

    #expect(rendered.contains("\u{001B}[38;2;74;222;128m"))
    #expect(rendered.contains("\u{001B}[38;2;250;204;21m"))
}

@Test
func normalizeTruncatesOverwideStyledLines() {
    let width = 32
    let line = "\u{001B}[38;2;250;204;21m" + String(repeating: "x", count: 96) + "\u{001B}[39m"

    let normalized = SloppyTUITheme.normalize(lines: [line], width: width, height: 1)

    #expect(normalized.count == 1)
    #expect(VisibleWidth.measure(normalized[0]) == width)
}

@Test
func chromeRowsFitNarrowTerminalWidth() {
    let width = 40
    let rows = [
        SloppyTUITheme.composerMetaLine(
            width: width,
            mode: .plan,
            model: "anthropic:claude-sonnet-4-6",
            agent: "Yadev",
            provider: "anthropic"
        ),
        SloppyTUITheme.interruptControlLine(width: width, frame: 3, isInterrupting: false),
        SloppyTUITheme.tokenUsageStatus(.init(
            promptTokens: 22_000,
            completionTokens: 13_000,
            totalTokens: 35_000,
            contextWindowTokens: 400_000,
            costUSD: 0.42
        )),
        SloppyTUITheme.toolCallLine(
            tool: "runtime.exec",
            reason: String(repeating: "reason", count: 12),
            summary: String(repeating: "/Users/vlad-prusakov/Developer/Sloppy/", count: 4),
            width: width
        ),
        SloppyTUITheme.toolResultLine(
            tool: "runtime.exec",
            ok: false,
            error: String(repeating: "Rendered line exceeds width ", count: 6),
            durationMs: 123,
            width: width
        ),
        SloppyTUITheme.attachmentLine(
            name: String(repeating: "screenshot-", count: 10) + ".png",
            mimeType: "image/png",
            sizeBytes: 12_345,
            width: width
        ),
        SloppyTUITheme.toolOverflowLine(hiddenCount: 42, width: width),
        SloppyTUITheme.subSessionLine(
            title: String(repeating: "subagent-session-", count: 6),
            childSessionId: String(repeating: "abcdef", count: 6),
            status: .running("Reading files"),
            frame: 0,
            width: width
        ),
        SloppyTUITheme.transcriptHintLine(expanded: true, childSessionCount: 3, width: width),
    ]

    for row in rows {
        #expect(VisibleWidth.measure(row) <= width)
    }
}

@Test
func backgroundBlocksIncludeBreathingRoom() {
    let width = 40
    let lines = SloppyTUITheme.userMessageLines("hello", width: width)

    #expect(lines.count == 3)
    #expect(stripANSI(lines[0]).trimmingCharacters(in: .whitespaces).isEmpty)
    #expect(stripANSI(lines[1]).hasPrefix("  › hello"))
    #expect(stripANSI(lines[2]).trimmingCharacters(in: .whitespaces).isEmpty)

    for line in lines {
        #expect(VisibleWidth.measure(line) <= width)
    }
}

@Test
func buildProgressRendersStructuredWrappedLines() {
    let width = 56
    let progress = AgentBuildProgressEvent(
        title: "Project picker UI changes",
        items: [
            AgentBuildProgressItem(
                id: "inspect",
                title: "Inspect project structure and current project picker UI",
                status: .done,
                definitionOfDone: "Locate relevant window/view code, tests, and build commands.",
                details: "Found ProjectOpeningView and layout tests."
            ),
            AgentBuildProgressItem(
                id: "verify",
                title: "Verify",
                status: .inProgress,
                definitionOfDone: "Run smallest relevant tests and final project build successfully."
            ),
        ]
    )

    let lines = SloppyTUITheme.buildProgressLines(progress, width: width)
    let plain = lines.map(stripANSI)

    #expect(plain[0].trimmingCharacters(in: .whitespaces) == "Project picker UI changes")
    #expect(plain.contains { $0.hasPrefix("  [x] Inspect project structure") })
    #expect(plain.contains { $0.hasPrefix("      ") && $0.contains("UI") })
    #expect(plain.contains { $0.hasPrefix("      DoD: Locate relevant") })
    #expect(plain.contains { $0.hasPrefix("      Notes: Found ProjectOpeningView") })
    #expect(plain.contains { $0.hasPrefix("  [~] Verify") })
    #expect(!plain.joined(separator: "\n").contains("UI - DoD:"))

    for line in lines {
        #expect(VisibleWidth.measure(line) <= width)
    }
}

@Test
func buildProgressColorsItemsByStatus() {
    let progress = AgentBuildProgressEvent(
        title: "Build progress",
        items: [
            AgentBuildProgressItem(id: "done", title: "Done item", status: .done, definitionOfDone: "Complete."),
            AgentBuildProgressItem(id: "active", title: "Active item", status: .inProgress, definitionOfDone: "Working."),
            AgentBuildProgressItem(id: "pending", title: "Pending item", status: .pending, definitionOfDone: "Queued."),
        ]
    )

    let rendered = SloppyTUITheme.buildProgressLines(progress, width: 80).joined(separator: "\n")

    #expect(rendered.contains("\u{001B}[38;2;74;222;128m"))
    #expect(rendered.contains("\u{001B}[38;2;251;178;123m"))
    #expect(rendered.contains("\u{001B}[38;2;148;163;184m"))
}

@Test
func welcomeScreenShowsSingleTip() {
    let lines = SloppyTUITheme.welcomeScreen(
        width: 120,
        cwd: "/Users/vlad-prusakov/Developer/Sloppy",
        project: "Sloppy",
        agent: "sloppy",
        model: "openai:gpt-5-codex-mini",
        mode: .build,
        includeFooter: false
    )

    let tipLines = lines.filter { stripANSI($0).contains("Tip  ") }

    #expect(tipLines.count == 1)
}

@Test
func welcomeIntroBlockIsCenteredUnderLogo() throws {
    let width = 120
    let lines = SloppyTUITheme.welcomeScreen(
        width: width,
        cwd: "/Users/vlad-prusakov/Developer/Sloppy",
        project: "Sloppy",
        agent: "sloppy",
        model: "openai:gpt-5-codex-mini",
        mode: .build,
        includeFooter: false
    )

    let promptLine = try #require(lines.first { stripANSI($0).contains("Ask anything") })

    #expect(leadingSpaceCount(stripANSI(promptLine)) == 28)
}

@Test
func elapsedFormatsShortAndLongRuns() {
    #expect(SloppyTUITheme.elapsed(0) == "00:00")
    #expect(SloppyTUITheme.elapsed(65) == "01:05")
    #expect(SloppyTUITheme.elapsed(3_661) == "1:01:01")
}

@Test
func sessionDisplayTitleUsesPreviewForDefaultDashboardStyleTitles() {
    let session = AgentSessionSummary(
        id: "session-abcdef123456",
        agentId: "sloppy",
        title: "Session session-",
        messageCount: 2,
        lastMessagePreview: "Refactor the TUI session header"
    )

    #expect(SloppyTUITheme.sessionDisplayTitle(session) == "Refactor the TUI session header")
    #expect(SloppyTUITheme.sessionHeaderTitle(session).contains("Refactor the TUI session header"))
}

@Test
func sessionDisplayTitleUsesPreviewForLegacyTUIChatTitles() {
    let session = AgentSessionSummary(
        id: "session-abcdef123456",
        agentId: "sloppy",
        title: "TUI chat",
        messageCount: 2,
        lastMessagePreview: "Investigate absolute path submission"
    )

    #expect(SloppyTUITheme.sessionDisplayTitle(session) == "Investigate absolute path submission")
}

@Test
func sessionDisplayTitleKeepsSpecificTitles() {
    let session = AgentSessionSummary(
        id: "session-abcdef123456",
        agentId: "sloppy",
        title: "Fork: improve project overlay",
        messageCount: 2,
        lastMessagePreview: "Something else"
    )

    #expect(SloppyTUITheme.sessionDisplayTitle(session) == "Fork: improve project overlay")
}

private func leadingSpaceCount(_ line: String) -> Int {
    line.prefix { $0 == " " }.count
}

private func stripANSI(_ line: String) -> String {
    var result = ""
    var index = line.startIndex
    while index < line.endIndex {
        if line[index] == "\u{001B}" {
            index = ansiEscapeEnd(in: line, from: index)
            continue
        }
        result.append(line[index])
        index = line.index(after: index)
    }
    return result
}

private func ansiEscapeEnd(in line: String, from start: String.Index) -> String.Index {
    let next = line.index(after: start)
    guard next < line.endIndex else {
        return next
    }

    if line[next] == "[" {
        var index = line.index(after: next)
        while index < line.endIndex {
            let scalar = line[index].unicodeScalars.first?.value ?? 0
            index = line.index(after: index)
            if scalar >= 0x40 && scalar <= 0x7E {
                return index
            }
        }
        return line.endIndex
    }

    return line.index(after: next)
}
