import Foundation
import Protocols

struct ProjectFileIndexEntry: Codable, Equatable, Sendable {
    var path: String
    var type: ProjectFileEntry.EntryType
}

struct ProjectFileIndex: Codable, Equatable, Sendable {
    static let version = 1
    static let defaultLimit = 80_000

    var version: Int
    var projectId: String
    var rootPath: String
    var indexedAt: Date
    var truncated: Bool
    var entries: [ProjectFileIndexEntry]

    init(
        version: Int = Self.version,
        projectId: String,
        rootPath: String,
        indexedAt: Date = Date(),
        truncated: Bool = false,
        entries: [ProjectFileIndexEntry]
    ) {
        self.version = version
        self.projectId = projectId
        self.rootPath = rootPath
        self.indexedAt = indexedAt
        self.truncated = truncated
        self.entries = entries
    }

    static func build(
        projectId: String,
        rootURL: URL,
        additionalRootURLs: [URL] = [],
        limit: Int = defaultLimit,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) -> ProjectFileIndex {
        var builder = ProjectFileIndexBuilder(
            fileManager: fileManager,
            limit: max(1, limit)
        )
        let root = rootURL.standardizedFileURL
        var entries = builder.entries(rootURL: root)
        for additionalRoot in additionalRootURLs.map(\.standardizedFileURL) {
            guard additionalRoot.path != root.path else {
                continue
            }
            entries += builder.entries(rootURL: additionalRoot, pathPrefix: additionalRoot.path)
        }
        return ProjectFileIndex(
            projectId: projectId,
            rootPath: root.path,
            indexedAt: now,
            truncated: builder.truncated,
            entries: entries
        )
    }

    func search(_ query: String, limit: Int) -> [ProjectFileIndexEntry] {
        let normalized = Self.normalizedQuery(query)
        let maxResults = max(1, limit)
        guard !entries.isEmpty else {
            return []
        }

        if normalized.isEmpty {
            return Array(entries.prefix(maxResults))
        }

        let lowerQuery = normalized.lowercased()
        let directoryQuery = normalized.hasSuffix("/")
        let directoryPath = directoryQuery ? String(normalized.dropLast()) : normalized
        let lowerDirectoryPath = directoryPath.lowercased()

        var best: [(entry: ProjectFileIndexEntry, rank: (Int, Int, Int, String))] = []
        best.reserveCapacity(maxResults)

        for entry in entries {
            let rank: (Int, Int, Int, String)?
            if directoryQuery {
                rank = Self.directorySearchRank(
                    entry: entry,
                    directoryPath: directoryPath,
                    lowerDirectoryPath: lowerDirectoryPath
                )
            } else {
                rank = Self.searchRank(entry: entry, query: normalized, lowerQuery: lowerQuery)
            }
            guard let rank else {
                continue
            }
            Self.insertTopMatch((entry, rank), into: &best, limit: maxResults)
        }

        return best.map(\.entry)
    }

    func completionSearch(_ query: String, limit: Int) -> [ProjectFileIndexEntry] {
        let normalized = Self.normalizedQuery(query)
        guard !normalized.isEmpty else {
            return search(normalized, limit: limit)
        }
        guard normalized.contains("/") else {
            return search(normalized, limit: limit)
        }
        return pathCompletionSearch(normalized, limit: limit)
    }

    func directoryManifest(path: String, limit: Int) -> [ProjectFileIndexEntry] {
        let normalized = Self.normalizedQuery(path)
        let directoryPath = normalized.hasSuffix("/") ? String(normalized.dropLast()) : normalized
        guard !directoryPath.isEmpty else {
            return Array(entries.sorted(by: Self.sortForDisplay).prefix(max(1, limit)))
        }

        let prefix = directoryPath + "/"
        return entries
            .filter { $0.path.hasPrefix(prefix) }
            .sorted(by: Self.sortForDisplay)
            .prefix(max(1, limit))
            .map(\.self)
    }

    static func directoryManifest(
        projectId: String,
        rootURL: URL,
        path: String,
        limit: Int,
        fileManager: FileManager = .default
    ) throws -> [ProjectFileIndexEntry] {
        let normalized = normalizedQuery(path)
        let target = normalized.isEmpty ? rootURL : rootURL.appendingPathComponent(normalized).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileNoSuchFile)
        }

        let index = build(projectId: projectId, rootURL: rootURL, limit: defaultLimit, fileManager: fileManager)
        return index.directoryManifest(path: normalized, limit: limit)
    }

    private static func normalizedQuery(_ query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/"), trimmed != "/" {
            let stripped = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !stripped.isEmpty else {
                return ""
            }
            return "/" + stripped + (trimmed.hasSuffix("/") ? "/" : "")
        }
        let stripped = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !stripped.isEmpty else {
            return ""
        }
        return stripped + (trimmed.hasSuffix("/") ? "/" : "")
    }

    private static func searchRank(
        entry: ProjectFileIndexEntry,
        query: String,
        lowerQuery: String
    ) -> (Int, Int, Int, String)? {
        let path = entry.path
        let lowerPath = path.lowercased()
        let lowerPathWithoutLeadingSlash = lowerPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let basename = (path as NSString).lastPathComponent
        let lowerBasename = basename.lowercased()

        if lowerPath == lowerQuery {
            return (0, typeRank(entry.type), path.count, path)
        }
        if lowerPath.hasPrefix(lowerQuery) || lowerPathWithoutLeadingSlash.hasPrefix(lowerQuery) {
            return (1, typeRank(entry.type), path.count, path)
        }
        if lowerBasename.hasPrefix(lowerQuery) {
            return (2, typeRank(entry.type), path.count, path)
        }
        if let range = lowerPath.range(of: lowerQuery) {
            let offset = lowerPath.distance(from: lowerPath.startIndex, to: range.lowerBound)
            return (3, offset, typeRank(entry.type), path)
        }
        if let range = lowerBasename.range(of: lowerQuery) {
            let offset = lowerBasename.distance(from: lowerBasename.startIndex, to: range.lowerBound)
            return (4, offset, typeRank(entry.type), path)
        }
        return nil
    }

    private static func directorySearchRank(
        entry: ProjectFileIndexEntry,
        directoryPath: String,
        lowerDirectoryPath: String
    ) -> (Int, Int, Int, String)? {
        let lowerPath = entry.path.lowercased()
        let lowerPathWithoutLeadingSlash = lowerPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let prefix = lowerDirectoryPath + "/"

        if lowerPath == lowerDirectoryPath, entry.type == .directory {
            return (0, 0, 0, entry.path)
        }
        if lowerPath.hasPrefix(prefix) || lowerPathWithoutLeadingSlash.hasPrefix(prefix) {
            let suffix = String(entry.path.dropFirst(directoryPath.count + 1))
            let depth = suffix.split(separator: "/").count
            return (1, depth, typeRank(entry.type), entry.path)
        }
        return nil
    }

    private func pathCompletionSearch(_ normalized: String, limit: Int) -> [ProjectFileIndexEntry] {
        let maxResults = max(1, limit)
        let hasTrailingSlash = normalized.hasSuffix("/")
        let trimmed = hasTrailingSlash ? String(normalized.dropLast()) : normalized
        let parentPath: String
        let childPrefix: String

        if hasTrailingSlash {
            parentPath = trimmed
            childPrefix = ""
        } else {
            let parent = (trimmed as NSString).deletingLastPathComponent
            parentPath = parent == "." ? "" : parent
            childPrefix = (trimmed as NSString).lastPathComponent
        }

        let lowerChildPrefix = childPrefix.lowercased()
        let entryPrefix = parentPath.isEmpty ? "" : parentPath + "/"
        var matches: [ProjectFileIndexEntry] = []
        matches.reserveCapacity(maxResults)

        for entry in entries {
            guard entry.path.hasPrefix(entryPrefix) else {
                continue
            }

            let suffix = String(entry.path.dropFirst(entryPrefix.count))
            guard !suffix.isEmpty, !suffix.contains("/") else {
                continue
            }

            if !lowerChildPrefix.isEmpty,
               !suffix.lowercased().hasPrefix(lowerChildPrefix) {
                continue
            }

            matches.append(entry)
            if matches.count >= maxResults * 4 {
                break
            }
        }

        return matches
            .sorted(by: Self.sortForDisplay)
            .prefix(maxResults)
            .map(\.self)
    }

    private static func sortForDisplay(_ lhs: ProjectFileIndexEntry, _ rhs: ProjectFileIndexEntry) -> Bool {
        if lhs.type != rhs.type {
            return lhs.type == .directory
        }
        return lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
    }

    private static func insertTopMatch(
        _ candidate: (entry: ProjectFileIndexEntry, rank: (Int, Int, Int, String)),
        into best: inout [(entry: ProjectFileIndexEntry, rank: (Int, Int, Int, String))],
        limit: Int
    ) {
        if best.count == limit, let last = best.last, !isRank(candidate.rank, betterThan: last.rank) {
            return
        }

        let index = best.firstIndex { current in
            isRank(candidate.rank, betterThan: current.rank)
        } ?? best.endIndex
        best.insert(candidate, at: index)
        if best.count > limit {
            best.removeLast(best.count - limit)
        }
    }

    private static func isRank(
        _ lhs: (Int, Int, Int, String),
        betterThan rhs: (Int, Int, Int, String)
    ) -> Bool {
        if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
        if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
        if lhs.2 != rhs.2 { return lhs.2 < rhs.2 }
        return lhs.3.localizedCaseInsensitiveCompare(rhs.3) == .orderedAscending
    }

    private static func typeRank(_ type: ProjectFileEntry.EntryType) -> Int {
        type == .directory ? 0 : 1
    }
}

struct ProjectFileIndexStore {
    var workspaceRoot: URL
    var fileManager: FileManager = .default

    func cacheURL(projectId: String) -> URL {
        workspaceRoot
            .appendingPathComponent("tui", isDirectory: true)
            .appendingPathComponent("file-indexes", isDirectory: true)
            .appendingPathComponent("\(projectId).json")
    }

    func load(projectId: String, rootPath: String) -> ProjectFileIndex? {
        let url = cacheURL(projectId: projectId)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let index = try? decoder.decode(ProjectFileIndex.self, from: data),
              index.version == ProjectFileIndex.version,
              index.projectId == projectId,
              index.rootPath == rootPath
        else {
            return nil
        }
        return index
    }

    func save(_ index: ProjectFileIndex) {
        do {
            let url = cacheURL(projectId: index.projectId)
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(index) + Data("\n".utf8)
            try data.write(to: url, options: .atomic)
        } catch {
            // File index cache is only an optimization.
        }
    }
}

private struct ProjectFileIndexBuilder {
    var fileManager: FileManager
    var limit: Int
    var truncated = false

    mutating func entries(rootURL: URL, pathPrefix: String = "") -> [ProjectFileIndexEntry] {
        var result: [ProjectFileIndexEntry] = []
        walk(directoryURL: rootURL, relativeDirectory: pathPrefix, result: &result)
        return result
    }

    private mutating func walk(directoryURL: URL, relativeDirectory: String, result: inout [ProjectFileIndexEntry]) {
        guard !Task.isCancelled else {
            truncated = true
            return
        }
        guard result.count < limit else {
            truncated = true
            return
        }

        let urls = (try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for url in urls.sorted(by: { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }) {
            guard !Task.isCancelled else {
                truncated = true
                return
            }
            guard result.count < limit else {
                truncated = true
                return
            }

            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            let isDirectory = values?.isDirectory == true
            if isDirectory, ProjectChangeWatcherService.defaultExcludedDirectoryNames.contains(name) {
                continue
            }

            let relativePath = relativeDirectory.isEmpty ? name : "\(relativeDirectory)/\(name)"
            result.append(ProjectFileIndexEntry(path: relativePath, type: isDirectory ? .directory : .file))

            if isDirectory {
                walk(directoryURL: url, relativeDirectory: relativePath, result: &result)
            }
        }
    }
}
