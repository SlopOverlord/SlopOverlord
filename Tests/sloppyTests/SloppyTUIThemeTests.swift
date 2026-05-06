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
            width: width
        ),
        SloppyTUITheme.transcriptHintLine(expanded: true, childSessionCount: 3, width: width),
    ]

    for row in rows {
        #expect(VisibleWidth.measure(row) <= width)
    }
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
