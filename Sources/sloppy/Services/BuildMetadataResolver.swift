import Foundation

public enum UpdateKind: String, Sendable, Codable {
    case release
    case git
}

public enum DeploymentKind: String, Sendable, Codable {
    case docker
    case local
}

struct GitHubRemoteDescriptor: Sendable, Equatable {
    let owner: String
    let repo: String
    let branch: String

    var cacheKey: String {
        "\(owner)/\(repo)#\(branch)"
    }
}

struct GitRepositoryMetadata: Sendable, Equatable {
    let repositoryRootPath: String
    let currentCommit: String?
    let currentCommitFull: String?
    let currentBranch: String?
    let currentCommitDate: Date?
    let upstreamBranch: String?
    let upstreamRemoteURL: String?
    let githubRemote: GitHubRemoteDescriptor?
}

struct BuildMetadata: Sendable, Equatable {
    let isReleaseBuild: Bool
    let displayVersion: String
    let releaseVersion: String?
    let deploymentKind: DeploymentKind
    let git: GitRepositoryMetadata?

    var updateKind: UpdateKind {
        isReleaseBuild ? .release : .git
    }
}

struct GitRepositoryInspector: Sendable {
    func inspectRepository(at rootURL: URL) -> GitRepositoryMetadata? {
        let repoPath = rootURL.path
        guard isGitRepository(at: repoPath) else { return nil }

        let currentBranch = gitOutput(["branch", "--show-current"], cwd: repoPath)
        let currentCommit = abbreviatedCommit(gitOutput(["rev-parse", "HEAD"], cwd: repoPath))
        let currentCommitFull = gitOutput(["rev-parse", "HEAD"], cwd: repoPath)
        let currentCommitDate = gitOutput(["show", "-s", "--format=%cI", "HEAD"], cwd: repoPath)
            .flatMap(Self.parseISO8601)

        let upstreamRef = gitOutput(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], cwd: repoPath)
        let upstreamRemoteURL: String?
        let upstreamBranch: String?
        let githubRemote: GitHubRemoteDescriptor?
        if let upstreamRef, let (remoteName, branchName) = Self.parseUpstreamRef(upstreamRef) {
            upstreamBranch = branchName
            upstreamRemoteURL = gitOutput(["config", "--get", "remote.\(remoteName).url"], cwd: repoPath)
            githubRemote = upstreamRemoteURL.flatMap { Self.parseGitHubRemote(url: $0, branch: branchName) }
        } else {
            upstreamRemoteURL = nil
            upstreamBranch = nil
            githubRemote = nil
        }

        return GitRepositoryMetadata(
            repositoryRootPath: repoPath,
            currentCommit: currentCommit,
            currentCommitFull: currentCommitFull,
            currentBranch: currentBranch,
            currentCommitDate: currentCommitDate,
            upstreamBranch: upstreamBranch,
            upstreamRemoteURL: upstreamRemoteURL,
            githubRemote: githubRemote
        )
    }

    static func parseGitHubRemote(url raw: String, branch: String) -> GitHubRemoteDescriptor? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalized: String
        if trimmed.hasPrefix("git@github.com:") {
            normalized = String(trimmed.dropFirst("git@github.com:".count))
        } else if trimmed.hasPrefix("ssh://git@github.com/") {
            normalized = String(trimmed.dropFirst("ssh://git@github.com/".count))
        } else if trimmed.hasPrefix("https://github.com/") {
            normalized = String(trimmed.dropFirst("https://github.com/".count))
        } else if trimmed.hasPrefix("http://github.com/") {
            normalized = String(trimmed.dropFirst("http://github.com/".count))
        } else {
            return nil
        }

        let cleaned = normalized
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: ".git", with: "")
        let parts = cleaned.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        return GitHubRemoteDescriptor(
            owner: String(parts[0]),
            repo: String(parts[1]),
            branch: branch
        )
    }

    private func abbreviatedCommit(_ sha: String?) -> String? {
        guard let sha, !sha.isEmpty else { return nil }
        return String(sha.prefix(12))
    }

    private func isGitRepository(at path: String) -> Bool {
        guard let output = gitOutput(["rev-parse", "--is-inside-work-tree"], cwd: path) else {
            return false
        }
        return output == "true"
    }

    private func gitOutput(_ args: [String], cwd: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.environment = childProcessEnvironment()

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty
        else {
            return nil
        }
        return output
    }

    private static func parseUpstreamRef(_ ref: String) -> (String, String)? {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let pieces = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
        guard pieces.count == 2 else { return nil }
        return (String(pieces[0]), String(pieces[1]))
    }

    private static func parseISO8601(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }
}

struct BuildMetadataResolver: Sendable {
    let repositoryRootURL: URL?
    let executableURL: URL?
    let environment: [String: String]
    let gitInspector: GitRepositoryInspector

    init(
        repositoryRootURL: URL? = nil,
        executableURL: URL? = currentExecutableURL(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        gitInspector: GitRepositoryInspector = GitRepositoryInspector()
    ) {
        self.repositoryRootURL = repositoryRootURL
        self.executableURL = executableURL
        self.environment = environment
        self.gitInspector = gitInspector
    }

    func resolve() -> BuildMetadata {
        let releaseVersion = SloppyVersion.releaseVersion
        let gitMetadata = resolveGitMetadata()
        return BuildMetadata(
            isReleaseBuild: releaseVersion != nil,
            displayVersion: Self.displayVersion(releaseVersion: releaseVersion, gitMetadata: gitMetadata),
            releaseVersion: releaseVersion,
            deploymentKind: Self.resolveDeploymentKind(environment: environment),
            git: gitMetadata
        )
    }

    func resolveGitMetadata() -> GitRepositoryMetadata? {
        let rootURL = repositoryRootURL
            ?? executableURL.flatMap { repoRootDerivedFromExecutable(executableURL: $0) }
            ?? Self.findRepositoryRoot(
                startingAt: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            )
        guard let rootURL else { return nil }
        return gitInspector.inspectRepository(at: rootURL)
    }

    static func displayVersion(releaseVersion: String?, gitMetadata: GitRepositoryMetadata?) -> String {
        if let releaseVersion, !releaseVersion.isEmpty {
            return releaseVersion
        }
        guard let commit = gitMetadata?.currentCommit, !commit.isEmpty else {
            return "dev build"
        }
        guard let branch = gitMetadata?.currentBranch?.trimmingCharacters(in: .whitespacesAndNewlines),
              !branch.isEmpty
        else {
            return commit
        }
        return "\(commit) (\(branch))"
    }

    static func resolveDeploymentKind(environment: [String: String]) -> DeploymentKind {
        if environment["SLOPPY_DEPLOYMENT_KIND"]?.lowercased() == "docker" {
            return .docker
        }
        if FileManager.default.fileExists(atPath: "/.dockerenv") {
            return .docker
        }
        return .local
    }

    static func findRepositoryRoot(startingAt startURL: URL) -> URL? {
        var candidate = startURL.standardizedFileURL
        let fileManager = FileManager.default

        while true {
            let gitURL = candidate.appendingPathComponent(".git")
            if fileManager.fileExists(atPath: gitURL.path) {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path {
                return nil
            }
            candidate = parent
        }
    }
}
