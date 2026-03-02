import Foundation
import Testing
@testable import Core

@Test
func decodeSkillsResponseParsesItemsPayload() throws {
    let payload = """
    {
      "items": [
        {
          "id": "acme/chat-ui",
          "owner": {
            "login": "acme"
          },
          "repository": "skills",
          "name": "chat-ui",
          "description": "Chat UI toolkit",
          "installs": 1234,
          "github_url": "https://github.com/acme/skills"
        }
      ],
      "totalCount": 128
    }
    """.data(using: .utf8)!

    let decoded = SkillsRegistryService.decodeSkillsResponse(from: payload)

    #expect(decoded?.total == 128)
    #expect(decoded?.skills.count == 1)
    #expect(decoded?.skills.first?.id == "acme/chat-ui")
    #expect(decoded?.skills.first?.owner == "acme")
    #expect(decoded?.skills.first?.repo == "skills")
    #expect(decoded?.skills.first?.name == "chat-ui")
}

@Test
func decodeSkillsResponseParsesDataPayloadWithMetaTotal() throws {
    let payload = """
    {
      "data": [
        {
          "slug": "teamx/chat-ui",
          "owner": "teamx",
          "repo": "skills",
          "title": "chat-ui",
          "summary": "Reusable chat components",
          "download_count": "77",
          "repository_url": "https://github.com/teamx/skills"
        }
      ],
      "meta": {
        "total": 9001
      }
    }
    """.data(using: .utf8)!

    let decoded = SkillsRegistryService.decodeSkillsResponse(from: payload)

    #expect(decoded?.total == 9001)
    #expect(decoded?.skills.count == 1)
    #expect(decoded?.skills.first?.id == "teamx/chat-ui")
    #expect(decoded?.skills.first?.installs == 77)
}

@Test
func parseSkillsFromHTMLExtractsSkillLinks() throws {
    let html = """
    <html>
      <body>
        <a href="/sergiopaladino/claude-code-skills/chat-ui">chat-ui</a>
        <a href="/anthropics/skills/frontend-design">frontend-design</a>
      </body>
    </html>
    """

    let parsed = SkillsRegistryService.parseSkillsFromHTML(html)

    #expect(parsed.contains(where: { $0.id == "sergiopaladino/chat-ui" && $0.repo == "claude-code-skills" }))
    #expect(parsed.contains(where: { $0.id == "anthropics/frontend-design" && $0.repo == "skills" }))
}

@Test
func parseSkillsFromHTMLExtractsInstallsFromCardMarkup() throws {
    let html = """
    <html>
      <body>
        <a href="/anthropics/skills/frontend-design">frontend-design</a>
        <span>111.9k installs</span>
      </body>
    </html>
    """

    let parsed = SkillsRegistryService.parseSkillsFromHTML(html)
    let skill = parsed.first(where: { $0.id == "anthropics/frontend-design" })

    #expect(skill?.installs == 111_900)
}
