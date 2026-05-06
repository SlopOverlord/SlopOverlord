import Foundation
import Testing
@testable import sloppy

@Test
func sloppyVersionIsNewerPatch() {
    #expect(SloppyVersion.isNewer("1.2.4", than: "1.2.3") == true)
}

@Test
func sloppyVersionIsNewerMinor() {
    #expect(SloppyVersion.isNewer("1.3.0", than: "1.2.9") == true)
}

@Test
func sloppyVersionIsNewerMajor() {
    #expect(SloppyVersion.isNewer("2.0.0", than: "1.9.9") == true)
}

@Test
func sloppyVersionNotNewerWhenEqual() {
    #expect(SloppyVersion.isNewer("1.2.3", than: "1.2.3") == false)
}

@Test
func sloppyVersionNotNewerWhenOlder() {
    #expect(SloppyVersion.isNewer("1.2.2", than: "1.2.3") == false)
}

@Test
func sloppyVersionNewerWithMissingSegment() {
    #expect(SloppyVersion.isNewer("2.0", than: "1.9.9") == true)
}

@Test
func sloppyVersionNotNewerWithMissingSegment() {
    #expect(SloppyVersion.isNewer("1.2", than: "1.2.1") == false)
}

@Test
func sloppyVersionReleaseVsDevDetection() {
    #expect(SloppyVersion.isReleaseBuild == (SloppyVersion.releaseVersion != nil))
}

@Test
func sloppyVersionReadsInstalledShareVersionFile() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let binDirectory = root.appendingPathComponent("bin", isDirectory: true)
    let shareDirectory = root.appendingPathComponent("share/sloppy", isDirectory: true)
    try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: shareDirectory, withIntermediateDirectories: true)

    let versionFile = shareDirectory.appendingPathComponent("sloppy-version.json")
    try """
    {
      "sloppy-core": {
        "version": "2.4.6"
      }
    }
    """.write(to: versionFile, atomically: true, encoding: .utf8)

    let executablePath = binDirectory.appendingPathComponent("sloppy").path
    let value = SloppyVersion.loadReleaseVersion(
        executablePath: executablePath,
        currentDirectoryPath: root.path,
        sourceFilePath: root.appendingPathComponent("Missing/SloppyVersion.swift").path
    )

    #expect(value == "2.4.6")
}

@Test
func sloppyVersionReadsInstalledShareVersionFileViaSymlink() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let installRoot = root.appendingPathComponent("install", isDirectory: true)
    let linkRoot = root.appendingPathComponent("links", isDirectory: true)
    let binDirectory = installRoot.appendingPathComponent("bin", isDirectory: true)
    let shareDirectory = installRoot.appendingPathComponent("share/sloppy", isDirectory: true)
    try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: shareDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: linkRoot, withIntermediateDirectories: true)

    let realBinaryPath = binDirectory.appendingPathComponent("sloppy").path
    let symlinkPath = linkRoot.appendingPathComponent("sloppy").path
    FileManager.default.createFile(atPath: realBinaryPath, contents: Data(), attributes: nil)
    try FileManager.default.createSymbolicLink(atPath: symlinkPath, withDestinationPath: realBinaryPath)

    let versionFile = shareDirectory.appendingPathComponent("sloppy-version.json")
    try """
    {
      "sloppy-core": {
        "version": "3.1.4"
      }
    }
    """.write(to: versionFile, atomically: true, encoding: .utf8)

    let value = SloppyVersion.loadReleaseVersion(
        executablePath: symlinkPath,
        currentDirectoryPath: root.path,
        sourceFilePath: root.appendingPathComponent("Missing/SloppyVersion.swift").path
    )

    #expect(value == "3.1.4")
}

@Test
func sloppyVersionIgnoresPlaceholderVersionFile() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let versionFile = root.appendingPathComponent("sloppy-version.json")
    try """
    {
      "sloppy-core": {
        "version": "__SLOPPY_APP_VERSION__"
      }
    }
    """.write(to: versionFile, atomically: true, encoding: .utf8)

    let value = SloppyVersion.releaseVersion(at: versionFile)
    #expect(value == nil)
}

@Test
func buildMetadataDisplayVersionUsesReleaseVersion() {
    let value = BuildMetadataResolver.displayVersion(releaseVersion: "1.2.3", gitMetadata: nil)
    #expect(value == "1.2.3")
}

@Test
func buildMetadataDisplayVersionUsesCommitAndBranchForDevBuild() {
    let metadata = GitRepositoryMetadata(
        repositoryRootPath: "/tmp/sloppy",
        currentCommit: "4f0a1704cd6a",
        currentCommitFull: "4f0a1704cd6a92e01168c3b7e57645d236d8aa82",
        currentBranch: "main",
        currentCommitDate: nil,
        upstreamBranch: "main",
        upstreamRemoteURL: "https://github.com/TeamSloppy/Sloppy.git",
        githubRemote: GitHubRemoteDescriptor(owner: "TeamSloppy", repo: "Sloppy", branch: "main")
    )
    let value = BuildMetadataResolver.displayVersion(releaseVersion: nil, gitMetadata: metadata)
    #expect(value == "4f0a1704cd6a (main)")
}

@Test
func buildMetadataDisplayVersionFallsBackWithoutGitMetadata() {
    let value = BuildMetadataResolver.displayVersion(releaseVersion: nil, gitMetadata: nil)
    #expect(value == "dev build")
}

@Test
func buildMetadataResolverUsesExecutableSourceCheckout() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("Dashboard", isDirectory: true),
        withIntermediateDirectories: true
    )
    try "// package\n".write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    try "test\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

    try runVersionTestGit(["init", "--initial-branch=main"], cwd: root)
    try runVersionTestGit(["config", "user.email", "test@sloppy.dev"], cwd: root)
    try runVersionTestGit(["config", "user.name", "SloppyTest"], cwd: root)
    try runVersionTestGit(["add", "."], cwd: root)
    try runVersionTestGit(["commit", "-m", "init"], cwd: root)

    let executableURL = root
        .appendingPathComponent(".build/release", isDirectory: true)
        .appendingPathComponent("sloppy")
    try FileManager.default.createDirectory(
        at: executableURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    FileManager.default.createFile(atPath: executableURL.path, contents: Data(), attributes: nil)

    let metadata = BuildMetadataResolver(executableURL: executableURL).resolve()

    #expect(metadata.git?.repositoryRootPath == root.path)
    #expect(metadata.git?.currentBranch == "main")
}

@Test
func gitHubRemoteParserAcceptsGitHubUrls() {
    let parsed = GitRepositoryInspector.parseGitHubRemote(
        url: "git@github.com:TeamSloppy/Sloppy.git",
        branch: "feature/test"
    )
    #expect(parsed == GitHubRemoteDescriptor(owner: "TeamSloppy", repo: "Sloppy", branch: "feature/test"))
}

@Test
func gitHubRemoteParserRejectsNonGitHubUrls() {
    let parsed = GitRepositoryInspector.parseGitHubRemote(
        url: "https://gitlab.com/TeamSloppy/Sloppy.git",
        branch: "main"
    )
    #expect(parsed == nil)
}

@Test
func buildMetadataDeploymentKindDetectsExplicitDockerFlag() {
    let kind = BuildMetadataResolver.resolveDeploymentKind(environment: ["SLOPPY_DEPLOYMENT_KIND": "docker"])
    #expect(kind == .docker)
}

private func runVersionTestGit(_ args: [String], cwd: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = args
    process.currentDirectoryURL = cwd
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
}
