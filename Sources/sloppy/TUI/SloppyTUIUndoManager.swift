import Foundation

struct SloppyTUIUndoManager {
    enum ApplyDirection: Equatable {
        case undo
        case redo
    }

    struct Baseline {
        var rootURL: URL
        fileprivate var fingerprints: [String: FileFingerprint]
        fileprivate var contents: [String: Data]
    }

    struct ApplyResult: Equatable {
        var direction: ApplyDirection
        var paths: [String]
    }

    enum RecordResult: Equatable {
        case recorded(paths: [String])
        case noChanges
        case skipped(String)
    }

    enum Error: LocalizedError, Equatable {
        case nothingToUndo
        case nothingToRedo
        case conflict(path: String)
        case oversized(path: String, bytes: Int)
        case filesystem(String)

        var errorDescription: String? {
            switch self {
            case .nothingToUndo:
                return "Nothing to undo."
            case .nothingToRedo:
                return "Nothing to redo."
            case .conflict(let path):
                return "Cannot apply because `\(path)` changed since the undo point was recorded."
            case .oversized(let path, let bytes):
                return "`\(path)` is too large for TUI undo history (\(bytes) bytes)."
            case .filesystem(let message):
                return message
            }
        }
    }

    static let maxHistoryDepth = 20
    static let maxFileBytes = 5 * 1024 * 1024
    static let maxTurnBytes = 25 * 1024 * 1024
    static let maxBaselineBytes = 25 * 1024 * 1024

    private var undoStack: [Transaction] = []
    private var redoStack: [Transaction] = []
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func makeBaseline(rootURL: URL) -> Baseline {
        let root = rootURL.standardizedFileURL
        let fingerprints = scanFingerprints(rootURL: root)
        var contents: [String: Data] = [:]
        var capturedBytes = 0

        for path in fingerprints.keys.sorted() {
            let fileURL = root.appendingPathComponent(path)
            guard let size = fingerprints[path]?.sizeBytes,
                  size <= Self.maxFileBytes,
                  capturedBytes + size <= Self.maxBaselineBytes,
                  let data = try? Data(contentsOf: fileURL)
            else {
                continue
            }
            contents[path] = data
            capturedBytes += data.count
        }

        return Baseline(rootURL: root, fingerprints: fingerprints, contents: contents)
    }

    mutating func recordChanges(rootURL: URL, baseline: Baseline) -> RecordResult {
        let root = rootURL.standardizedFileURL
        let current = scanFingerprints(rootURL: root)
        var candidatePathSet = Set(baseline.fingerprints.keys)
            .union(current.keys)
            .filter { baseline.fingerprints[$0] != current[$0] }

        for (path, beforeData) in baseline.contents where current[path] != nil && !candidatePathSet.contains(path) {
            let fileURL = root.appendingPathComponent(path)
            if let currentData = try? Data(contentsOf: fileURL), currentData != beforeData {
                candidatePathSet.insert(path)
            }
        }

        let candidatePaths = candidatePathSet.sorted()

        guard !candidatePaths.isEmpty else {
            return .noChanges
        }

        var before: [String: FileState] = [:]
        var after: [String: FileState] = [:]
        var recordedPaths: [String] = []
        var totalBytes = 0

        for path in candidatePaths {
            let beforeState: FileState
            if baseline.fingerprints[path] == nil {
                beforeState = .missing
            } else if let data = baseline.contents[path] {
                beforeState = .file(data)
            } else {
                return .skipped("Undo history skipped because `\(path)` was not captured before the turn. Files above 5 MiB and snapshots beyond 25 MiB are not recorded.")
            }

            let afterState: FileState
            do {
                afterState = try readState(rootURL: root, path: path)
            } catch let error as Error {
                return .skipped(error.localizedDescription)
            } catch {
                return .skipped(String(describing: error))
            }

            guard beforeState != afterState else {
                continue
            }

            totalBytes += beforeState.byteCount + afterState.byteCount
            guard totalBytes <= Self.maxTurnBytes else {
                return .skipped("Undo history skipped because this turn changed more than 25 MiB.")
            }

            before[path] = beforeState
            after[path] = afterState
            recordedPaths.append(path)
        }

        guard !recordedPaths.isEmpty else {
            return .noChanges
        }

        undoStack.append(Transaction(paths: recordedPaths, before: before, after: after))
        if undoStack.count > Self.maxHistoryDepth {
            undoStack.removeFirst(undoStack.count - Self.maxHistoryDepth)
        }
        redoStack.removeAll(keepingCapacity: true)
        return .recorded(paths: recordedPaths)
    }

    mutating func undo(rootURL: URL) throws -> ApplyResult {
        guard let transaction = undoStack.last else {
            throw Error.nothingToUndo
        }
        let root = rootURL.standardizedFileURL
        try validate(transaction.after, rootURL: root)
        try apply(transaction.before, rootURL: root)
        undoStack.removeLast()
        redoStack.append(transaction)
        return ApplyResult(direction: .undo, paths: transaction.paths)
    }

    mutating func redo(rootURL: URL) throws -> ApplyResult {
        guard let transaction = redoStack.last else {
            throw Error.nothingToRedo
        }
        let root = rootURL.standardizedFileURL
        try validate(transaction.before, rootURL: root)
        try apply(transaction.after, rootURL: root)
        redoStack.removeLast()
        undoStack.append(transaction)
        return ApplyResult(direction: .redo, paths: transaction.paths)
    }

    private func scanFingerprints(rootURL: URL) -> [String: FileFingerprint] {
        var result: [String: FileFingerprint] = [:]
        walk(directoryURL: rootURL, relativeDirectory: "", result: &result)
        return result
    }

    private func walk(directoryURL: URL, relativeDirectory: String, result: inout [String: FileFingerprint]) {
        let urls = (try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: []
        )) ?? []

        for url in urls {
            let name = url.lastPathComponent
            let relativePath = relativeDirectory.isEmpty ? name : "\(relativeDirectory)/\(name)"
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            if values?.isDirectory == true {
                guard !Self.excludedDirectoryNames.contains(name) else {
                    continue
                }
                walk(directoryURL: url, relativeDirectory: relativePath, result: &result)
            } else {
                result[relativePath] = FileFingerprint(
                    sizeBytes: values?.fileSize ?? 0,
                    modifiedAt: values?.contentModificationDate
                )
            }
        }
    }

    private func readState(rootURL: URL, path: String) throws -> FileState {
        let fileURL = rootURL.appendingPathComponent(path)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return .missing
        }

        let values = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        guard values.isDirectory != true else {
            throw Error.conflict(path: path)
        }
        let size = values.fileSize ?? 0
        guard size <= Self.maxFileBytes else {
            throw Error.oversized(path: path, bytes: size)
        }
        return .file(try Data(contentsOf: fileURL))
    }

    private func validate(_ expected: [String: FileState], rootURL: URL) throws {
        for path in expected.keys.sorted() {
            guard let expectedState = expected[path],
                  try readState(rootURL: rootURL, path: path) == expectedState
            else {
                throw Error.conflict(path: path)
            }
        }
    }

    private func apply(_ states: [String: FileState], rootURL: URL) throws {
        for path in states.keys.sorted() {
            guard let state = states[path] else {
                continue
            }
            let fileURL = rootURL.appendingPathComponent(path)
            do {
                switch state {
                case .missing:
                    if fileManager.fileExists(atPath: fileURL.path) {
                        try fileManager.removeItem(at: fileURL)
                    }
                case .file(let data):
                    try fileManager.createDirectory(
                        at: fileURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try data.write(to: fileURL, options: .atomic)
                }
            } catch {
                throw Error.filesystem(error.localizedDescription)
            }
        }
    }

    private static let excludedDirectoryNames: Set<String> = [
        ".git",
        ".sloppy",
        ".sloppy-worktrees",
        ".build",
        "node_modules",
        "dist",
        "DerivedData",
    ]
}

private struct Transaction: Equatable {
    var paths: [String]
    var before: [String: FileState]
    var after: [String: FileState]
}

private enum FileState: Equatable {
    case missing
    case file(Data)

    var byteCount: Int {
        switch self {
        case .missing:
            return 0
        case .file(let data):
            return data.count
        }
    }
}

private struct FileFingerprint: Equatable {
    var sizeBytes: Int
    var modifiedAt: Date?
}
