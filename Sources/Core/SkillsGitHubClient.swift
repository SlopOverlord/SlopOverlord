import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Client for downloading skill files from GitHub repositories
actor SkillsGitHubClient {
    enum ClientError: Error {
        case invalidURL
        case invalidRepository
        case networkError(Error)
        case httpError(Int, String?)
        case decodeError
        case fileWriteError(Error)
        case invalidResponse
        case contentNotFound
    }

    private let urlSession: URLSession
    private let decoder: JSONDecoder

    init(urlSession: URLSession = URLSession.shared) {
        self.urlSession = urlSession
        self.decoder = JSONDecoder()
    }

    // MARK: - Public API

    /// Download a skill from GitHub repository
    /// Downloads the repository content and extracts skill files
    func downloadSkill(
        owner: String,
        repo: String,
        version: String? = nil,
        destination: URL
    ) async throws -> DownloadedSkill {
        // Validate inputs
        let normalizedOwner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedRepo = repo.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedOwner.isEmpty, !normalizedRepo.isEmpty else {
            throw ClientError.invalidRepository
        }

        let ref = version ?? "main"

        // First, try to get the repository contents
        let contents = try await fetchRepositoryContents(
            owner: normalizedOwner,
            repo: normalizedRepo,
            path: "",
            ref: ref
        )

        // Create destination directory
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        // Download files
        var downloadedFiles: [String] = []
        var skillName = normalizedRepo
        var skillDescription: String?

        // Look for common skill files
        let skillFiles = contents.filter { item in
            let name = item.name.lowercased()
            return name.hasSuffix(".md") ||
                   name == "skill.json" ||
                   name == "package.json" ||
                   name.hasPrefix("skill") ||
                   name.hasPrefix("prompt")
        }

        for item in skillFiles {
            do {
                let fileURL = destination.appendingPathComponent(item.name)

                if item.type == "file" {
                    guard let downloadURL = item.downloadUrl else {
                        continue
                    }

                    try await downloadFile(from: downloadURL, to: fileURL)
                    downloadedFiles.append(item.name)

                    // Try to extract skill name from common files
                    if item.name.lowercased() == "skill.json" {
                        if let metadata = try? extractSkillMetadata(from: fileURL) {
                            skillName = metadata.name ?? skillName
                            skillDescription = metadata.description
                        }
                    } else if item.name.lowercased() == "readme.md" {
                        if let readmeContent = try? String(contentsOf: fileURL, encoding: .utf8) {
                            skillDescription = extractDescriptionFromReadme(readmeContent)
                        }
                    }
                } else if item.type == "dir" {
                    // Recursively download subdirectory
                    let subDir = destination.appendingPathComponent(item.name)
                    let subFiles = try await downloadDirectory(
                        owner: normalizedOwner,
                        repo: normalizedRepo,
                        path: item.path,
                        ref: ref,
                        destination: subDir
                    )
                    downloadedFiles.append(contentsOf: subFiles.map { "\(item.name)/\($0)" })
                }
            } catch {
                // Continue with other files if one fails
                continue
            }
        }

        guard !downloadedFiles.isEmpty else {
            throw ClientError.contentNotFound
        }

        return DownloadedSkill(
            owner: normalizedOwner,
            repo: normalizedRepo,
            name: skillName,
            description: skillDescription,
            version: ref,
            files: downloadedFiles,
            localPath: destination.path
        )
    }

    /// Get the raw URL for a specific file in a repository
    func rawFileURL(
        owner: String,
        repo: String,
        path: String,
        ref: String = "main"
    ) -> URL? {
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/\(ref)/\(encodedPath)")
    }

    // MARK: - Private Helpers

    private func fetchRepositoryContents(
        owner: String,
        repo: String,
        path: String,
        ref: String
    ) async throws -> [GitHubContentItem] {
        var urlString = "https://api.github.com/repos/\(owner)/\(repo)/contents"
        if !path.isEmpty {
            urlString += "/\(path)"
        }
        urlString += "?ref=\(ref)"

        guard let url = URL(string: urlString) else {
            throw ClientError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

        // Add GitHub token if available (for higher rate limits)
        if let token = ProcessInfo.processInfo.environment["GITHUB_TOKEN"] {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await urlSession.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ClientError.invalidResponse
            }

            switch httpResponse.statusCode {
            case 200:
                // Single file or directory
                if let items = try? decoder.decode([GitHubContentItem].self, from: data) {
                    return items
                } else if let item = try? decoder.decode(GitHubContentItem.self, from: data) {
                    return [item]
                } else {
                    throw ClientError.decodeError
                }
            case 401:
                throw ClientError.httpError(401, "Unauthorized")
            case 403:
                throw ClientError.httpError(403, "Rate limited or forbidden")
            case 404:
                throw ClientError.httpError(404, "Repository or path not found")
            default:
                throw ClientError.httpError(httpResponse.statusCode, nil)
            }
        } catch let error as ClientError {
            throw error
        } catch {
            throw ClientError.networkError(error)
        }
    }

    private func downloadDirectory(
        owner: String,
        repo: String,
        path: String,
        ref: String,
        destination: URL
    ) async throws -> [String] {
        let contents = try await fetchRepositoryContents(
            owner: owner,
            repo: repo,
            path: path,
            ref: ref
        )

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        var downloadedFiles: [String] = []

        for item in contents {
            let fileURL = destination.appendingPathComponent(item.name)

            if item.type == "file" {
                guard let downloadURL = item.downloadUrl else {
                    continue
                }
                do {
                    try await downloadFile(from: downloadURL, to: fileURL)
                    downloadedFiles.append(item.name)
                } catch {
                    continue
                }
            } else if item.type == "dir" {
                let subDir = destination.appendingPathComponent(item.name)
                let subFiles = try await downloadDirectory(
                    owner: owner,
                    repo: repo,
                    path: item.path,
                    ref: ref,
                    destination: subDir
                )
                downloadedFiles.append(contentsOf: subFiles.map { "\(item.name)/\($0)" })
            }
        }

        return downloadedFiles
    }

    private func downloadFile(from urlString: String, to destination: URL) async throws {
        guard let url = URL(string: urlString) else {
            throw ClientError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3.raw", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await urlSession.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ClientError.invalidResponse
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                throw ClientError.httpError(httpResponse.statusCode, nil)
            }

            try data.write(to: destination)
        } catch let error as ClientError {
            throw error
        } catch {
            throw ClientError.fileWriteError(error)
        }
    }

    private func extractSkillMetadata(from url: URL) throws -> SkillMetadata {
        let data = try Data(contentsOf: url)
        return try decoder.decode(SkillMetadata.self, from: data)
    }

    private func extractDescriptionFromReadme(_ content: String) -> String? {
        // Extract first paragraph that looks like a description
        let lines = content.components(separatedBy: .newlines)

        // Skip the title line (# Title)
        var foundTitle = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("# ") {
                foundTitle = true
                continue
            }

            if foundTitle && !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                // Return first non-empty, non-header line
                return trimmed
            }
        }

        return nil
    }
}

// MARK: - Supporting Types

extension SkillsGitHubClient {
    struct GitHubContentItem: Codable {
        let name: String
        let path: String
        let type: String // "file" or "dir"
        // GitHub returns `null` for directories.
        let downloadUrl: String?

        enum CodingKeys: String, CodingKey {
            case name
            case path
            case type
            case downloadUrl = "download_url"
        }
    }

    struct SkillMetadata: Codable {
        let name: String?
        let description: String?
        let version: String?
    }

    struct DownloadedSkill {
        let owner: String
        let repo: String
        let name: String
        let description: String?
        let version: String
        let files: [String]
        let localPath: String
    }
}
