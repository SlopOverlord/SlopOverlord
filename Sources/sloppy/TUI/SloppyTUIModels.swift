import Protocols

enum SloppyTUIPickerKind: Equatable {
    case model
    case agent
    case session
    case subSession
    case provider
    case providerCatalog
    case projectFile
    case projectTask
    case planInput
}

struct SloppyTUIPickerItem {
    var value: String
    var label: String
    var description: String?
    var isCurrent: Bool
    var group: String? = nil
}

struct SloppyTUIPicker {
    var kind: SloppyTUIPickerKind
    var title: String
    var items: [SloppyTUIPickerItem]
    var selectedIndex: Int
    var allItems: [SloppyTUIPickerItem]? = nil
    var searchQuery: String = ""
    var supportsSearch: Bool = false

    var totalItemCount: Int {
        allItems?.count ?? items.count
    }

    mutating func appendSearchCharacter(_ character: Character) {
        setSearchQuery(searchQuery + String(character))
    }

    mutating func removeLastSearchCharacter() {
        guard !searchQuery.isEmpty else { return }
        var updated = searchQuery
        updated.removeLast()
        setSearchQuery(updated)
    }

    mutating func clearSearchQuery() {
        setSearchQuery("")
    }

    mutating func setSearchQuery(_ query: String) {
        guard supportsSearch, let allItems else { return }
        let previousValue = items.indices.contains(selectedIndex) ? items[selectedIndex].value : nil
        searchQuery = query
        items = Self.filteredItems(allItems, query: query)
        if let previousValue,
           let nextIndex = items.firstIndex(where: { $0.value == previousValue }) {
            selectedIndex = nextIndex
        } else {
            selectedIndex = 0
        }
    }

    static func filteredItems(_ items: [SloppyTUIPickerItem], query: String) -> [SloppyTUIPickerItem] {
        let tokens = query
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !tokens.isEmpty else { return items }
        return items.filter { item in
            let haystack = [
                item.value,
                item.label,
                item.description ?? "",
                item.group ?? "",
            ].joined(separator: " ")
            return tokens.allSatisfy { token in
                haystack.localizedCaseInsensitiveContains(token)
            }
        }
    }
}

struct SloppyTUILocalCard {
    var id: Int
    var block: SloppyTUITimelineBlock
}

enum SloppyTUIWelcomeVisibility {
    static func shouldRender(
        welcomeDismissed: Bool,
        hasSessionCards: Bool,
        hasLiveAssistantDraft: Bool,
        hasQueuedMessages: Bool,
        hasLocalCards: Bool,
        hasTransientNotice: Bool
    ) -> Bool {
        !welcomeDismissed
            && !hasSessionCards
            && !hasLiveAssistantDraft
            && !hasQueuedMessages
            && !hasLocalCards
            && !hasTransientNotice
    }
}

struct SloppyTUISubSessionCard: Equatable {
    var childSessionId: String
    var title: String
    var status: SloppyTUISubSessionStatus = .starting
}

struct SloppyTUITokenUsageSummary: Equatable {
    var promptTokens: Int
    var completionTokens: Int
    var totalTokens: Int
    var contextWindowTokens: Int
    var costUSD: Double?

    var usagePercent: Int? {
        guard contextWindowTokens > 0 else {
            return nil
        }
        return min(100, Int(((Double(totalTokens) / Double(contextWindowTokens)) * 100).rounded()))
    }
}

enum SloppyTUISubSessionStatus: Equatable {
    case starting
    case running(String?)
    case waiting(String?)
    case done
    case interrupted(String?)
}

enum SloppyTUITimelineBlock {
    case message(role: AgentMessageRole, text: String)
    case local(String)
    case queuedMessage(SloppyTUIQueuedMessage)
    case error(String)
    case thinking(String)
    case attachment(name: String, mimeType: String, sizeBytes: Int)
    case subSession(childSessionId: String, title: String, status: SloppyTUISubSessionStatus)
    case buildProgress(AgentBuildProgressEvent)
    case inputRequest(PlanInputRequest)
    case toolCall(tool: String, reason: String?, summary: String?, details: String?)
    case toolResult(tool: String, ok: Bool, error: String?, durationMs: Int?, details: String?)

    var plainText: String {
        switch self {
        case .message(_, let text), .local(let text), .error(let text):
            return text
        case .queuedMessage(let message):
            return "Queued message\n\(message.displayText)"
        case .thinking(let text):
            return text
        case .attachment(let name, let mimeType, _):
            return "\(name) \(mimeType)"
        case .subSession(let childSessionId, let title, let status):
            return "\(title) \(childSessionId) \(status.plainText)"
        case .buildProgress(let progress):
            let items = progress.items.map { "\($0.title) \($0.status.rawValue) \($0.definitionOfDone)" }
            return ([progress.title] + items).joined(separator: " ")
        case .inputRequest(let request):
            return SloppyTUIPlanInputPicker.requestText(request)
        case .toolCall(let tool, let reason, let summary, let details):
            return ([tool] + [summary, reason, details].compactMap { $0 }).joined(separator: " ")
        case .toolResult(let tool, _, let error, _, let details):
            return ([tool] + [error, details].compactMap { $0 }).joined(separator: " ")
        }
    }
}

extension SloppyTUISubSessionStatus {
    var plainText: String {
        switch self {
        case .starting:
            return "starting"
        case .running(let label):
            if let label, !label.isEmpty {
                return "working: \(label)"
            }
            return "working"
        case .waiting(let label):
            if let label, !label.isEmpty {
                return "waiting: \(label)"
            }
            return "waiting"
        case .done:
            return "done"
        case .interrupted(let label):
            if let label, !label.isEmpty {
                return "stopped: \(label)"
            }
            return "stopped"
        }
    }
}

enum SloppyTUIPlanInputPicker {
    static func picker(for request: PlanInputRequest, selectedIndex: Int = 0) -> SloppyTUIPicker? {
        let items = selectionItems(for: request)
        guard !items.isEmpty else {
            return nil
        }
        let title: String
        if request.questions.count == 1, let question = request.questions.first {
            title = question.header ?? question.question
        } else {
            title = request.title ?? "Input needed"
        }
        return SloppyTUIPicker(
            kind: .planInput,
            title: title,
            items: items,
            selectedIndex: max(0, min(selectedIndex, items.count - 1))
        )
    }

    static func selectionItems(for request: PlanInputRequest) -> [SloppyTUIPickerItem] {
        let questions = request.questions.filter { !$0.options.isEmpty }
        guard questions.count == request.questions.count else {
            return []
        }
        if questions.count == 1, let question = questions.first {
            return question.options.map { option in
                SloppyTUIPickerItem(
                    value: encodedValue([(question.id, option.id)]),
                    label: option.label,
                    description: option.description,
                    isCurrent: false
                )
            }
        }

        let combinations = optionCombinations(for: questions)
        return combinations.map { answers in
            let labels = answers.compactMap { questionID, optionID -> String? in
                questions
                    .first(where: { $0.id == questionID })?
                    .options
                    .first(where: { $0.id == optionID })?
                    .label
            }
            let description = answers.compactMap { questionID, optionID -> String? in
                guard let question = questions.first(where: { $0.id == questionID }),
                      let option = question.options.first(where: { $0.id == optionID })
                else {
                    return nil
                }
                let label = question.header ?? question.question
                return "\(label): \(option.label)"
            }.joined(separator: " | ")
            return SloppyTUIPickerItem(
                value: encodedValue(answers),
                label: labels.joined(separator: " / "),
                description: description,
                isCurrent: false
            )
        }
    }

    static func answerRequest(
        for item: SloppyTUIPickerItem,
        request: PlanInputRequest,
        userID: String = "tui"
    ) -> PlanInputAnswerRequest? {
        let decoded = decodedValue(item.value)
        guard decoded.count == request.questions.count else {
            return nil
        }
        var selectedByQuestion: [String: String] = [:]
        for (questionID, optionID) in decoded {
            selectedByQuestion[questionID] = optionID
        }
        let answers: [PlanInputAnswer] = request.questions.compactMap { question in
            guard let optionID = selectedByQuestion[question.id],
                  question.options.contains(where: { $0.id == optionID })
            else {
                return nil
            }
            return PlanInputAnswer(questionId: question.id, selectedOptionId: optionID)
        }
        guard answers.count == request.questions.count else {
            return nil
        }
        return PlanInputAnswerRequest(answers: answers, userId: userID)
    }

    static func requestText(_ request: PlanInputRequest) -> String {
        let title = request.title ?? "Input needed"
        let questionText = request.questions.map { question -> String in
            let header = question.header.map { "\($0)\n" } ?? ""
            let options = question.options.map { option -> String in
                let suffix = option.description.map { " - \($0)" } ?? ""
                return "- \(option.label)\(suffix)"
            }.joined(separator: "\n")
            return "\(header)\(question.question)\n\(options)"
        }.joined(separator: "\n\n")
        return "## \(title)\n\(questionText)"
    }

    private static func optionCombinations(for questions: [PlanInputQuestion]) -> [[(String, String)]] {
        questions.reduce([[]]) { combinations, question in
            combinations.flatMap { prefix in
                question.options.map { option in
                    prefix + [(question.id, option.id)]
                }
            }
        }
    }

    private static func encodedValue(_ answers: [(String, String)]) -> String {
        answers.map { "\($0.0)=\($0.1)" }.joined(separator: "|")
    }

    private static func decodedValue(_ value: String) -> [(String, String)] {
        value.split(separator: "|").compactMap { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                return nil
            }
            return (String(parts[0]), String(parts[1]))
        }
    }
}

extension AgentChatMode {
    var next: AgentChatMode {
        switch self {
        case .ask: return .build
        case .build: return .plan
        case .plan: return .debug
        case .debug: return .ask
        }
    }

    var title: String {
        switch self {
        case .ask: return "Ask"
        case .build: return "Build"
        case .plan: return "Plan"
        case .debug: return "Debug"
        }
    }
}
