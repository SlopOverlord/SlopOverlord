import Foundation
import Protocols

private let requiredPlanningTaskBriefHeadings = [
    "Goal",
    "Context",
    "Definition of Done",
    "Tests / Verification"
]

func planningTaskBriefIsRequired(kind: ProjectTaskKind?, status: String?) -> Bool {
    if kind == .planning {
        return true
    }
    let normalizedStatus = status?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    return normalizedStatus == ProjectTaskStatus.pendingApproval.rawValue
}

func missingRequiredPlanningTaskBriefHeadings(in description: String?) -> [String] {
    let headingLines = Set(
        (description ?? "")
            .split(whereSeparator: \.isNewline)
            .map { line in
                line.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                    .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            }
            .filter { $0.hasPrefix("## ") }
    )

    return requiredPlanningTaskBriefHeadings.filter { heading in
        !headingLines.contains("## \(heading.lowercased())")
    }
}

func planningTaskBriefValidationFailure(tool: String, missingHeadings: [String]) -> ToolInvocationResult {
    let missing = missingHeadings.map { "`## \($0)`" }.joined(separator: ", ")
    return toolFailure(
        tool: tool,
        code: "task_brief_required",
        message: "Planning and pending-approval tasks require a structured task brief. Missing headings: \(missing).",
        retryable: true,
        hint:
            """
            Retry with `description` containing the full planning handoff, not a short summary:

            ## Goal
            <Outcome to achieve.>

            ## Context
            <Relevant findings, files, risks, hypotheses, and user decisions from planning.>

            ## Definition of Done
            <Observable acceptance criteria.>

            ## Tests / Verification
            <Exact commands, builds, manual checks, or evidence expected.>
            """
    )
}
