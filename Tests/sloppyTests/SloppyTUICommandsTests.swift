import Foundation
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
    let commandNames: Set<String> = ["help", "add-dir", "undo", "redo"]

    #expect(SloppyTUISlashCommandRouter.shouldHandle("/help", commandNames: commandNames, skillCommandNames: []))
    #expect(SloppyTUISlashCommandRouter.shouldHandle("/add-dir /tmp/demo", commandNames: commandNames, skillCommandNames: []))
    #expect(SloppyTUISlashCommandRouter.shouldHandle("/undo", commandNames: commandNames, skillCommandNames: []))
    #expect(SloppyTUISlashCommandRouter.shouldHandle("/redo", commandNames: commandNames, skillCommandNames: []))
}

@Test
func slashCommandRouterHandlesSkillCommands() {
    let skillCommandNames: Set<String> = ["ux-pro-max"]

    #expect(SloppyTUISlashCommandRouter.shouldHandle("/ux-pro-max make it nicer", commandNames: [], skillCommandNames: skillCommandNames))
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
