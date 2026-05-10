import Foundation

struct ProjectContextLoader {
    struct Limits: Sendable {
        var maxSkillFiles: Int = 25
        var maxCharsPerFile: Int = 20_000
        var maxTotalChars: Int = 200_000
    }

    struct LoadedFile: Sendable {
        var relativePath: String
        var chars: Int
        var truncated: Bool
        var content: String
    }

    struct Result: Sendable {
        var repoPath: String
        var loadedDocs: [LoadedFile]
        var loadedProjectMemory: LoadedFile?
        var loadedSkills: [LoadedFile]
        var totalChars: Int
        var truncated: Bool
    }

    private let limits: Limits

    init(limits: Limits = Limits()) {
        self.limits = limits
    }

    func load(repoPath: String, projectMemoryURL: URL? = nil) -> Result {
        let rootURL = URL(fileURLWithPath: repoPath, isDirectory: true).standardized
        var loadedDocs: [LoadedFile] = []
        var loadedProjectMemory: LoadedFile?
        var loadedSkills: [LoadedFile] = []
        var totalChars = 0
        var truncated = false

        func canAcceptMoreChars(_ additional: Int) -> Bool {
            totalChars + additional <= limits.maxTotalChars
        }

        func addFile(relativePath: String, content: String, to target: inout [LoadedFile]) {
            guard totalChars < limits.maxTotalChars else {
                truncated = true
                return
            }

            let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
            let limited = String(normalized.prefix(limits.maxCharsPerFile))
            var finalContent = limited
            var didTruncate = limited.count < normalized.count

            let remaining = max(0, limits.maxTotalChars - totalChars)
            if finalContent.count > remaining {
                finalContent = String(finalContent.prefix(remaining))
                didTruncate = true
            }

            guard canAcceptMoreChars(finalContent.count) else {
                truncated = true
                return
            }

            target.append(
                LoadedFile(
                    relativePath: relativePath,
                    chars: finalContent.count,
                    truncated: didTruncate,
                    content: finalContent
                )
            )
            totalChars += finalContent.count
            if didTruncate {
                truncated = true
            }
        }

        func readTextFileIfExists(relativePath: String) -> String? {
            let url = rootURL.appendingPathComponent(relativePath).standardized
            guard url.path.hasPrefix(rootURL.path) else { return nil }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
                return nil
            }
            guard let data = try? Data(contentsOf: url), data.count <= 2 * 1024 * 1024 else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        }

        let docPaths: [String] = [
            "AGENTS.md",
            "CLAUDE.md",
            "SLOPPY.md"
        ]
        for relativePath in docPaths {
            guard let text = readTextFileIfExists(relativePath: relativePath) else { continue }
            addFile(relativePath: relativePath, content: text, to: &loadedDocs)
        }

        if let projectMemoryURL,
           let text = try? String(contentsOf: projectMemoryURL, encoding: .utf8) {
            var memoryDocs: [LoadedFile] = []
            addFile(relativePath: ".meta/MEMORY.md", content: text, to: &memoryDocs)
            loadedProjectMemory = memoryDocs.first
        }

        if totalChars < limits.maxTotalChars {
            loadSkillFiles(rootURL: rootURL, addFile: { relativePath, content in
                addFile(relativePath: relativePath, content: content, to: &loadedSkills)
            }, recordTruncation: {
                truncated = true
            })
        }

        return Result(
            repoPath: rootURL.path,
            loadedDocs: loadedDocs,
            loadedProjectMemory: loadedProjectMemory,
            loadedSkills: loadedSkills,
            totalChars: totalChars,
            truncated: truncated
        )
    }

    private func loadSkillFiles(
        rootURL: URL,
        addFile: (String, String) -> Void,
        recordTruncation: () -> Void
    ) {
        let skillsRoot = rootURL.appendingPathComponent(".skills", isDirectory: true).standardized
        guard skillsRoot.path.hasPrefix(rootURL.path) else { return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: skillsRoot.path, isDirectory: &isDir), isDir.boolValue else {
            return
        }

        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        let enumerator = fm.enumerator(at: skillsRoot, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])

        var skillPaths: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            let values = (try? url.resourceValues(forKeys: Set(keys)))
            guard values?.isRegularFile == true else { continue }
            guard url.lastPathComponent == "SKILL.md" else { continue }
            guard url.path.hasPrefix(rootURL.path) else { continue }

            let relative = String(url.path.dropFirst(rootURL.path.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            skillPaths.append(relative)
        }

        skillPaths.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        if skillPaths.count > limits.maxSkillFiles {
            recordTruncation()
            skillPaths = Array(skillPaths.prefix(limits.maxSkillFiles))
        }

        for relativePath in skillPaths {
            guard let text = try? String(contentsOf: rootURL.appendingPathComponent(relativePath), encoding: .utf8) else {
                continue
            }
            addFile(relativePath, text)
        }
    }
}
