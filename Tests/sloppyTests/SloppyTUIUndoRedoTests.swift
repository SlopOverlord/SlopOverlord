import Foundation
import Testing
@testable import sloppy

@Test
func tuiUndoRedoRestoresModifiedFile() throws {
    let root = try makeUndoRedoRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fileURL = root.appendingPathComponent("note.txt")
    try Data("before".utf8).write(to: fileURL)

    var manager = SloppyTUIUndoManager()
    let baseline = manager.makeBaseline(rootURL: root)
    try Data("after".utf8).write(to: fileURL)

    #expect(manager.recordChanges(rootURL: root, baseline: baseline) == .recorded(paths: ["note.txt"]))
    #expect(try manager.undo(rootURL: root).paths == ["note.txt"])
    #expect(try String(contentsOf: fileURL, encoding: .utf8) == "before")
    #expect(try manager.redo(rootURL: root).paths == ["note.txt"])
    #expect(try String(contentsOf: fileURL, encoding: .utf8) == "after")
}

@Test
func tuiUndoRedoRestoresCreatedFile() throws {
    let root = try makeUndoRedoRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fileURL = root.appendingPathComponent("created.bin")

    var manager = SloppyTUIUndoManager()
    let baseline = manager.makeBaseline(rootURL: root)
    try Data([0, 1, 2, 3]).write(to: fileURL)

    #expect(manager.recordChanges(rootURL: root, baseline: baseline) == .recorded(paths: ["created.bin"]))
    _ = try manager.undo(rootURL: root)
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    _ = try manager.redo(rootURL: root)
    #expect(try Data(contentsOf: fileURL) == Data([0, 1, 2, 3]))
}

@Test
func tuiUndoRedoRestoresDeletedFile() throws {
    let root = try makeUndoRedoRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fileURL = root.appendingPathComponent("deleted.txt")
    try Data("keep me".utf8).write(to: fileURL)

    var manager = SloppyTUIUndoManager()
    let baseline = manager.makeBaseline(rootURL: root)
    try FileManager.default.removeItem(at: fileURL)

    #expect(manager.recordChanges(rootURL: root, baseline: baseline) == .recorded(paths: ["deleted.txt"]))
    _ = try manager.undo(rootURL: root)
    #expect(try String(contentsOf: fileURL, encoding: .utf8) == "keep me")
    _ = try manager.redo(rootURL: root)
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
}

@Test
func tuiUndoRedoClearsRedoAfterNewRecordedTurn() throws {
    let root = try makeUndoRedoRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fileURL = root.appendingPathComponent("note.txt")
    try Data("one".utf8).write(to: fileURL)

    var manager = SloppyTUIUndoManager()
    var baseline = manager.makeBaseline(rootURL: root)
    try Data("two".utf8).write(to: fileURL)
    _ = manager.recordChanges(rootURL: root, baseline: baseline)
    _ = try manager.undo(rootURL: root)
    #expect(manager.canRedo)

    baseline = manager.makeBaseline(rootURL: root)
    try Data("three".utf8).write(to: fileURL)
    _ = manager.recordChanges(rootURL: root, baseline: baseline)

    #expect(!manager.canRedo)
}

@Test
func tuiUndoRedoRefusesWhenCurrentFileConflicts() throws {
    let root = try makeUndoRedoRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fileURL = root.appendingPathComponent("note.txt")
    try Data("before".utf8).write(to: fileURL)

    var manager = SloppyTUIUndoManager()
    let baseline = manager.makeBaseline(rootURL: root)
    try Data("after".utf8).write(to: fileURL)
    _ = manager.recordChanges(rootURL: root, baseline: baseline)
    try Data("manual".utf8).write(to: fileURL)

    #expect(throws: SloppyTUIUndoManager.Error.conflict(path: "note.txt")) {
        _ = try manager.undo(rootURL: root)
    }
    #expect(try String(contentsOf: fileURL, encoding: .utf8) == "manual")
}

@Test
func tuiUndoRedoSkipsOversizedChangedFile() throws {
    let root = try makeUndoRedoRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fileURL = root.appendingPathComponent("large.bin")
    try Data("small".utf8).write(to: fileURL)

    var manager = SloppyTUIUndoManager()
    let baseline = manager.makeBaseline(rootURL: root)
    try Data(repeating: 7, count: SloppyTUIUndoManager.maxFileBytes + 1).write(to: fileURL)

    let result = manager.recordChanges(rootURL: root, baseline: baseline)
    guard case .skipped(let message) = result else {
        Issue.record("Expected oversized change to be skipped, got \(result)")
        return
    }
    #expect(message.contains("large.bin"))
    #expect(!manager.canUndo)
}

private func makeUndoRedoRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("sloppy-tui-undo-redo-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
