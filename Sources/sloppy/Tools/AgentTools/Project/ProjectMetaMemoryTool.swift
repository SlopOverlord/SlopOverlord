import AnyLanguageModel
import Foundation
import Protocols

struct ProjectMetaMemoryTool: CoreTool {
    let domain = "project"
    let title = "Set project .meta/MEMORY.md"
    let status = "fully_functional"
    let name = "project.meta_memory_set"
    let description = "Writes workspace-private `projects/<projectId>/.meta/MEMORY.md` (max \(AgentMarkdownLimits.projectMetaMemoryMarkdownMaxCharacters) characters)."

    var parameters: GenerationSchema {
        .objectSchema([
            .init(name: "projectId", description: "Project id", schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "content", description: "Markdown body", schema: DynamicGenerationSchema(type: String.self))
        ])
    }

    func invoke(arguments: [String: JSONValue], context: ToolContext) async -> ToolInvocationResult {
        let projectId = arguments["projectId"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let content = arguments["content"]?.asString ?? ""
        guard !projectId.isEmpty else {
            return toolFailure(tool: name, code: "invalid_arguments", message: "`projectId` is required.", retryable: false)
        }
        guard let projectService = context.projectService else {
            return toolFailure(tool: name, code: "not_available", message: "Project tools are not available.", retryable: false)
        }
        do {
            try AgentMarkdownLimits.validateProjectMetaMemoryMarkdown(content)
        } catch let error as AgentDocumentLengthError {
            if case .exceeded(let resource, let limit) = error {
                return toolFailure(
                    tool: name,
                    code: "document_too_long",
                    message: "\(resource) exceeds the limit of \(limit) characters. Remove content or store it elsewhere.",
                    retryable: false
                )
            }
            return toolFailure(tool: name, code: "invalid_arguments", message: "Invalid content.", retryable: false)
        } catch {
            return toolFailure(tool: name, code: "invalid_arguments", message: "Invalid content.", retryable: false)
        }

        do {
            let project = try await projectService.getProject(id: projectId)
            let root = context.workspaceRootURL
                .appendingPathComponent("projects", isDirectory: true)
                .appendingPathComponent(project.id, isDirectory: true)
                .standardizedFileURL
            let metaDir = root.appendingPathComponent(".meta", isDirectory: true)
            let dest = metaDir.appendingPathComponent("MEMORY.md", isDirectory: false)
            try FileManager.default.createDirectory(at: metaDir, withIntermediateDirectories: true)
            try content.write(to: dest, atomically: true, encoding: .utf8)
            return toolSuccess(tool: name, data: .object([
                "path": .string(dest.path),
                "chars": .number(Double(content.count))
            ]))
        } catch {
            return toolFailure(tool: name, code: "write_failed", message: error.localizedDescription, retryable: true)
        }
    }
}
