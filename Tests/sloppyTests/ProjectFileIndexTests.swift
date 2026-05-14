import Foundation
import Testing
@testable import sloppy
@testable import Protocols

private func temporaryIndexRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("sloppy-file-index-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test
func projectFileIndexBuildsFilesAndDirectoriesAndSkipsExcludedDirectories() throws {
    let root = try temporaryIndexRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let src = root.appendingPathComponent("src", isDirectory: true)
    try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
    try Data("main".utf8).write(to: src.appendingPathComponent("AppMain.swift"))
    let build = root.appendingPathComponent(".build", isDirectory: true)
    try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
    try Data("hidden".utf8).write(to: build.appendingPathComponent("Generated.swift"))

    let index = ProjectFileIndex.build(projectId: "p1", rootURL: root)
    #expect(index.entries.contains(ProjectFileIndexEntry(path: "src", type: .directory)))
    #expect(index.entries.contains(ProjectFileIndexEntry(path: "src/AppMain.swift", type: .file)))
    #expect(!index.entries.contains { $0.path.hasPrefix(".build") })
}

@Test
func projectFileIndexCacheRoundTripsAndRejectsMismatches() throws {
    let workspace = try temporaryIndexRoot()
    defer { try? FileManager.default.removeItem(at: workspace) }

    let index = ProjectFileIndex(
        projectId: "project-a",
        rootPath: "/tmp/project-a",
        entries: [ProjectFileIndexEntry(path: "README.md", type: .file)]
    )
    let store = ProjectFileIndexStore(workspaceRoot: workspace)
    store.save(index)

    let loaded = try #require(store.load(projectId: "project-a", rootPath: "/tmp/project-a"))
    #expect(loaded.projectId == index.projectId)
    #expect(loaded.rootPath == index.rootPath)
    #expect(loaded.entries == index.entries)
    #expect(store.load(projectId: "project-a", rootPath: "/tmp/other") == nil)

    var stale = index
    stale.version = ProjectFileIndex.version + 1
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let staleData = try encoder.encode(stale)
    try staleData.write(to: store.cacheURL(projectId: "project-a"), options: .atomic)
    #expect(store.load(projectId: "project-a", rootPath: "/tmp/project-a") == nil)
}

@Test
func projectFileIndexSearchFindsRecursivePathsAndRanksBasenamePrefix() throws {
    let index = ProjectFileIndex(
        projectId: "p1",
        rootPath: "/tmp/p1",
        entries: [
            ProjectFileIndexEntry(path: "docs/domain.txt", type: .file),
            ProjectFileIndexEntry(path: "src/AppMain.swift", type: .file),
            ProjectFileIndexEntry(path: "src/main", type: .directory),
        ]
    )

    let main = index.search("main", limit: 10)
    #expect(main.map(\.path).contains("src/AppMain.swift"))
    #expect(main.first?.path == "src/main")

    let limited = index.search("main", limit: 1)
    #expect(limited.count == 1)
}

@Test
func projectFileIndexBuildsAdditionalRootsAsAbsolutePaths() throws {
    let root = try temporaryIndexRoot()
    let extra = try temporaryIndexRoot()
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: extra)
    }

    try Data("root".utf8).write(to: root.appendingPathComponent("README.md"))
    try Data("extra".utf8).write(to: extra.appendingPathComponent("Notes.md"))

    let index = ProjectFileIndex.build(projectId: "p1", rootURL: root, additionalRootURLs: [extra])

    #expect(index.entries.contains(ProjectFileIndexEntry(path: "README.md", type: .file)))
    #expect(index.entries.contains(ProjectFileIndexEntry(path: extra.appendingPathComponent("Notes.md").path, type: .file)))
    #expect(index.search("Notes", limit: 10).contains(ProjectFileIndexEntry(path: extra.appendingPathComponent("Notes.md").path, type: .file)))
}

@Test
func projectFileIndexSearchDirectoryQueryReturnsDirectoryAndDescendants() throws {
    let index = ProjectFileIndex(
        projectId: "p1",
        rootPath: "/tmp/p1",
        entries: [
            ProjectFileIndexEntry(path: "src", type: .directory),
            ProjectFileIndexEntry(path: "src/AppMain.swift", type: .file),
            ProjectFileIndexEntry(path: "src/Nested/Helper.swift", type: .file),
            ProjectFileIndexEntry(path: "Tests/AppMainTests.swift", type: .file),
        ]
    )

    let results = index.search("src/", limit: 10)
    #expect(results.first == ProjectFileIndexEntry(path: "src", type: .directory))
    #expect(results.contains(ProjectFileIndexEntry(path: "src/AppMain.swift", type: .file)))
    #expect(!results.contains(ProjectFileIndexEntry(path: "Tests/AppMainTests.swift", type: .file)))
}

@Test
func projectFileIndexCompletionSearchReturnsDirectChildrenForPathPrefixes() throws {
    let index = ProjectFileIndex(
        projectId: "p1",
        rootPath: "/tmp/p1",
        entries: [
            ProjectFileIndexEntry(path: "src", type: .directory),
            ProjectFileIndexEntry(path: "src/AppMain.swift", type: .file),
            ProjectFileIndexEntry(path: "src/Nested", type: .directory),
            ProjectFileIndexEntry(path: "src/Nested/Helper.swift", type: .file),
            ProjectFileIndexEntry(path: "Tests/AppMainTests.swift", type: .file),
        ]
    )

    let srcChildren = index.completionSearch("src/", limit: 10).map(\.path)
    #expect(srcChildren == ["src/Nested", "src/AppMain.swift"])

    let prefixed = index.completionSearch("src/App", limit: 10).map(\.path)
    #expect(prefixed == ["src/AppMain.swift"])
}

@Test
func projectFileIndexDirectoryManifestValidatesDirectoryAndReturnsBoundedTree() throws {
    let root = try temporaryIndexRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let src = root.appendingPathComponent("src", isDirectory: true)
    try FileManager.default.createDirectory(at: src.appendingPathComponent("Nested", isDirectory: true), withIntermediateDirectories: true)
    try Data("main".utf8).write(to: src.appendingPathComponent("AppMain.swift"))
    try Data("helper".utf8).write(to: src.appendingPathComponent("Nested/Helper.swift"))

    let manifest = try ProjectFileIndex.directoryManifest(projectId: "p1", rootURL: root, path: "src/", limit: 2)
    #expect(manifest.count == 2)
    #expect(manifest.allSatisfy { $0.path.hasPrefix("src/") })
    #expect(throws: Error.self) {
        _ = try ProjectFileIndex.directoryManifest(projectId: "p1", rootURL: root, path: "missing/", limit: 2)
    }
}
