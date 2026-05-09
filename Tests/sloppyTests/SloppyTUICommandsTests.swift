import Foundation
import Protocols
import TauTUI
import Testing
@testable import sloppy

@Test
func slashCommandRouterIgnoresAbsolutePaths() {
    let commandNames: Set<String> = ["help", "status"]
    let path = "/Users/vlad-prusakov/Developer/Sloppy/Sources/sloppy/TUI/SloppyTUICommands.swift"

    #expect(SloppyTUISlashCommandRouter.commandName(in: path) == "users/vlad-prusakov/developer/sloppy/sources/sloppy/tui/sloppytuicommands.swift")
    #expect(!SloppyTUISlashCommandRouter.shouldHandle(path, commandNames: commandNames, skillCommandNames: []))
}

@Test
func slashCommandRouterHandlesKnownCommandsAndAliases() {
    let commandNames: Set<String> = ["help", "add-dir", "restore", "up", "undo", "redo"]

    #expect(SloppyTUISlashCommandRouter.shouldHandle("/help", commandNames: commandNames, skillCommandNames: []))
    #expect(SloppyTUISlashCommandRouter.shouldHandle("/add-dir /tmp/demo", commandNames: commandNames, skillCommandNames: []))
    #expect(SloppyTUISlashCommandRouter.shouldHandle("/restore", commandNames: commandNames, skillCommandNames: []))
    #expect(SloppyTUISlashCommandRouter.shouldHandle("/up", commandNames: commandNames, skillCommandNames: []))
    #expect(SloppyTUISlashCommandRouter.shouldHandle("/undo", commandNames: commandNames, skillCommandNames: []))
    #expect(SloppyTUISlashCommandRouter.shouldHandle("/redo", commandNames: commandNames, skillCommandNames: []))
}

@Test
func slashCommandRouterHandlesSkillCommands() {
    let skillCommandNames: Set<String> = ["ux-pro-max"]

    #expect(SloppyTUISlashCommandRouter.shouldHandle("/ux-pro-max make it nicer", commandNames: [], skillCommandNames: skillCommandNames))
}

@Test
func codeEditorLauncherParsesConfiguredEditorCommand() {
    let command = SloppyTUICodeEditorLauncher.configuredCommandLine(environment: [
        "SLOPPY_CODE_EDITOR": "code --reuse-window",
        "VISUAL": "vim",
    ])

    #expect(command == ["code", "--reuse-window"])
}

@Test
func codeEditorLauncherSkipsTerminalEditorFallbacks() {
    let command = SloppyTUICodeEditorLauncher.configuredCommandLine(environment: [
        "VISUAL": "vim",
        "EDITOR": "nano",
    ])

    #expect(command == nil)
}

@Test
func codeEditorLauncherUsesExplicitPreferredEditor() {
    let xcodeLabels = SloppyTUICodeEditorLauncher.candidateCommandLabels(
        preferredEditor: ["xcode"],
        environment: ["SLOPPY_CODE_EDITOR": "code --reuse-window"]
    )
    let cursorLabels = SloppyTUICodeEditorLauncher.candidateCommandLabels(
        preferredEditor: ["cursor", "--reuse-window"],
        environment: [:]
    )

    #expect(xcodeLabels == ["xcode", "Xcode"])
    #expect(cursorLabels == ["cursor --reuse-window", "Cursor"])
}

@Test
func doubleEscapeDetectorInterruptsOnlyOnSecondNearbyEscape() {
    var detector = SloppyTUIDoubleEscapeDetector(interval: 0.75)
    let first = Date(timeIntervalSince1970: 100)
    let second = first.addingTimeInterval(0.4)
    let firstResult = detector.shouldInterrupt(input: TerminalInput.key(.escape), now: first, isInterruptible: true)
    let secondResult = detector.shouldInterrupt(input: TerminalInput.key(.escape), now: second, isInterruptible: true)

    #expect(!firstResult)
    #expect(secondResult)
}

@Test
func doubleEscapeDetectorIgnoresSlowOrNonInterruptibleEscapes() {
    var detector = SloppyTUIDoubleEscapeDetector(interval: 0.75)
    let first = Date(timeIntervalSince1970: 100)
    let slowSecond = first.addingTimeInterval(1.0)
    let firstResult = detector.shouldInterrupt(input: TerminalInput.key(.escape), now: first, isInterruptible: true)
    let slowResult = detector.shouldInterrupt(input: TerminalInput.key(.escape), now: slowSecond, isInterruptible: true)
    let nonInterruptibleResult = detector.shouldInterrupt(
        input: TerminalInput.key(.escape),
        now: slowSecond.addingTimeInterval(0.2),
        isInterruptible: false
    )

    #expect(!firstResult)
    #expect(!slowResult)
    #expect(!nonInterruptibleResult)
}

@Test
func doubleEscapeDetectorResetsOnOtherInput() {
    var detector = SloppyTUIDoubleEscapeDetector(interval: 0.75)
    let first = Date(timeIntervalSince1970: 100)
    let other = first.addingTimeInterval(0.2)
    let second = first.addingTimeInterval(0.4)
    let firstResult = detector.shouldInterrupt(input: TerminalInput.key(.escape), now: first, isInterruptible: true)
    let otherResult = detector.shouldInterrupt(input: TerminalInput.key(.character("a")), now: other, isInterruptible: true)
    let secondResult = detector.shouldInterrupt(input: TerminalInput.key(.escape), now: second, isInterruptible: true)

    #expect(!firstResult)
    #expect(!otherResult)
    #expect(!secondResult)
}

@Test
func controlCExitDetectorRequiresSecondNearbyPress() {
    var detector = SloppyTUIControlCExitDetector(interval: 2)
    let first = Date(timeIntervalSince1970: 100)
    let second = first.addingTimeInterval(1.5)
    let firstResult = detector.shouldExit(now: first)
    let secondResult = detector.shouldExit(now: second)

    #expect(!firstResult)
    #expect(secondResult)
}

@Test
func controlCExitDetectorIgnoresSlowOrResetPresses() {
    var detector = SloppyTUIControlCExitDetector(interval: 2)
    let first = Date(timeIntervalSince1970: 100)
    let slowSecond = first.addingTimeInterval(3)
    let afterReset = slowSecond.addingTimeInterval(1)
    let firstResult = detector.shouldExit(now: first)
    let slowResult = detector.shouldExit(now: slowSecond)

    #expect(!firstResult)
    #expect(!slowResult)

    detector.reset()
    let resetResult = detector.shouldExit(now: afterReset)
    #expect(!resetResult)
}

@Test
func pickerSearchFiltersAcrossLabelDescriptionAndGroup() {
    let items = [
        SloppyTUIPickerItem(
            value: "openrouter:anthropic/claude-sonnet",
            label: "claude-sonnet",
            description: "Claude Sonnet",
            isCurrent: false,
            group: "OpenRouter / anthropic"
        ),
        SloppyTUIPickerItem(
            value: "opencode:yteam:internal/internal-model",
            label: "internal-model",
            description: "tools",
            isCurrent: false,
            group: "OpenCode / yteam / internal"
        ),
        SloppyTUIPickerItem(
            value: "openai:gpt-5.4-mini",
            label: "gpt-5.4-mini",
            description: "reasoning",
            isCurrent: false,
            group: "OpenAI / gpt"
        ),
    ]

    let filtered = SloppyTUIPicker.filteredItems(items, query: "yteam tools")

    #expect(filtered.map(\.value) == ["opencode:yteam:internal/internal-model"])
}

@Test
func pickerSearchRestoresItemsAfterClearingQuery() {
    let items = [
        SloppyTUIPickerItem(value: "openai:gpt-5.4-mini", label: "gpt-5.4-mini", description: nil, isCurrent: false, group: "OpenAI / gpt"),
        SloppyTUIPickerItem(value: "openai:o4-mini", label: "o4-mini", description: nil, isCurrent: false, group: "OpenAI / o4"),
    ]
    var picker = SloppyTUIPicker(
        kind: .model,
        title: "Select model",
        items: items,
        selectedIndex: 0,
        allItems: items,
        supportsSearch: true
    )

    picker.setSearchQuery("o4")
    #expect(picker.items.map(\.value) == ["openai:o4-mini"])

    picker.clearSearchQuery()
    #expect(picker.items.map(\.value) == ["openai:gpt-5.4-mini", "openai:o4-mini"])
}

@Test
func launchDraftSessionIsNotPersistedSessionID() {
    let agent = AgentSummary(id: "sloppy", displayName: "SLOPPY", role: "SLOPPY")
    let session = SloppyTUIApp.makeDraftSession(agent: agent, projectID: "project-1")

    #expect(session.id == "new")
    #expect(session.agentId == "sloppy")
    #expect(session.title == "New session")
    #expect(session.projectId == "project-1")
    #expect(!session.id.hasPrefix("session-"))
}
