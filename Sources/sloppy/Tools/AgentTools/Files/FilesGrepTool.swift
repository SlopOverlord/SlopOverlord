import AnyLanguageModel
import Foundation
import Protocols

struct FilesGrepTool: CoreTool {
    let domain = "files"
    let title = "Search file contents"
    let status = "fully_functional"
    let name = "files.grep"
    let description = "Search UTF-8 file contents under a workspace path. Supports literal or regular expression queries with bounded results."
    let executableResolver: @Sendable (String) -> URL?

    private static let defaultMaxMatches = 100
    private static let hardMaxMatches = 500
    private static let defaultMaxFiles = 20_000
    private static let hardMaxFiles = 100_000
    fileprivate static let previewLimit = 240

    init(executableResolver: @escaping @Sendable (String) -> URL? = findExecutableInPath(named:)) {
        self.executableResolver = executableResolver
    }

    var parameters: GenerationSchema {
        .objectSchema([
            .init(
                name: "query",
                description: "Text or regex pattern to search for.",
                schema: DynamicGenerationSchema(type: String.self)
            ),
            .init(
                name: "path",
                description: "File or directory path to search. Defaults to the current workspace directory.",
                schema: DynamicGenerationSchema(type: String.self),
                isOptional: true
            ),
            .init(
                name: "regex",
                description: "Treat query as a regular expression. Defaults to false.",
                schema: DynamicGenerationSchema(type: Bool.self),
                isOptional: true
            ),
            .init(
                name: "caseSensitive",
                description: "Use case-sensitive matching. Defaults to false.",
                schema: DynamicGenerationSchema(type: Bool.self),
                isOptional: true
            ),
            .init(
                name: "maxMatches",
                description: "Maximum matching lines to return. Defaults to \(Self.defaultMaxMatches), max \(Self.hardMaxMatches).",
                schema: DynamicGenerationSchema(type: Int.self),
                isOptional: true
            ),
            .init(
                name: "maxFiles",
                description: "Maximum files to inspect. Defaults to \(Self.defaultMaxFiles), max \(Self.hardMaxFiles).",
                schema: DynamicGenerationSchema(type: Int.self),
                isOptional: true
            ),
            .init(
                name: "maxFileBytes",
                description: "Maximum size of each file to inspect, clamped by tool guardrails.",
                schema: DynamicGenerationSchema(type: Int.self),
                isOptional: true
            ),
            .init(
                name: "includeHidden",
                description: "Include hidden files and directories. Defaults to false.",
                schema: DynamicGenerationSchema(type: Bool.self),
                isOptional: true
            ),
        ])
    }

    func invoke(arguments: [String: JSONValue], context: ToolContext) async -> ToolInvocationResult {
        let query = arguments["query"]?.asString ?? ""
        guard !query.isEmpty else {
            return toolFailure(tool: name, code: "invalid_arguments", message: "`query` is required.", retryable: false)
        }

        let pathValue = arguments["path"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "."
        let searchesDefaultRoots = pathValue.isEmpty || pathValue == "."
        let rootURLs: [URL]
        if searchesDefaultRoots {
            rootURLs = defaultSearchRoots(context: context)
        } else if let rootURL = context.resolveReadablePath(pathValue) {
            rootURLs = [rootURL]
        } else {
            rootURLs = []
        }
        guard !rootURLs.isEmpty else {
            return toolFailure(tool: name, code: "path_not_allowed", message: "Search path is outside allowed roots.", retryable: false)
        }
        if !searchesDefaultRoots, let rootURL = rootURLs.first {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
                return toolFailure(
                    tool: name,
                    code: "not_found",
                    message: "No file or directory at \(rootURL.path).",
                    retryable: false,
                    hint: "Confirm the path spelling and that it exists under the workspace."
                )
            }
        }

        let regexEnabled = arguments["regex"]?.asBool ?? false
        let caseSensitive = arguments["caseSensitive"]?.asBool ?? false
        let includeHidden = arguments["includeHidden"]?.asBool ?? false
        let maxMatches = clamp(arguments["maxMatches"]?.asInt ?? Self.defaultMaxMatches, min: 1, max: Self.hardMaxMatches)
        let maxFiles = clamp(arguments["maxFiles"]?.asInt ?? Self.defaultMaxFiles, min: 1, max: Self.hardMaxFiles)
        let requestedMaxFileBytes = arguments["maxFileBytes"]?.asInt ?? context.policy.guardrails.maxReadBytes
        let maxFileBytes = clamp(requestedMaxFileBytes, min: 1, max: max(1, context.policy.guardrails.maxReadBytes))

        let matcher: LineMatcher
        do {
            matcher = try LineMatcher(query: query, regex: regexEnabled, caseSensitive: caseSensitive)
        } catch {
            return toolFailure(tool: name, code: "invalid_arguments", message: "Invalid regular expression.", retryable: false)
        }

        let output = await runSearch(
            rootURLs: rootURLs,
            context: context,
            query: query,
            matcher: matcher,
            regexEnabled: regexEnabled,
            caseSensitive: caseSensitive,
            includeHidden: includeHidden,
            maxMatches: maxMatches,
            maxFiles: maxFiles,
            maxFileBytes: maxFileBytes
        )

        return toolSuccess(tool: name, data: .object([
            "path": .string(rootURLs.first?.path ?? "."),
            "paths": .array(rootURLs.map { .string($0.path) }),
            "query": .string(query),
            "backend": .string(output.backend),
            "regex": .bool(regexEnabled),
            "caseSensitive": .bool(caseSensitive),
            "maxMatches": .number(Double(maxMatches)),
            "maxFiles": .number(Double(maxFiles)),
            "maxFileBytes": .number(Double(maxFileBytes)),
            "filesScanned": .number(Double(output.stats.filesScanned)),
            "filesSkipped": .number(Double(output.stats.filesSkipped)),
            "matchesCount": .number(Double(output.matches.count)),
            "truncated": .bool(output.truncated),
            "matches": .array(output.matches),
        ]))
    }

    private func defaultSearchRoots(context: ToolContext) -> [URL] {
        var roots: [URL] = [context.currentDirectoryURL]
        for rawRoot in context.policy.guardrails.allowedWriteRoots {
            let root = rawRoot.hasPrefix("/")
                ? URL(fileURLWithPath: rawRoot, isDirectory: true)
                : context.workspaceRootURL.appendingPathComponent(rawRoot, isDirectory: true)
            roots.append(root)
        }

        var seen = Set<String>()
        return roots.compactMap { root in
            let resolved = root.resolvingSymlinksInPath().standardizedFileURL
            guard seen.insert(resolved.path).inserted else {
                return nil
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory) else {
                return nil
            }
            return resolved
        }
    }

    private func runSearch(
        rootURLs: [URL],
        context: ToolContext,
        query: String,
        matcher: LineMatcher,
        regexEnabled: Bool,
        caseSensitive: Bool,
        includeHidden: Bool,
        maxMatches: Int,
        maxFiles: Int,
        maxFileBytes: Int
    ) async -> GrepSearchOutput {
        var backend: String?
        var matches: [JSONValue] = []
        var stats = GrepStats()
        var truncated = false

        for rootURL in rootURLs {
            guard matches.count < maxMatches, stats.filesScanned < maxFiles else {
                truncated = true
                break
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
                stats.filesSkipped += 1
                continue
            }

            let remainingMatches = max(1, maxMatches - matches.count)
            let remainingFiles = max(1, maxFiles - stats.filesScanned)
            let output: GrepSearchOutput
            if let rgURL = executableResolver("rg") {
                output = await runRipgrep(
                    executableURL: rgURL,
                    rootURL: rootURL,
                    isDirectory: isDirectory.boolValue,
                    context: context,
                    query: query,
                    regexEnabled: regexEnabled,
                    caseSensitive: caseSensitive,
                    includeHidden: includeHidden,
                    maxMatches: remainingMatches,
                    maxFileBytes: maxFileBytes
                )
            } else if let grepURL = executableResolver("grep") {
                output = await runGrep(
                    executableURL: grepURL,
                    rootURL: rootURL,
                    isDirectory: isDirectory.boolValue,
                    context: context,
                    query: query,
                    matcher: matcher,
                    regexEnabled: regexEnabled,
                    caseSensitive: caseSensitive,
                    includeHidden: includeHidden,
                    maxMatches: remainingMatches,
                    maxFiles: remainingFiles,
                    maxFileBytes: maxFileBytes
                )
            } else {
                output = runNativeSearch(
                    rootURL: rootURL,
                    isDirectory: isDirectory.boolValue,
                    context: context,
                    matcher: matcher,
                    includeHidden: includeHidden,
                    maxMatches: remainingMatches,
                    maxFiles: remainingFiles,
                    maxFileBytes: maxFileBytes
                )
            }

            backend = backend ?? output.backend
            matches += output.matches
            stats.filesScanned += output.stats.filesScanned
            stats.filesSkipped += output.stats.filesSkipped
            truncated = truncated || output.truncated
        }

        return GrepSearchOutput(
            backend: backend ?? "swift",
            matches: Array(matches.prefix(maxMatches)),
            stats: stats,
            truncated: truncated || matches.count > maxMatches
        )
    }

    private func runNativeSearch(
        rootURL: URL,
        isDirectory: Bool,
        context: ToolContext,
        matcher: LineMatcher,
        includeHidden: Bool,
        maxMatches: Int,
        maxFiles: Int,
        maxFileBytes: Int
    ) -> GrepSearchOutput {
        var stats = GrepStats()
        var matches: [JSONValue] = []
        var truncated = false

        if isDirectory {
            searchDirectory(
                rootURL,
                context: context,
                matcher: matcher,
                includeHidden: includeHidden,
                maxMatches: maxMatches,
                maxFiles: maxFiles,
                maxFileBytes: maxFileBytes,
                matches: &matches,
                stats: &stats,
                truncated: &truncated
            )
        } else {
            searchFile(
                rootURL,
                context: context,
                matcher: matcher,
                maxMatches: maxMatches,
                maxFileBytes: maxFileBytes,
                matches: &matches,
                stats: &stats,
                truncated: &truncated
            )
        }

        return GrepSearchOutput(backend: "swift", matches: matches, stats: stats, truncated: truncated)
    }

    private func runRipgrep(
        executableURL: URL,
        rootURL: URL,
        isDirectory: Bool,
        context: ToolContext,
        query: String,
        regexEnabled: Bool,
        caseSensitive: Bool,
        includeHidden: Bool,
        maxMatches: Int,
        maxFileBytes: Int
    ) async -> GrepSearchOutput {
        let cwd = isDirectory ? rootURL : rootURL.deletingLastPathComponent()
        let searchPath = isDirectory ? "." : rootURL.lastPathComponent
        var args = [
            "--json",
            "--color", "never",
            "--no-messages",
            "--max-filesize", "\(maxFileBytes)",
        ]
        if !regexEnabled {
            args.append("--fixed-strings")
        }
        if !caseSensitive {
            args.append("--ignore-case")
        }
        if includeHidden {
            args.append("--hidden")
        }
        for directoryName in ProjectChangeWatcherService.defaultExcludedDirectoryNames.sorted() {
            args += ["--glob", "!**/\(directoryName)/**"]
        }
        args += ["--", query, searchPath]

        do {
            let result = try await runForegroundProcess(
                command: executableURL.path,
                arguments: args,
                cwd: cwd,
                timeoutMs: context.policy.guardrails.execTimeoutMs,
                maxOutputBytes: max(64 * 1024, context.policy.guardrails.maxExecOutputBytes)
            )
            return parseRipgrepOutput(
                result,
                cwd: cwd,
                workspaceRootURL: context.workspaceRootURL,
                maxMatches: maxMatches
            )
        } catch {
            return runNativeSearch(
                rootURL: rootURL,
                isDirectory: isDirectory,
                context: context,
                matcher: (try? LineMatcher(query: query, regex: regexEnabled, caseSensitive: caseSensitive))
                    ?? (try! LineMatcher(query: query, regex: false, caseSensitive: caseSensitive)),
                includeHidden: includeHidden,
                maxMatches: maxMatches,
                maxFiles: Self.defaultMaxFiles,
                maxFileBytes: maxFileBytes
            )
        }
    }

    private func runGrep(
        executableURL: URL,
        rootURL: URL,
        isDirectory: Bool,
        context: ToolContext,
        query: String,
        matcher: LineMatcher,
        regexEnabled: Bool,
        caseSensitive: Bool,
        includeHidden: Bool,
        maxMatches: Int,
        maxFiles: Int,
        maxFileBytes: Int
    ) async -> GrepSearchOutput {
        var stats = GrepStats()
        var truncated = false
        let files = collectSearchableFiles(
            rootURL: rootURL,
            isDirectory: isDirectory,
            includeHidden: includeHidden,
            maxFiles: maxFiles,
            maxFileBytes: maxFileBytes,
            stats: &stats,
            truncated: &truncated
        )
        guard !files.isEmpty, !truncated || stats.filesScanned > 0 else {
            return GrepSearchOutput(backend: "grep", matches: [], stats: stats, truncated: truncated)
        }

        var matches: [JSONValue] = []
        let chunkSize = 200
        for start in stride(from: 0, to: files.count, by: chunkSize) {
            if matches.count >= maxMatches {
                truncated = true
                break
            }
            let chunk = Array(files[start..<min(start + chunkSize, files.count)])
            var args = ["-n", "-H", "-I", "--null"]
            args.append(regexEnabled ? "-E" : "-F")
            if !caseSensitive {
                args.append("-i")
            }
            args += ["-e", query]
            args += chunk.map(\.url.path)

            do {
                let result = try await runForegroundProcess(
                    command: executableURL.path,
                    arguments: args,
                    cwd: isDirectory ? rootURL : rootURL.deletingLastPathComponent(),
                    timeoutMs: context.policy.guardrails.execTimeoutMs,
                    maxOutputBytes: max(64 * 1024, context.policy.guardrails.maxExecOutputBytes)
                )
                let parsed = parseGrepOutput(
                    result,
                    matcher: matcher,
                    workspaceRootURL: context.workspaceRootURL,
                    maxMatches: maxMatches - matches.count
                )
                matches += parsed.matches
                truncated = truncated || parsed.truncated
            } catch {
                stats.filesSkipped += chunk.count
            }
        }

        return GrepSearchOutput(backend: "grep", matches: matches, stats: stats, truncated: truncated)
    }

    private func searchDirectory(
        _ directoryURL: URL,
        context: ToolContext,
        matcher: LineMatcher,
        includeHidden: Bool,
        maxMatches: Int,
        maxFiles: Int,
        maxFileBytes: Int,
        matches: inout [JSONValue],
        stats: inout GrepStats,
        truncated: inout Bool
    ) {
        guard !truncated else { return }

        let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: options
        ) else {
            stats.filesSkipped += 1
            return
        }

        for case let url as URL in enumerator {
            guard !Task.isCancelled else {
                truncated = true
                return
            }
            guard !truncated else { return }

            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if values?.isDirectory == true {
                if ProjectChangeWatcherService.defaultExcludedDirectoryNames.contains(name) || (name.hasPrefix(".") && !includeHidden) {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard values?.isRegularFile == true || values?.isSymbolicLink == true else {
                continue
            }
            guard stats.filesScanned < maxFiles else {
                truncated = true
                return
            }

            searchFile(
                url,
                context: context,
                matcher: matcher,
                maxMatches: maxMatches,
                maxFileBytes: maxFileBytes,
                knownSize: values?.fileSize,
                matches: &matches,
                stats: &stats,
                truncated: &truncated
            )
        }
    }

    private func searchFile(
        _ fileURL: URL,
        context: ToolContext,
        matcher: LineMatcher,
        maxMatches: Int,
        maxFileBytes: Int,
        knownSize: Int? = nil,
        matches: inout [JSONValue],
        stats: inout GrepStats,
        truncated: inout Bool
    ) {
        guard !truncated else { return }
        stats.filesScanned += 1

        let size = knownSize ?? ((try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue)
        if let size, size > maxFileBytes {
            stats.filesSkipped += 1
            return
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            stats.filesSkipped += 1
            return
        }
        guard data.count <= maxFileBytes else {
            stats.filesSkipped += 1
            return
        }
        guard let text = String(data: data, encoding: .utf8) else {
            stats.filesSkipped += 1
            return
        }

        for (index, line) in text.components(separatedBy: .newlines).enumerated() {
            guard let match = matcher.firstMatch(in: line) else {
                continue
            }

            matches.append(.object([
                "path": .string(displayPath(for: fileURL, workspaceRootURL: context.workspaceRootURL)),
                "line": .number(Double(index + 1)),
                "column": .number(Double(match.column)),
                "match": .string(match.text),
                "text": .string(clippedPreview(line)),
            ]))

            if matches.count >= maxMatches {
                truncated = true
                break
            }
        }
    }
}

private struct GrepStats {
    var filesScanned = 0
    var filesSkipped = 0
}

private struct GrepSearchOutput {
    var backend: String
    var matches: [JSONValue]
    var stats: GrepStats
    var truncated: Bool
}

private struct SearchableFile {
    var url: URL
}

private struct LineMatch {
    var column: Int
    var text: String
}

private struct LineMatcher {
    private let literalQuery: String?
    private let regex: NSRegularExpression?
    private let stringOptions: String.CompareOptions

    init(query: String, regex: Bool, caseSensitive: Bool) throws {
        if regex {
            let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
            self.regex = try NSRegularExpression(pattern: query, options: options)
            self.literalQuery = nil
            self.stringOptions = []
        } else {
            self.regex = nil
            self.literalQuery = query
            self.stringOptions = caseSensitive ? [] : [.caseInsensitive]
        }
    }

    func firstMatch(in line: String) -> LineMatch? {
        if let regex {
            let nsLine = line as NSString
            let range = NSRange(location: 0, length: nsLine.length)
            guard let match = regex.firstMatch(in: line, options: [], range: range),
                  match.range.location != NSNotFound
            else {
                return nil
            }
            let matchText = nsLine.substring(with: match.range)
            let prefix = nsLine.substring(to: match.range.location)
            return LineMatch(column: prefix.count + 1, text: matchText)
        }

        guard let literalQuery,
              let range = line.range(of: literalQuery, options: stringOptions)
        else {
            return nil
        }
        let column = line.distance(from: line.startIndex, to: range.lowerBound) + 1
        return LineMatch(column: column, text: String(line[range]))
    }
}

func findExecutableInPath(named name: String) -> URL? {
    guard !name.isEmpty, !name.contains("/") else {
        return nil
    }
    let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    for directory in path.split(separator: ":", omittingEmptySubsequences: false) {
        let directoryPath = directory.isEmpty ? "." : String(directory)
        let url = URL(fileURLWithPath: directoryPath).appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
    }
    return nil
}

private func collectSearchableFiles(
    rootURL: URL,
    isDirectory: Bool,
    includeHidden: Bool,
    maxFiles: Int,
    maxFileBytes: Int,
    stats: inout GrepStats,
    truncated: inout Bool
) -> [SearchableFile] {
    if !isDirectory {
        stats.filesScanned += 1
        guard fileSizeBytes(rootURL) <= maxFileBytes else {
            stats.filesSkipped += 1
            return []
        }
        return [SearchableFile(url: rootURL)]
    }

    let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
    guard let enumerator = FileManager.default.enumerator(
        at: rootURL,
        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
        options: options
    ) else {
        stats.filesSkipped += 1
        return []
    }

    var files: [SearchableFile] = []
    for case let url as URL in enumerator {
        guard !Task.isCancelled else {
            truncated = true
            break
        }
        let name = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        if values?.isDirectory == true {
            if ProjectChangeWatcherService.defaultExcludedDirectoryNames.contains(name) || (name.hasPrefix(".") && !includeHidden) {
                enumerator.skipDescendants()
            }
            continue
        }
        guard values?.isRegularFile == true || values?.isSymbolicLink == true else {
            continue
        }
        guard stats.filesScanned < maxFiles else {
            truncated = true
            break
        }
        stats.filesScanned += 1
        if (values?.fileSize ?? fileSizeBytes(url)) > maxFileBytes {
            stats.filesSkipped += 1
            continue
        }
        files.append(SearchableFile(url: url))
    }
    return files
}

private func parseRipgrepOutput(
    _ processResult: JSONValue,
    cwd: URL,
    workspaceRootURL: URL,
    maxMatches: Int
) -> GrepSearchOutput {
    let object = processResult.asObject ?? [:]
    let stdout = object["stdout"]?.asString ?? ""
    var stats = GrepStats()
    var matches: [JSONValue] = []
    var truncated = object["stdoutTruncated"]?.asBool == true || object["timedOut"]?.asBool == true

    for rawLine in stdout.split(separator: "\n", omittingEmptySubsequences: true) {
        guard matches.count < maxMatches else {
            truncated = true
            break
        }
        guard let data = String(rawLine).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String,
              let payload = json["data"] as? [String: Any]
        else {
            continue
        }

        if type == "summary", let summaryStats = payload["stats"] as? [String: Any] {
            stats.filesScanned = intValue(summaryStats["searches"]) ?? stats.filesScanned
            continue
        }
        guard type == "match" else {
            continue
        }
        guard let pathObject = payload["path"] as? [String: Any],
              let rawPath = pathObject["text"] as? String,
              let lineNumber = intValue(payload["line_number"]),
              let linesObject = payload["lines"] as? [String: Any],
              let rawLineText = linesObject["text"] as? String
        else {
            continue
        }

        let lineText = trimmingLineEnding(rawLineText)
        let submatches = payload["submatches"] as? [[String: Any]]
        let firstSubmatch = submatches?.first
        let byteStart = intValue(firstSubmatch?["start"]) ?? 0
        let matchText = ((firstSubmatch?["match"] as? [String: Any])?["text"] as? String) ?? ""
        let fileURL = rawPath.hasPrefix("/") ? URL(fileURLWithPath: rawPath) : cwd.appendingPathComponent(rawPath)
        matches.append(.object([
            "path": .string(displayPath(for: fileURL, workspaceRootURL: workspaceRootURL)),
            "line": .number(Double(lineNumber)),
            "column": .number(Double(columnForUTF8ByteOffset(byteStart, in: lineText))),
            "match": .string(matchText),
            "text": .string(clippedPreview(lineText)),
        ]))
    }

    return GrepSearchOutput(backend: "rg", matches: matches, stats: stats, truncated: truncated)
}

private func parseGrepOutput(
    _ processResult: JSONValue,
    matcher: LineMatcher,
    workspaceRootURL: URL,
    maxMatches: Int
) -> GrepSearchOutput {
    let object = processResult.asObject ?? [:]
    let stdout = object["stdout"]?.asString ?? ""
    var matches: [JSONValue] = []
    var truncated = object["stdoutTruncated"]?.asBool == true || object["timedOut"]?.asBool == true
    var cursor = stdout.startIndex

    while cursor < stdout.endIndex, matches.count < maxMatches {
        guard let nulIndex = stdout[cursor...].firstIndex(of: "\0") else {
            break
        }
        let rawPath = String(stdout[cursor..<nulIndex])
        let payloadStart = stdout.index(after: nulIndex)
        let payloadEnd = stdout[payloadStart...].firstIndex(of: "\n") ?? stdout.endIndex
        let payload = String(stdout[payloadStart..<payloadEnd])
        cursor = payloadEnd < stdout.endIndex ? stdout.index(after: payloadEnd) : stdout.endIndex

        guard let colon = payload.firstIndex(of: ":"),
              let lineNumber = Int(payload[..<colon])
        else {
            continue
        }
        let lineText = String(payload[payload.index(after: colon)...])
        guard let match = matcher.firstMatch(in: lineText) else {
            continue
        }
        matches.append(.object([
            "path": .string(displayPath(for: URL(fileURLWithPath: rawPath), workspaceRootURL: workspaceRootURL)),
            "line": .number(Double(lineNumber)),
            "column": .number(Double(match.column)),
            "match": .string(match.text),
            "text": .string(clippedPreview(lineText)),
        ]))
    }

    if matches.count >= maxMatches {
        truncated = true
    }
    return GrepSearchOutput(backend: "grep", matches: matches, stats: GrepStats(), truncated: truncated)
}

private func fileSizeBytes(_ fileURL: URL) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue) ?? 0
}

private func intValue(_ value: Any?) -> Int? {
    if let int = value as? Int {
        return int
    }
    if let number = value as? NSNumber {
        return number.intValue
    }
    return nil
}

private func trimmingLineEnding(_ text: String) -> String {
    var result = text
    while result.last == "\n" || result.last == "\r" {
        result.removeLast()
    }
    return result
}

private func columnForUTF8ByteOffset(_ offset: Int, in line: String) -> Int {
    let clamped = max(0, min(offset, line.utf8.count))
    let prefixBytes = Array(line.utf8.prefix(clamped))
    return (String(bytes: prefixBytes, encoding: .utf8)?.count ?? clamped) + 1
}

private func clamp(_ value: Int, min minValue: Int, max maxValue: Int) -> Int {
    min(max(value, minValue), maxValue)
}

private func displayPath(for fileURL: URL, workspaceRootURL: URL) -> String {
    let filePath = fileURL.standardizedFileURL.path
    let rootPath = workspaceRootURL.standardizedFileURL.path
    let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    if filePath.hasPrefix(prefix) {
        return String(filePath.dropFirst(prefix.count))
    }
    return filePath
}

private func clippedPreview(_ line: String) -> String {
    if line.count <= FilesGrepTool.previewLimit {
        return line
    }
    return String(line.prefix(FilesGrepTool.previewLimit - 3)) + "..."
}
