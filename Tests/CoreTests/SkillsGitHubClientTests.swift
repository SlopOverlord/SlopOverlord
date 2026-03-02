import Foundation
import Testing
@testable import Core

@Test
func gitHubContentItemDecodesDirectoryWithNullDownloadURL() throws {
    let payload = """
    {
      "name": "skills",
      "path": "skills",
      "type": "dir",
      "download_url": null
    }
    """.data(using: .utf8)!

    let item = try JSONDecoder().decode(SkillsGitHubClient.GitHubContentItem.self, from: payload)

    #expect(item.name == "skills")
    #expect(item.type == "dir")
    #expect(item.downloadUrl == nil)
}

@Test
func gitHubContentItemDecodesFileWithDownloadURL() throws {
    let payload = """
    {
      "name": "README.md",
      "path": "README.md",
      "type": "file",
      "download_url": "https://raw.githubusercontent.com/example/repo/main/README.md"
    }
    """.data(using: .utf8)!

    let item = try JSONDecoder().decode(SkillsGitHubClient.GitHubContentItem.self, from: payload)

    #expect(item.name == "README.md")
    #expect(item.type == "file")
    #expect(item.downloadUrl == "https://raw.githubusercontent.com/example/repo/main/README.md")
}
