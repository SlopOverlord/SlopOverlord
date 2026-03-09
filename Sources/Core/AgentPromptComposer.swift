import Foundation
import Logging
import Protocols

struct AgentPromptComposer {
    enum ComposerError: Error {
        case unsupportedProcess
    }

    private let templateLoader: PromptTemplateLoader
    private let templateRenderer: PromptTemplateRenderer
    private let logger: Logger

    init(
        templateLoader: PromptTemplateLoader = PromptTemplateLoader(),
        templateRenderer: PromptTemplateRenderer = PromptTemplateRenderer(),
        logger: Logger = Logger(label: "sloppy.core.prompts")
    ) {
        self.templateLoader = templateLoader
        self.templateRenderer = templateRenderer
        self.logger = logger
    }

    func compose(context: PromptRenderContext) throws -> String {
        switch context.processKind {
        case .agentSessionBootstrap:
            return try composeAgentSessionBootstrap(context: context)
        case .swarmPlanner:
            throw ComposerError.unsupportedProcess
        }
    }

    private func composeAgentSessionBootstrap(context: PromptRenderContext) throws -> String {
        guard let sessionID = context.sessionID,
              let bootstrapMarker = context.bootstrapMarker,
              let documents = context.documents
        else {
            throw ComposerError.unsupportedProcess
        }

        let capabilitiesSection = try renderPartial(
            named: "session_capabilities",
            values: [:]
        )
        let runtimeRulesSection = try renderPartial(
            named: "runtime_rules",
            values: [:]
        )
        let toolsInstructionSection = try renderPartial(
            named: "tools_instruction",
            values: [:]
        )
        let skillsSection = try renderSkillsSection(skills: context.installedSkills)
        let template = try templateLoader.loadTemplate(for: .agentSessionBootstrap)

        return try templateRenderer.render(
            template: template,
            values: [
                "bootstrap_marker": bootstrapMarker,
                "agent_id": context.agentID,
                "session_id": sessionID,
                "agents_markdown": documents.agentsMarkdown,
                "user_markdown": documents.userMarkdown,
                "identity_markdown": documents.identityMarkdown,
                "soul_markdown": documents.soulMarkdown,
                "skills_section": skillsSection,
                "process_capabilities_section": capabilitiesSection,
                "runtime_rules_section": runtimeRulesSection,
                "tools_instruction_section": toolsInstructionSection
            ]
        )
    }

    private func renderPartial(named name: String, values: [String: String]) throws -> String {
        let template = try templateLoader.loadPartial(named: name)
        return try templateRenderer.render(template: template, values: values)
    }

    private func renderSkillsSection(skills: [InstalledSkill]) throws -> String {
        let renderedEntries: String
        if skills.isEmpty {
            renderedEntries = "- No additional skills installed."
        } else {
            renderedEntries = skills
                .sorted { lhs, rhs in
                    lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                .map { skill in
                    let description = skill.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if description.isEmpty {
                        return "- `\(skill.id)` | \(skill.name) | path: `\(skill.localPath)`"
                    }
                    return "- `\(skill.id)` | \(skill.name) | \(description) | path: `\(skill.localPath)`"
                }
                .joined(separator: "\n")
        }

        do {
            return try renderPartial(
                named: "skills_summary",
                values: ["skills_entries": renderedEntries]
            )
        } catch {
            logger.warning(
                "Skills summary partial rendering failed",
                metadata: [
                    "skills_count": .stringConvertible(skills.count),
                    "error": .string(String(describing: error))
                ]
            )
            throw error
        }
    }
}
