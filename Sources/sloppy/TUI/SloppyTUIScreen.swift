import Foundation
#if canImport(AppKit)
import AppKit
#endif
import ChannelPluginSupport
import Protocols
import TauTUI

private enum SloppyTUIAttachmentLimits {
    static let maxBytes = 25 * 1024 * 1024
}

private enum SloppyTUIStreamTyping {
    static let intervalNanoseconds: UInt64 = 32_000_000
    static let intervalSeconds = 0.032
    static let charactersPerSecond = 90.0
    static let maxCatchupSeconds = 0.85
}

enum SloppyTUILiveDraftPolicy {
    static func shouldInterpolate(current: String, target: String) -> Bool {
        guard !target.isEmpty,
              target.hasPrefix(current),
              target.count > current.count else {
            return false
        }

        if current.contains("\n") || target.contains("\n") || target.count > 240 {
            return false
        }

        return !hasMarkdownControlPrefix(target)
    }

    private static func hasMarkdownControlPrefix(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }

        if trimmed.hasPrefix("#") || trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("> ") {
            return true
        }

        var sawDigit = false
        for scalar in trimmed.unicodeScalars {
            if CharacterSet.decimalDigits.contains(scalar) {
                sawDigit = true
                continue
            }
            return sawDigit && scalar == "."
        }

        return false
    }
}

private enum SloppyTUILocalCardBehavior {
    static let autoDismissSeconds: TimeInterval = 10
    static let autoDismissLineLimit = 3
    static let autoDismissCharacterLimit = 320
}

private enum SloppyTUITimelinePerformance {
    static let animatedSessionBlockLimit = 80
}

private struct SloppyTUISessionTimelineCache {
    var revision: Int
    var width: Int
    var transcriptExpanded: Bool
    var animationFrameKey: Int
    var lines: [String]
    var containsToolTranscriptBlock: Bool
}

private extension Array where Element == String {
    func trimmingEmptyEdges() -> [String] {
        var startIndex = self.startIndex
        var endIndex = self.endIndex

        while startIndex < endIndex, self[startIndex].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            startIndex = index(after: startIndex)
        }
        while endIndex > startIndex {
            let previousIndex = index(before: endIndex)
            guard self[previousIndex].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                break
            }
            endIndex = previousIndex
        }

        return Array(self[startIndex..<endIndex])
    }
}

private enum SloppyTUIAttachmentError: LocalizedError {
    case notAFile
    case tooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .notAFile:
            return "not a file"
        case .tooLarge(let bytes):
            return "file is too large (\(bytes) bytes)"
        }
    }
}

@MainActor
final class SloppyTUIScreen: @preconcurrency Component, @unchecked Sendable {
    let editor = Editor()
    var onExit: (@MainActor @Sendable () -> Void)?

    private static let baseSlashCommands = [
        SloppyTUISlashCommand("help", "Show TUI commands"),
        SloppyTUISlashCommand("status", "Show session status"),
        SloppyTUISlashCommand("pet", "Toggle Sloppie pet and show terminal face status"),
        SloppyTUISlashCommand("agents", "Switch agent"),
        SloppyTUISlashCommand("sessions", "Switch session"),
        SloppyTUISlashCommand("subagents", "Open a child subagent session"),
        SloppyTUISlashCommand("parent", "Return to the parent session"),
        SloppyTUISlashCommand("new", "Create a new session"),
        SloppyTUISlashCommand("clear", "Clear local cards"),
        SloppyTUISlashCommand("stop", "Interrupt the current run"),
        SloppyTUISlashCommand("restore", "Restart the current session after a failed run"),
        SloppyTUISlashCommand("up", "Alias for restore"),
        SloppyTUISlashCommand("undo", "Undo file changes from the last completed turn"),
        SloppyTUISlashCommand("redo", "Redo the last undone turn"),
        SloppyTUISlashCommand("btw", "Ask a quick side question without interrupting the main conversation", argument: "message"),
        SloppyTUISlashCommand("compact", "Free up context by summarizing the conversation so far"),
        SloppyTUISlashCommand("add_dir", "Add a working directory to this session", argument: "path"),
        SloppyTUISlashCommand("fork", "Create a branch of the current conversation", argument: "task"),
        SloppyTUISlashCommand("bar", "Change color bar", argument: "color"),
        SloppyTUISlashCommand("copy", "Copy last agent response to clipboard"),
        SloppyTUISlashCommand("diff", "Show uncommitted changes and per-turn diffs"),
        SloppyTUISlashCommand("effort", "Set reasoning effort level", argument: "low|medium|high"),
        SloppyTUISlashCommand("skills", "Show enabled skills"),
        SloppyTUISlashCommand("editor", "Open code editor, optionally choose cursor/xcode/code"),
        SloppyTUISlashCommand("model", "Switch agent model"),
        SloppyTUISlashCommand("context", "Attach changes or git diff", argument: "changes|diff"),
        SloppyTUISlashCommand("tasks", "Show project tasks"),
        SloppyTUISlashCommand("mcps", "Show MCP server statuses"),
        SloppyTUISlashCommand("provider", "Configure provider"),
        SloppyTUISlashCommand("quit", "Exit TUI"),
    ]
    private static let handledSlashCommandNames: Set<String> = [
        "help",
        "status",
        "pet",
        "agents",
        "agent",
        "subagents",
        "children",
        "parent",
        "back",
        "sessions",
        "session",
        "new",
        "clear",
        "stop",
        "restore",
        "up",
        "undo",
        "redo",
        "btw",
        "compact",
        "add_dir",
        "add-dir",
        "fork",
        "bar",
        "copy",
        "diff",
        "effort",
        "skills",
        "editor",
        "model",
        "context",
        "tasks",
        "mcps",
        "mcp",
        "provider",
        "providers",
        "openai-device",
        "anthropic-oauth",
        "anthropic-callback",
        "quit",
        "exit",
    ]

    private static let firstStartBootstrapCard = """
    ## First start bootstrap
    Configure a provider with `/provider <id> <key> [model]`, `/openai-device`, or `/anthropic-oauth`.
    Type the launch prompt when ready; Sloppy will create the onboarding session turn and mark onboarding complete.
    """

    private let runtime: SloppyTUIRuntime
    private let desktopNotificationService = DesktopNotificationService.live()
    private var project: ProjectRecord
    private var agent: AgentSummary
    private var session: AgentSessionSummary
    private var hasPersistedSession: Bool
    private let stateStore: SloppyTUIStateStore
    private var state: SloppyTUIState
    private let welcomeTipCursor: Int
    private let initialAction: SloppyTUIInitialAction
    private weak var tui: TUI?
    private weak var terminal: Terminal?

    private let header = Text(paddingX: 1, paddingY: 0)
    private let timeline = MarkdownComponent(padding: .init(horizontal: 1, vertical: 0))
    private let status = Text(paddingX: 1, paddingY: 0)

    private var sessionCards: [SloppyTUITimelineBlock] = []
    private var localCards: [SloppyTUILocalCard] = []
    private var subSessionCards: [SloppyTUISubSessionCard] = []
    private var pendingContext: String?
    private var pendingUploads: [AgentAttachmentUpload] = []
    private var pendingDraftCheckpointSessionID: String?
    private var chatMode: AgentChatMode = .build
    private var selectedModel = "default"
    private var selectedModelContextWindowTokens = 0
    private var reasoningEffort: ReasoningEffort?
    private var skillSlashCommands: [SloppyTUISlashCommand] = []
    private var skillSlashCommandNames: Set<String> = []
    private var commandPaletteSelection = 0
    private var streamTask: Task<Void, Never>?
    private var changeTask: Task<Void, Never>?
    private var devicePollTask: Task<Void, Never>?
    private var thinkingAnimationTask: Task<Void, Never>?
    private var projectFileIndexTask: Task<Void, Never>?
    private var projectFileReindexTask: Task<Void, Never>?
    private var lastChangeBatch: ProjectWorkingTreeChangeBatch?
    private var lastRenderedSessionEventIDs: Set<String> = []
    private var activePicker: SloppyTUIPicker?
    private var pendingPlanInputRequest: PlanInputRequest?
    private var tokenUsageSummary: SloppyTUITokenUsageSummary?
    private var tokenUsageCostUSD: Double?
    private var projectFileIndex: ProjectFileIndex?
    private var projectFileRootURL: URL?
    private var projectFileIndexLoading = false
    private var projectFileSearchSelection = 0
    private var suppressedProjectFileSearch: SloppyTUIProjectPathSearchSuppression?
    private var projectFileIndexGeneration = 0
    private var projectFileSearchCache: (generation: Int, token: String, items: [SloppyTUIPickerItem])?
    private var restoredDirectorySessionKeys: Set<String> = []
    private var projectTaskSearchSelection = 0
    private var projectTaskAutocompleteLoading = false
    private var projectTaskAutocompleteTask: Task<Void, Never>?
    private var suppressedProjectTaskSearch: SloppyTUITaskReferenceSearchSuppression?
    private var projectTaskGeneration = 0
    private var projectTaskSearchCache: (generation: Int, token: String, items: [SloppyTUIPickerItem])?
    private var liveAssistantDraft: String?
    private var liveAssistantTarget: String?
    private var liveAssistantInterpolationTask: Task<Void, Never>?
    private var liveRunStatusLine: String?
    private var taskStartedAt: Date?
    private var lastTaskElapsed: TimeInterval?
    private var transientNoticeLine: String?
    private var transientNoticeTask: Task<Void, Never>?
    private var transcriptExpanded = false
    private var sessionUndoManagers = SloppyTUISessionUndoManagers()
    private var thinkingFrame = 0
    private var thinkingWord = "thinking"
    private var petMood: AgentPetAnimationState = .idle
    private var welcomeDismissed = false
    private var isPosting = false
    private var queuedMessages = SloppyTUIMessageQueue()
    private var isDrainingQueuedMessages = false
    private var isInterruptingRun = false
    private var isExiting = false
    private var controlCExitDetector = SloppyTUIControlCExitDetector()
    private var exitAfterModelSelection = false
    private var nextLocalCardID = 0
    private var localCardDismissTasks: [Int: Task<Void, Never>] = [:]
    private var timelineScrollOffset = 0
    private var lastTimelineViewportHeight = 1
    private var sessionTimelineRevision = 0
    private var sessionTimelineCache: SloppyTUISessionTimelineCache?

    init(
        runtime: SloppyTUIRuntime,
        project: ProjectRecord,
        agent: AgentSummary,
        session: AgentSessionSummary,
        hasPersistedSession: Bool,
        stateStore: SloppyTUIStateStore,
        state: SloppyTUIState,
        welcomeTipCursor: Int = 0,
        initialAction: SloppyTUIInitialAction = .none,
        tui: TUI,
        terminal: Terminal
    ) {
        self.runtime = runtime
        self.project = project
        self.agent = agent
        self.session = session
        self.hasPersistedSession = hasPersistedSession
        self.stateStore = stateStore
        self.state = state
        self.welcomeTipCursor = welcomeTipCursor
        self.initialAction = initialAction
        self.tui = tui
        self.terminal = terminal

        editor.apply(theme: SloppyTUITheme.palette)
        if SloppyTUIAutocompleteFeatureFlags.editorAutocompleteEnabled {
            editor.setAutocompleteProvider(SloppyTUIAutocompleteProvider(basePath: runtime.cwd))
        }
        editor.onSubmit = { [weak self] value in
            guard let self else { return }
            Task { @MainActor in await self.submit(value) }
        }
        editor.onChange = { [weak self] value in
            self?.persistDraft(value)
            self?.projectFileSearchSelection = 0
            self?.projectFileSearchCache = nil
            self?.projectTaskSearchSelection = 0
            self?.projectTaskSearchCache = nil
            if let suppressed = self?.suppressedProjectFileSearch,
               !suppressed.matches(self?.currentProjectFileToken()) {
                self?.suppressedProjectFileSearch = nil
            }
            if let suppressed = self?.suppressedProjectTaskSearch,
               !suppressed.matches(self?.currentProjectTaskToken()) {
                self?.suppressedProjectTaskSearch = nil
            }
        }
        let draftKey = SloppyTUIStateStore.draftKey(
            projectId: project.id,
            agentId: agent.id,
            sessionId: session.id
        )
        editor.setText(state.drafts[draftKey] ?? "")
        refreshStaticChrome()
        renderTimeline()
    }

    func start() {
        if hasPersistedSession {
            Task { @MainActor in
                await restorePersistedDirectoriesForCurrentSession()
                await reloadSession()
            }
        }
        Task { @MainActor in await reloadSkillSlashCommands() }
        Task { @MainActor in
            await refreshSelectedModel()
            if case .modelPicker(let exitAfterSelection) = initialAction {
                await showModelPicker(exitAfterSelection: exitAfterSelection)
            }
        }
        if hasPersistedSession {
            streamSession()
        }
        streamChanges()
        loadProjectFileIndex()
        reloadProjectForTaskAutocompleteIfNeeded()
        if !runtime.config.onboarding.completed {
            appendLocalCard(Self.firstStartBootstrapCard)
        }
    }

    func stopBackgroundTasks() {
        streamTask?.cancel()
        changeTask?.cancel()
        devicePollTask?.cancel()
        thinkingAnimationTask?.cancel()
        projectFileIndexTask?.cancel()
        projectTaskAutocompleteTask?.cancel()
        projectFileReindexTask?.cancel()
        transientNoticeTask?.cancel()
        transientNoticeTask = nil
        cancelLocalCardDismissTasks()
    }

    func render(width: Int) -> [String] {
        let height = max(terminal?.rows ?? 24, 12)
        let lines = renderBaseScreen(width: width, height: height)
        return SloppyTUITheme.normalize(lines: lines, width: width, height: height)
    }

    func handle(input: TerminalInput) {
        controlCExitDetector.reset()
        if handleQueuedMessageCancel(input) {
            return
        }
        if handleActivePicker(input: input) {
            return
        }
        if handleCommandPalette(input: input) {
            return
        }
        if handleProjectTaskSearchInput(input) {
            return
        }
        if handleProjectFileSearchInput(input) {
            return
        }
        if handleAttachmentInput(input) {
            return
        }
        if handleRunInterrupt(input) {
            return
        }
        if handleModeCycle(input) {
            return
        }
        if handleTranscriptInput(input) {
            return
        }
        if handleTimelineScroll(input) {
            return
        }
        editor.handle(input: input)
    }

    func handleControlC() {
        if controlCExitDetector.shouldExit() {
            Task { @MainActor in
                await self.stopTUI(reason: "TUI Ctrl+C")
            }
            return
        }

        showSystemNotice("Press Ctrl+C again to exit. Active agent run will be interrupted.", autoDismissAfter: 4)
    }

    private func handleQueuedMessageCancel(_ input: TerminalInput) -> Bool {
        guard case .key(.character("b"), let modifiers) = input,
              modifiers.contains(.control)
        else {
            return false
        }

        guard let canceled = queuedMessages.cancelNext() else {
            showSystemNotice("No queued message to cancel.")
            return true
        }

        showSystemNotice("Canceled queued message: \(canceled.displayText)")
        renderTimeline()
        return true
    }

    private func handleRunInterrupt(_ input: TerminalInput) -> Bool {
        guard isPosting, !isInterruptingRun else {
            return false
        }
        guard case .key(.escape, let modifiers) = input, modifiers.isEmpty else {
            return false
        }

        Task { @MainActor in
            await self.interruptCurrentRun(
                reason: "TUI Esc",
                successMessage: "Interrupt requested.",
                failurePrefix: "Interrupt failed",
                useNotice: true
            )
        }
        return true
    }

    private func renderBaseScreen(width: Int, height: Int) -> [String] {
        let footer = SloppyTUITheme.appFooter(width: width, cwd: runtime.cwd)
        var composer = SloppyTUITheme.highlightedComposerLines(editor.render(width: width))
        if isPosting {
            composer.append(SloppyTUITheme.interruptControlLine(
                width: width,
                frame: thinkingFrame,
                isInterrupting: isInterruptingRun
            ))
        }
        composer.append(SloppyTUITheme.composerMetaLine(
            width: width,
            mode: chatMode,
            model: selectedModel,
            agent: agent.displayName,
            provider: providerLabel(from: selectedModel)
        ))
        if let tokenUsageSummary {
            composer.append(SloppyTUITheme.tokenUsageFooterLine(width: width, summary: tokenUsageSummary))
        }
        composer.append(footer)

        if let picker = activePicker {
            composer.insert(contentsOf: SloppyTUITheme.pickerLines(width: width, picker: picker, maxVisible: 9), at: 0)
        } else if let palette = commandPaletteLines(width: width) {
            composer.insert(contentsOf: palette, at: 0)
        } else if let picker = projectTaskSearchPicker() {
            composer.insert(contentsOf: SloppyTUITheme.pickerLines(width: width, picker: picker, maxVisible: 9), at: 0)
        } else if let picker = projectFileSearchPicker() {
            composer.insert(contentsOf: SloppyTUITheme.pickerLines(width: width, picker: picker, maxVisible: 9), at: 0)
        }

        let bodyHeight = max(1, height - composer.count)
        let body = renderBody(width: width, height: bodyHeight)
        return body + composer
    }

    private func renderBody(width: Int, height: Int) -> [String] {
        if shouldRenderWelcome {
            let raw = SloppyTUITheme.welcomeScreen(
                width: width,
                cwd: runtime.cwd,
                project: project.name,
                agent: agent.displayName,
                model: selectedModel,
                mode: chatMode,
                tipOffset: welcomeTipCursor,
                includeFooter: false
            )
            return centerWelcome(raw, height: height)
        }

        let headerLines = header.render(width: width)
        let statusLines = status.render(width: width)
        let timelineHeight = max(1, height - headerLines.count - statusLines.count)
        let visibleTimeline = renderTimelineBlocks(width: width, height: timelineHeight)
        let bottomPadding = max(0, height - headerLines.count - visibleTimeline.count - statusLines.count)
        return headerLines
            + visibleTimeline
            + Array(repeating: "", count: bottomPadding)
            + statusLines
    }

    private func centerWelcome(_ lines: [String], height: Int) -> [String] {
        let content = lines.trimmingEmptyEdges()
        guard content.count < height else {
            return Array(content.suffix(height))
        }

        let topPadding = (height - content.count) / 2
        let bottomPadding = height - content.count - topPadding
        return Array(repeating: "", count: topPadding)
            + content
            + Array(repeating: "", count: bottomPadding)
    }

    private func handleActivePicker(input: TerminalInput) -> Bool {
        guard var picker = activePicker else { return false }
        if picker.supportsSearch, case .paste(let text) = input {
            for character in text where !character.isNewline {
                picker.appendSearchCharacter(character)
            }
            activePicker = picker
            requestRender()
            return true
        }
        guard case let .key(key, modifiers) = input else { return true }
        guard !picker.items.isEmpty || picker.supportsSearch else {
            activePicker = nil
            requestRender()
            return true
        }

        switch key {
        case .arrowUp:
            picker.selectedIndex = picker.items.isEmpty ? 0 : max(0, picker.selectedIndex - 1)
            activePicker = picker
            requestRender()
            return true
        case .arrowDown:
            picker.selectedIndex = picker.items.isEmpty ? 0 : min(picker.items.count - 1, picker.selectedIndex + 1)
            activePicker = picker
            requestRender()
            return true
        case .enter, .tab:
            guard picker.items.indices.contains(picker.selectedIndex) else {
                return true
            }
            let item = picker.items[picker.selectedIndex]
            activePicker = nil
            requestRender()
            Task { @MainActor in
                await self.applyPickerItem(item, kind: picker.kind)
            }
            return true
        case .backspace:
            if picker.supportsSearch {
                picker.removeLastSearchCharacter()
                activePicker = picker
                requestRender()
            }
            return true
        case .delete:
            if picker.supportsSearch {
                picker.clearSearchQuery()
                activePicker = picker
                requestRender()
            }
            return true
        case .character("u") where picker.supportsSearch && modifiers.contains(.control):
            picker.clearSearchQuery()
            activePicker = picker
            requestRender()
            return true
        case .character(let character)
            where picker.supportsSearch
                && !modifiers.contains(.control)
                && !modifiers.contains(.option)
                && !character.isNewline:
            picker.appendSearchCharacter(character)
            activePicker = picker
            requestRender()
            return true
        case .escape:
            if picker.kind == .planInput {
                activePicker = nil
                requestRender()
                Task { @MainActor in
                    await self.cancelPlanInputRequest()
                }
                return true
            }
            activePicker = nil
            if exitAfterModelSelection && picker.kind == .model {
                Task { @MainActor in
                    await self.stopTUI(reason: "TUI model picker")
                }
                return true
            }
            refreshStaticChrome()
            return true
        default:
            return true
        }
    }

    private func handleCommandPalette(input: TerminalInput) -> Bool {
        guard commandPaletteVisible else { return false }
        guard case let .key(key, _) = input else { return false }
        let commands = commandPaletteSuggestions()
        guard !commands.isEmpty else { return false }

        switch key {
        case .arrowUp:
            commandPaletteSelection = max(0, commandPaletteSelection - 1)
            requestRender()
            return true
        case .arrowDown:
            commandPaletteSelection = min(commands.count - 1, commandPaletteSelection + 1)
            requestRender()
            return true
        case .enter, .tab:
            applyCommandPaletteSelection(commands[commandPaletteSelection])
            return true
        case .escape:
            editor.setText("")
            commandPaletteSelection = 0
            requestRender()
            return true
        default:
            return false
        }
    }

    private func handleProjectTaskSearchInput(_ input: TerminalInput) -> Bool {
        guard SloppyTUIAutocompleteFeatureFlags.projectTaskAutocompleteEnabled else {
            return false
        }
        guard case let .key(key, _) = input else { return false }
        switch key {
        case .arrowUp, .arrowDown, .enter, .tab, .escape:
            break
        default:
            return false
        }

        guard let picker = projectTaskSearchPicker() else { return false }
        switch key {
        case .arrowUp:
            projectTaskSearchSelection = max(0, projectTaskSearchSelection - 1)
            requestRender()
            return true
        case .arrowDown:
            projectTaskSearchSelection = min(picker.items.count - 1, projectTaskSearchSelection + 1)
            requestRender()
            return true
        case .enter, .tab:
            guard !picker.items[picker.selectedIndex].value.isEmpty else {
                return true
            }
            applyProjectTaskSearchItem(picker.items[picker.selectedIndex])
            return true
        case .escape:
            if let token = currentProjectTaskToken() {
                suppressedProjectTaskSearch = SloppyTUITaskReferenceSearchSuppression(token: token)
            }
            requestRender()
            return true
        default:
            return false
        }
    }

    private func handleProjectFileSearchInput(_ input: TerminalInput) -> Bool {
        guard SloppyTUIAutocompleteFeatureFlags.projectPathAutocompleteEnabled else {
            return false
        }
        guard case let .key(key, _) = input else { return false }
        switch key {
        case .arrowUp, .arrowDown, .enter, .tab, .escape:
            break
        default:
            return false
        }

        guard let picker = projectFileSearchPicker() else { return false }
        switch key {
        case .arrowUp:
            projectFileSearchSelection = max(0, projectFileSearchSelection - 1)
            requestRender()
            return true
        case .arrowDown:
            projectFileSearchSelection = min(picker.items.count - 1, projectFileSearchSelection + 1)
            requestRender()
            return true
        case .enter, .tab:
            guard !picker.items[picker.selectedIndex].value.isEmpty else {
                return true
            }
            applyProjectFileSearchItem(picker.items[picker.selectedIndex])
            return true
        case .escape:
            if let token = currentProjectFileToken() {
                suppressedProjectFileSearch = SloppyTUIProjectPathSearchSuppression(token: token)
            }
            requestRender()
            return true
        default:
            return false
        }
    }

    private func handleAttachmentInput(_ input: TerminalInput) -> Bool {
        switch input {
        case .paste:
            return false
        case .key(.character("v"), let modifiers) where modifiers.contains(.control):
            if isEditingSingleLineSlashCommand, pasteClipboardTextIntoEditor() {
                return true
            }
            pasteAttachmentFromClipboard()
            return true
        default:
            return false
        }
    }

    private var isEditingSingleLineSlashCommand: Bool {
        let text = editor.getText()
        guard !text.contains("\n") else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/")
    }

    private func pasteClipboardTextIntoEditor() -> Bool {
        #if canImport(AppKit)
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           !urls.isEmpty {
            editor.handle(input: .paste(urls.map(\.path).joined(separator: "\n")))
            return true
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            editor.handle(input: .paste(text))
            return true
        }
        #endif
        return false
    }

    private func handleModeCycle(_ input: TerminalInput) -> Bool {
        guard case .key(.tab, let modifiers) = input, modifiers.isEmpty else {
            return false
        }
        chatMode = chatMode.next
        refreshStaticChrome()
        return true
    }

    private func handleTranscriptInput(_ input: TerminalInput) -> Bool {
        guard case let .key(key, modifiers) = input else {
            return false
        }

        switch key {
        case .character("o") where modifiers.contains(.control):
            transcriptExpanded.toggle()
            refreshStaticChrome()
            renderTimeline()
            return true
        case .character("O") where modifiers.contains(.control):
            transcriptExpanded.toggle()
            refreshStaticChrome()
            renderTimeline()
            return true
        case .character("p") where modifiers.contains(.control):
            Task { @MainActor in await self.openParentSession() }
            return true
        case .character("P") where modifiers.contains(.control):
            Task { @MainActor in await self.openParentSession() }
            return true
        case .character("g") where modifiers.contains(.control):
            Task { @MainActor in await self.openLatestSubSession() }
            return true
        case .character("G") where modifiers.contains(.control):
            Task { @MainActor in await self.openLatestSubSession() }
            return true
        case .arrowRight where modifiers.contains(.control):
            Task { @MainActor in await self.openLatestSubSession() }
            return true
        default:
            return false
        }
    }

    private func handleTimelineScroll(_ input: TerminalInput) -> Bool {
        guard case let .key(key, modifiers) = input else {
            return false
        }

        let page = max(1, lastTimelineViewportHeight - 2)
        switch key {
        case .function(5):
            scrollTimeline(by: page)
        case .function(6):
            scrollTimeline(by: -page)
        case .arrowUp where modifiers.isEmpty || modifiers.contains(.option) || modifiers.contains(.control):
            scrollTimeline(by: 3)
        case .arrowDown where modifiers.isEmpty || modifiers.contains(.option) || modifiers.contains(.control):
            scrollTimeline(by: -3)
        case .home where modifiers.contains(.option) || modifiers.contains(.control):
            scrollTimelineToTop()
        case .end where modifiers.contains(.option) || modifiers.contains(.control):
            scrollTimelineToBottom()
        default:
            return false
        }
        return true
    }

    private func scrollTimeline(by delta: Int) {
        timelineScrollOffset = max(0, timelineScrollOffset + delta)
        requestRender()
    }

    private func scrollTimelineToTop() {
        timelineScrollOffset = Int.max
        requestRender()
    }

    private func scrollTimelineToBottom() {
        timelineScrollOffset = 0
        requestRender()
    }

    private var commandPaletteVisible: Bool {
        let value = editor.getText()
        guard value.hasPrefix("/") else { return false }
        guard !value.contains(" ") else { return false }
        return !value.contains("\n")
    }

    private var allSlashCommands: [SloppyTUISlashCommand] {
        (Self.baseSlashCommands + skillSlashCommands).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func commandPaletteSuggestions() -> [SloppyTUISlashCommand] {
        let prefix = String(editor.getText().dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches: [SloppyTUISlashCommand]
        if prefix.isEmpty {
            matches = allSlashCommands
        } else {
            matches = allSlashCommands.filter { command in
                command.name.lowercased().hasPrefix(prefix)
            }
        }
        if commandPaletteSelection >= matches.count {
            commandPaletteSelection = max(0, matches.count - 1)
        }
        return matches
    }

    private func commandPaletteLines(width: Int) -> [String]? {
        guard commandPaletteVisible else { return nil }
        let suggestions = commandPaletteSuggestions()
        guard !suggestions.isEmpty else { return nil }
        return SloppyTUITheme.commandPaletteLines(
            width: width,
            commands: suggestions,
            selectedIndex: commandPaletteSelection,
            maxVisible: 9
        )
    }

    private func projectTaskSearchPicker() -> SloppyTUIPicker? {
        guard SloppyTUIAutocompleteFeatureFlags.projectTaskAutocompleteEnabled else {
            return nil
        }
        guard let token = currentProjectTaskToken() else {
            return nil
        }
        guard suppressedProjectTaskSearch?.matches(token) != true else {
            return nil
        }

        let query = token.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeTasks = project.tasks.filter { task in
            !task.isArchived && ProjectTaskStatus(rawValue: task.status)?.isTerminal != true
        }
        if activeTasks.isEmpty {
            if projectTaskAutocompleteLoading {
                return SloppyTUIPicker(
                    kind: .projectTask,
                    title: "Loading project tasks",
                    items: [
                        SloppyTUIPickerItem(
                            value: "",
                            label: "Collecting tasks...",
                            description: "Task suggestions will appear in a moment.",
                            isCurrent: false
                        ),
                    ],
                    selectedIndex: 0
                )
            }
            reloadProjectForTaskAutocompleteIfNeeded()
            return nil
        }

        let items: [SloppyTUIPickerItem]
        if let cached = projectTaskSearchCache,
           cached.generation == projectTaskGeneration,
           cached.token == token.rawToken {
            items = cached.items
        } else {
            let matches = matchingProjectTasks(activeTasks, query: query, limit: 30)
            guard !matches.isEmpty else {
                return nil
            }
            items = matches.map(projectTaskPickerItem)
            projectTaskSearchCache = (projectTaskGeneration, token.rawToken, items)
        }

        if projectTaskSearchSelection >= items.count {
            projectTaskSearchSelection = max(0, items.count - 1)
        }
        return SloppyTUIPicker(
            kind: .projectTask,
            title: "Reference project task",
            items: items,
            selectedIndex: projectTaskSearchSelection
        )
    }

    private func matchingProjectTasks(_ tasks: [ProjectTask], query: String, limit: Int) -> [ProjectTask] {
        let tokens = query
            .split { character in
                character.isWhitespace || character == "-" || character == "_" || character == "/"
            }
            .map(String.init)
        let ordered = tasks.sorted { lhs, rhs in
            let lhsRank = projectTaskStatusRank(lhs.status)
            let rhsRank = projectTaskStatusRank(rhs.status)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
        }
        guard !tokens.isEmpty else {
            return Array(ordered.prefix(limit))
        }
        return Array(ordered.filter { task in
            let haystack = [
                task.id,
                task.title,
                task.status,
                task.priority,
                task.kind?.rawValue ?? "",
            ].joined(separator: " ")
            return tokens.allSatisfy { token in
                haystack.localizedCaseInsensitiveContains(token)
            }
        }.prefix(limit))
    }

    private func projectTaskStatusRank(_ status: String) -> Int {
        switch ProjectTaskStatus(rawValue: status) {
        case .ready:
            return 0
        case .backlog:
            return 1
        case .inProgress:
            return 2
        case .waitingInput:
            return 3
        case .needsReview:
            return 4
        case .pendingApproval:
            return 5
        case .blocked:
            return 6
        case .done:
            return 7
        case .cancelled:
            return 8
        case nil:
            return 9
        }
    }

    private func projectTaskPickerItem(_ task: ProjectTask) -> SloppyTUIPickerItem {
        SloppyTUIPickerItem(
            value: task.id,
            label: "#\(task.id)",
            description: "[\(task.status)] \(task.title)",
            isCurrent: false,
            group: task.priority
        )
    }

    private func applyProjectTaskSearchItem(_ item: SloppyTUIPickerItem) {
        guard let token = currentProjectTaskToken() else {
            return
        }

        var lines = editor.getText().components(separatedBy: "\n")
        guard lines.indices.contains(token.line) else {
            return
        }

        var line = lines[token.line]
        let start = line.index(line.startIndex, offsetBy: token.startColumn)
        let end = line.index(line.startIndex, offsetBy: token.endColumn)
        let insertedToken = "#\(item.value)"
        let suppression = SloppyTUITaskReferenceSearchSuppression(
            rawToken: insertedToken,
            line: token.line,
            startColumn: token.startColumn
        )
        line.replaceSubrange(start..<end, with: insertedToken + " ")
        lines[token.line] = line
        projectTaskSearchSelection = 0
        editor.setText(lines.joined(separator: "\n"))
        suppressedProjectTaskSearch = suppression
        requestRender()
    }

    private func currentProjectTaskToken() -> SloppyTUITaskReferenceTokens.Token? {
        let text = editor.getText()
        let cursor = editor.getCursor()
        let lines = text.components(separatedBy: "\n")
        return SloppyTUITaskReferenceTokens.tokenBeforeCursor(
            lines: lines,
            cursorLine: cursor.line,
            cursorColumn: cursor.col
        )
    }

    private func projectFileSearchPicker() -> SloppyTUIPicker? {
        guard SloppyTUIAutocompleteFeatureFlags.projectPathAutocompleteEnabled else {
            return nil
        }
        guard let token = currentProjectFileToken() else {
            return nil
        }
        guard suppressedProjectFileSearch?.matches(token) != true else {
            return nil
        }

        let query = token.path
        guard shouldSearchProjectFiles(query: query) else {
            return nil
        }
        guard let index = projectFileIndex else {
            guard projectFileIndexLoading else {
                return nil
            }
            return SloppyTUIPicker(
                kind: .projectFile,
                title: "Indexing project files",
                items: [
                    SloppyTUIPickerItem(
                        value: "",
                        label: "Collecting files...",
                        description: "Path suggestions will appear in a moment.",
                        isCurrent: false
                    ),
                ],
                selectedIndex: 0
            )
        }
        guard !isExactIndexedFilePath(query, in: index) else {
            return nil
        }
        guard !(query.hasSuffix("/") && isExactIndexedDirectoryPath(query, in: index)) else {
            return nil
        }

        let items: [SloppyTUIPickerItem]
        if let cached = projectFileSearchCache,
           cached.generation == projectFileIndexGeneration,
           cached.token == token.rawToken {
            items = cached.items
        } else {
            let entries = index.completionSearch(query, limit: 30)
            guard !entries.isEmpty else {
                return nil
            }
            items = entries.map(projectFilePickerItem)
            projectFileSearchCache = (projectFileIndexGeneration, token.rawToken, items)
        }

        if projectFileSearchSelection >= items.count {
            projectFileSearchSelection = max(0, items.count - 1)
        }
        return SloppyTUIPicker(
            kind: .projectFile,
            title: "Attach project path",
            items: items,
            selectedIndex: projectFileSearchSelection
        )
    }

    private func shouldSearchProjectFiles(query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }
        if trimmed.hasSuffix("/") {
            return true
        }
        return trimmed.count >= 2
    }

    private func isExactIndexedFilePath(_ query: String, in index: ProjectFileIndex) -> Bool {
        let normalized = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalized.isEmpty else {
            return false
        }
        return index.entries.contains { entry in
            entry.type == .file && entry.path == normalized
        }
    }

    private func isExactIndexedDirectoryPath(_ query: String, in index: ProjectFileIndex) -> Bool {
        let normalized = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalized.isEmpty else {
            return false
        }
        return index.entries.contains { entry in
            entry.type == .directory && entry.path == normalized
        }
    }

    private func projectFilePickerItem(entry: ProjectFileIndexEntry) -> SloppyTUIPickerItem {
        let value = entry.type == .directory ? entry.path + "/" : entry.path
        let displayPath = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let name = (displayPath as NSString).lastPathComponent + (entry.type == .directory ? "/" : "")
        let parent = (displayPath as NSString).deletingLastPathComponent
        return SloppyTUIPickerItem(
            value: value,
            label: name,
            description: parent == "." ? "" : parent,
            isCurrent: false
        )
    }

    private func applyProjectFileSearchItem(_ item: SloppyTUIPickerItem) {
        guard let token = currentProjectFileToken() else {
            return
        }

        var lines = editor.getText().components(separatedBy: "\n")
        guard lines.indices.contains(token.line) else {
            return
        }

        var line = lines[token.line]
        let start = line.index(line.startIndex, offsetBy: token.startColumn)
        let end = line.index(line.startIndex, offsetBy: token.endColumn)
        let insertedToken = "@\(SloppyTUIProjectPathTokens.escapedTokenValue(item.value))"
        let suppression = SloppyTUIProjectPathSearchSuppression(
            rawToken: insertedToken,
            line: token.line,
            startColumn: token.startColumn
        )
        line.replaceSubrange(start..<end, with: insertedToken + " ")
        lines[token.line] = line
        editor.handle(input: .key(.escape))
        projectFileSearchSelection = 0
        editor.setText(lines.joined(separator: "\n"))
        suppressedProjectFileSearch = suppression
        requestRender()
    }

    private func currentProjectFileToken() -> SloppyTUIProjectPathTokens.Token? {
        let text = editor.getText()
        let cursor = editor.getCursor()
        let lines = text.components(separatedBy: "\n")
        return SloppyTUIProjectPathTokens.tokenBeforeCursor(
            lines: lines,
            cursorLine: cursor.line,
            cursorColumn: cursor.col
        )
    }

    private func applyCommandPaletteSelection(_ command: SloppyTUISlashCommand) {
        commandPaletteSelection = 0
        let raw = "/\(command.name)"
        if command.requiresArgument {
            editor.setText(raw + " ")
            requestRender()
            return
        }

        editor.setText("")
        persistDraft("")
        requestRender()
        Task { @MainActor in
            await self.handleCommand(raw)
        }
    }

    private func providerLabel(from model: String) -> String {
        if let separator = model.firstIndex(of: ":") {
            return String(model[..<separator])
        }
        return "native"
    }

    private func submit(_ raw: String) async {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty || !pendingUploads.isEmpty else {
            return
        }
        if !value.isEmpty {
            editor.addToHistory(value)
        }
        editor.setText("")
        persistDraft("")

        if shouldHandleSlashCommand(value) {
            await handleCommand(value)
            return
        }

        welcomeDismissed = true
        dismissFirstStartBootstrapCard()
        if isPosting {
            queueMessage(value, context: pendingContext, uploads: pendingUploads, clearsPendingInputs: true)
            return
        }
        await sendMessage(value)
    }

    private func sendMessage(_ value: String, spawnSubSession: Bool = false) async {
        await sendMessage(
            value,
            context: pendingContext,
            uploads: pendingUploads,
            spawnSubSession: spawnSubSession,
            clearsPendingInputsOnSuccess: true
        )
    }

    private func sendMessage(
        _ value: String,
        context: String?,
        uploads: [AgentAttachmentUpload],
        spawnSubSession: Bool = false,
        clearsPendingInputsOnSuccess: Bool
    ) async {
        guard !isPosting else {
            queueMessage(value, context: context, uploads: uploads, spawnSubSession: spawnSubSession)
            return
        }

        dismissLocalCardsForUserMessage()
        isPosting = true
        taskStartedAt = Date()
        lastTaskElapsed = nil
        setLiveAssistantDraftImmediately("")
        liveRunStatusLine = "Thinking - Planning response strategy."
        startThinkingAnimation()
        renderTimeline()
        refreshStaticChrome()
        let content = await messageContentWithInlineAttachments(value, context: context, uploads: uploads)
        var createdSessionForThisMessage = false
        do {
            createdSessionForThisMessage = try await ensurePersistedSessionForMessage()
            let undoBaseline = await makeUndoBaseline()
            if !runtime.config.onboarding.completed {
                var config = await runtime.service.getConfig()
                config.onboarding.completed = true
                _ = try await runtime.service.updateConfig(config)
            }
            let config = await runtime.service.getConfig()
            _ = try await runtime.service.postAgentSessionMessage(
                agentID: agent.id,
                sessionID: session.id,
                request: AgentSessionPostMessageRequest(
                    userId: config.onboarding.completed ? "tui" : "onboarding",
                    content: content,
                    attachments: uploads,
                    spawnSubSession: spawnSubSession,
                    reasoningEffort: reasoningEffort,
                    mode: chatMode
                )
            )
            if clearsPendingInputsOnSuccess {
                pendingContext = nil
                pendingUploads.removeAll()
            }
            recordUndoPointIfNeeded(undoBaseline)
            await reloadSession()
            await refreshTokenUsage(includeCost: true)
            petMood = .happy
        } catch {
            await deleteSessionIfStillEmptyAfterFailedFirstMessage(createdSessionForThisMessage)
            clearLiveAssistantDraft()
            petMood = .sad
            appendLocalCard("Message failed: \(String(describing: error))")
        }
        if let taskStartedAt {
            lastTaskElapsed = Date().timeIntervalSince(taskStartedAt)
        }
        taskStartedAt = nil
        isPosting = false
        stopThinkingAnimation()
        clearLiveAssistantDraft()
        liveRunStatusLine = nil
        refreshStaticChrome()
        renderTimeline()
        await sendNextQueuedMessageIfIdle()
    }

    private func ensurePersistedSessionForMessage() async throws -> Bool {
        guard !hasPersistedSession else {
            return false
        }
        let draftDirectoryKey = currentSessionDirectoryKey()
        let draftDirectories = persistedDirectoriesForCurrentSession()
        let checkpointSessionID = pendingDraftCheckpointSessionID
        session = try await runtime.service.createAgentSession(
            agentID: agent.id,
            request: AgentSessionCreateRequest(
                checkpointSessionId: checkpointSessionID,
                projectId: project.id
            )
        )
        pendingDraftCheckpointSessionID = nil
        hasPersistedSession = true
        if !draftDirectories.isEmpty {
            await applyDraftDirectories(draftDirectories, previousKey: draftDirectoryKey)
        }
        persistSelection()
        streamSession()
        refreshStaticChrome()
        return true
    }

    private func deleteSessionIfStillEmptyAfterFailedFirstMessage(_ shouldDelete: Bool) async {
        guard shouldDelete, hasPersistedSession else {
            return
        }
        guard let detail = try? await runtime.service.getAgentSession(agentID: agent.id, sessionID: session.id),
              detail.summary.messageCount == 0 else {
            return
        }
        try? await runtime.service.deleteAgentSession(agentID: agent.id, sessionID: session.id)
        session = SloppyTUIApp.makeDraftSession(agent: agent, projectID: project.id)
        hasPersistedSession = false
        persistSelection()
        streamSession()
    }

    private func queueMessage(
        _ value: String,
        context: String? = nil,
        uploads: [AgentAttachmentUpload] = [],
        spawnSubSession: Bool = false,
        clearsPendingInputs: Bool = false
    ) {
        _ = queuedMessages.enqueue(
            text: value,
            context: context,
            uploads: uploads,
            spawnSubSession: spawnSubSession
        )
        if clearsPendingInputs {
            pendingContext = nil
            pendingUploads.removeAll()
        }
        showSystemNotice("Queued message. Press ctrl+b to cancel next queued message.")
        renderTimeline()
    }

    private func sendNextQueuedMessageIfIdle() async {
        guard !isPosting, !isDrainingQueuedMessages else { return }
        guard let message = queuedMessages.dequeue() else {
            renderTimeline()
            return
        }

        isDrainingQueuedMessages = true
        renderTimeline()
        await sendMessage(
            message.text,
            context: message.context,
            uploads: message.uploads,
            spawnSubSession: message.spawnSubSession,
            clearsPendingInputsOnSuccess: false
        )
        isDrainingQueuedMessages = false
        await sendNextQueuedMessageIfIdle()
    }

    private func handleCommand(_ raw: String) async {
        let parts = raw.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let command = parts.first.map { String($0.dropFirst()).lowercased() } ?? ""
        let args = Array(parts.dropFirst())

        switch command {
        case "help":
            showHelp()
        case "status":
            await showStatus()
        case "pet":
            showPetStatus(toggle: true)
        case "agents", "agent":
            await showAgentPicker()
        case "subagents", "children":
            showSubSessionPicker()
        case "parent", "back":
            await openParentSession()
        case "sessions", "session":
            await showSessionPicker()
        case "new":
            await createNewSession()
        case "clear":
            clearLocalCards()
            renderTimeline()
        case "stop":
            await stopCurrentRun()
        case "restore", "up":
            await restoreCurrentSession(extraInstruction: args.joined(separator: " "))
        case "undo":
            await undoLastTurn()
        case "redo":
            await redoLastTurn()
        case "btw":
            let message = args.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else {
                appendLocalCard("Usage: `/btw <message>`")
                return
            }
            await sendMessage(raw)
        case "compact":
            await compactCurrentSession()
        case "add_dir", "add-dir":
            await addDirectoryToCurrentSession(raw)
        case "fork":
            await forkCurrentSession(task: args.joined(separator: " "))
        case "bar":
            changeBarColor(args.first)
        case "copy":
            copyLastAssistantResponse()
        case "diff":
            await showDiff()
        case "effort":
            setReasoningEffort(args.first)
        case "skills":
            await showSkills()
        case "editor":
            await openCodeEditor(args)
        case "model":
            await switchModel(args.first)
        case "context":
            await attachContext(args.first)
        case "tasks":
            await showTasks()
        case "mcps", "mcp":
            await showMCPServers()
        case "provider", "providers":
            if args.isEmpty {
                await showProviderPicker()
            } else {
                await configureProvider(args)
            }
        case "openai-device":
            await startOpenAIDeviceFlow()
        case "anthropic-oauth":
            await startAnthropicOAuth()
        case "anthropic-callback":
            await completeAnthropicOAuth(args.joined(separator: " "))
        case "quit", "exit":
            await stopTUI(reason: "TUI /\(command)")
        default:
            if skillSlashCommandNames.contains(command) {
                await sendMessage(raw)
                return
            }
            showSystemNotice("Unknown command `\(raw)`. Try `/help`.")
        }
    }

    private func shouldHandleSlashCommand(_ value: String) -> Bool {
        SloppyTUISlashCommandRouter.shouldHandle(
            value,
            commandNames: Self.handledSlashCommandNames,
            skillCommandNames: skillSlashCommandNames
        )
    }

    private func showHelp() {
        let commandLines = allSlashCommands.map { command -> String in
            let usage = command.argument.map { " <\($0)>" } ?? ""
            return "- `/\(command.name)\(usage)` — \(command.description ?? command.name)"
        }.joined(separator: "\n")
        appendLocalCard("""
        ## TUI commands
        \(commandLines)

        Paste file paths normally to send them as text. Press Ctrl+V to attach files or images from the macOS clipboard.
        Use `@path` in a message to inline a project file as explicit context. Tab completes slash commands.
        Use `#` to autocomplete active project tasks by id or title.
        Press Ctrl+O to toggle the full tool-call transcript. Ctrl+G enters the newest subagent session.
        Press Ctrl+P or run `/parent` to return from a subagent to its parent session.
        Use `/subagents` to pick a specific child session.

        ## History scroll
        - PageUp / PageDown scroll by pages.
        - Up/Down scroll by a few lines.
        - Option+Up/Down or Ctrl+Up/Down also scroll by a few lines.
        - Option+Home / Ctrl+Home jumps to the start of history.
        - Option+End / Ctrl+End jumps back to the bottom.

        ## Tips
        - Esc interrupts the current run after picker overlays are closed.
        - `/pet` toggles the terminal Sloppie and shows its face/status.
        - `/undo` and `/redo` are scoped to the current session during this TUI run.
        - `/btw <message>` asks a quick side question without interrupting the main flow.
        - `/diff` previews local changes; `/context diff` attaches them to the next message.
        """)
    }

    private func showMCPServers() async {
        let statuses = await runtime.service.listMCPServerStatuses()
        guard !statuses.isEmpty else {
            appendLocalCard("No MCP servers configured.", autoDismissAfter: 6)
            return
        }

        let connectedCount = statuses.filter { $0.connected }.count
        let enabledCount = statuses.filter { $0.enabled }.count
        let lines = statuses.map(mcpStatusLine).joined(separator: "\n")
        appendLocalCard("""
        ## MCP servers
        \(connectedCount)/\(enabledCount) enabled servers connected.

        \(lines)
        """, autoDismissAfter: 20)
    }

    private func mcpStatusLine(_ status: MCPServerStatus) -> String {
        let state: String
        if !status.enabled {
            state = "disabled"
        } else if status.connected {
            state = "connected"
        } else {
            state = "disconnected"
        }

        var exposed: [String] = []
        if status.exposeTools {
            exposed.append("tools")
        }
        if status.exposeResources {
            exposed.append("resources")
        }
        if status.exposePrompts {
            exposed.append("prompts")
        }
        let exposedText = exposed.isEmpty ? "none" : exposed.joined(separator: ", ")
        let prefixText = status.toolPrefix?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? " prefix: `\(status.toolPrefix!)`"
            : ""
        let messageText = status.message?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? " - \(status.message!)"
            : ""

        return "- `\(status.id)` \(state) transport: `\(status.transport)` exposed: \(exposedText)\(prefixText)\(messageText)"
    }

    private func createNewSession() async {
        resetToDraftSession()
    }

    private func resetToDraftSession() {
        if let checkpointSessionID = SloppyTUIDraftSessionReset.pendingCheckpointSessionID(
            currentSessionID: session.id,
            hasPersistedSession: hasPersistedSession
        ) {
            pendingDraftCheckpointSessionID = checkpointSessionID
        }

        welcomeDismissed = false
        session = SloppyTUIApp.makeDraftSession(agent: agent, projectID: project.id)
        hasPersistedSession = false
        sessionCards = []
        subSessionCards = []
        lastRenderedSessionEventIDs = []
        pendingContext = nil
        pendingUploads.removeAll()
        pendingPlanInputRequest = nil
        tokenUsageSummary = nil
        tokenUsageCostUSD = nil
        taskStartedAt = nil
        lastTaskElapsed = nil
        liveRunStatusLine = nil
        activePicker = nil
        queuedMessages = SloppyTUIMessageQueue()
        isDrainingQueuedMessages = false
        sessionUndoManagers = SloppyTUISessionUndoManagers()
        clearLocalCards()
        transientNoticeTask?.cancel()
        transientNoticeTask = nil
        transientNoticeLine = nil
        streamTask?.cancel()
        streamTask = nil
        clearLiveAssistantDraft()
        invalidateSessionTimelineCache()
        persistSelection()
        renderTimeline()
    }

    private func stopCurrentRun() async {
        await interruptCurrentRun(
            reason: "TUI /stop",
            successMessage: "Stop requested.",
            failurePrefix: "Stop failed",
            useNotice: false
        )
    }

    private func restoreCurrentSession(extraInstruction: String) async {
        guard !isPosting else {
            appendLocalCard("A message is already in flight. Use `/stop` if you need to interrupt it before restoring.")
            return
        }

        let trimmedExtra = extraInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let extra = trimmedExtra.isEmpty ? "" : "\n\nAdditional recovery instruction:\n\(trimmedExtra)"
        await sendMessage("""
        Restore this session after the previous run failed, lost network access, or was interrupted. Continue the last unfinished user task from the current session transcript.

        Do not start a new task and do not repeat completed work. Inspect the latest session context and tool results if needed, then continue from the last reliable point. If the failure was transient, retry the failed operation and proceed normally.\(extra)
        """)
    }

    private func makeUndoBaseline() async -> SloppyTUISessionUndoManagers.Baseline? {
        do {
            let rootURL = try await runtime.service.resolveProjectWorkspaceRoot(projectID: project.id)
            return sessionUndoManagers.makeBaseline(sessionID: session.id, rootURL: rootURL)
        } catch {
            return nil
        }
    }

    private func recordUndoPointIfNeeded(_ baseline: SloppyTUISessionUndoManagers.Baseline?) {
        guard let baseline else {
            return
        }

        switch sessionUndoManagers.recordChanges(baseline) {
        case .recorded:
            break
        case .noChanges:
            break
        case .skipped(let reason):
            appendLocalCard(reason, autoDismissAfter: 10)
        }
    }

    private func undoLastTurn() async {
        await applyUndoRedo(direction: .undo)
    }

    private func redoLastTurn() async {
        await applyUndoRedo(direction: .redo)
    }

    private func applyUndoRedo(direction: SloppyTUIUndoManager.ApplyDirection) async {
        guard !isPosting else {
            appendLocalCard("A message is in flight. Use `/stop` before changing files with `/undo` or `/redo`.")
            return
        }
        guard hasPersistedSession else {
            appendLocalCard("No session yet. Send a message first or open an existing session with `/sessions`.")
            return
        }

        do {
            let rootURL = try await runtime.service.resolveProjectWorkspaceRoot(projectID: project.id)
            let result: SloppyTUIUndoManager.ApplyResult
            switch direction {
            case .undo:
                result = try sessionUndoManagers.undo(sessionID: session.id, rootURL: rootURL)
            case .redo:
                result = try sessionUndoManagers.redo(sessionID: session.id, rootURL: rootURL)
            }
            appendLocalCard(undoRedoSummary(result), autoDismissAfter: 10)
            scheduleProjectFileReindex()
        } catch let error as SloppyTUIUndoManager.Error {
            appendLocalCard(error.localizedDescription, autoDismissAfter: 8)
        } catch {
            appendLocalCard("Could not update files: \(String(describing: error))")
        }
    }

    private func undoRedoSummary(_ result: SloppyTUIUndoManager.ApplyResult) -> String {
        let title: String
        switch result.direction {
        case .undo:
            title = "Undid file changes from the last turn."
        case .redo:
            title = "Redid file changes from the last undone turn."
        }

        let paths = result.paths.prefix(12).map { "- `\($0)`" }.joined(separator: "\n")
        let remaining = result.paths.count > 12 ? "\n- ...and \(result.paths.count - 12) more" : ""
        return """
        \(title)

        \(paths)\(remaining)
        """
    }

    private func interruptCurrentRun(
        reason: String,
        successMessage: String,
        failurePrefix: String,
        useNotice: Bool
    ) async {
        guard hasPersistedSession else {
            if useNotice {
                showSystemNotice("No active session to interrupt.")
            } else {
                appendLocalCard("No active session to interrupt.")
            }
            return
        }
        guard !isInterruptingRun else {
            return
        }
        isInterruptingRun = true
        requestRender()
        defer {
            isInterruptingRun = false
            requestRender()
        }
        do {
            _ = try await runtime.service.controlAgentSession(
                agentID: agent.id,
                sessionID: session.id,
                request: AgentSessionControlRequest(action: .interruptTree, requestedBy: "tui", reason: reason)
            )
            if useNotice {
                showSystemNotice(successMessage)
            } else {
                appendLocalCard(successMessage)
            }
        } catch {
            let message = "\(failurePrefix): \(String(describing: error))"
            if useNotice {
                showSystemNotice(message)
            } else {
                appendLocalCard(message)
            }
        }
    }

    private func compactCurrentSession() async {
        guard hasPersistedSession else {
            appendLocalCard("No session yet. Send a message first or open an existing session with `/sessions`.")
            return
        }
        do {
            _ = try await runtime.service.requestAgentMemoryCheckpoint(
                agentID: agent.id,
                sessionID: session.id,
                reason: "tui_compact_command"
            )
            appendLocalCard("Context compacted for `\(session.title)`. Memory checkpoint requested.", autoDismissAfter: 8)
        } catch {
            appendLocalCard("Compact failed: \(String(describing: error))")
        }
    }

    private func addDirectoryToCurrentSession(_ raw: String) async {
        guard let path = ChannelAddDirCommandParsing.pathTailIfCommand(raw),
              !path.isEmpty
        else {
            appendLocalCard("Usage: `/add_dir <path>`")
            return
        }

        guard hasPersistedSession else {
            do {
                let resolvedPath = try await resolveDraftSessionDirectoryPath(path)
                let directories = appendingUniqueDirectory(resolvedPath, to: persistedDirectoriesForCurrentSession())
                persistSessionDirectories(directories)
                loadProjectFileIndex()
                appendLocalCard("Added working directory for the next session:\n`\(resolvedPath)`", autoDismissAfter: 8)
            } catch {
                appendLocalCard("Directory not found: `\(path)`")
            }
            return
        }

        do {
            let response = try await runtime.service.addAgentSessionDirectory(
                agentID: agent.id,
                sessionID: session.id,
                request: AgentSessionDirectoryRequest(path: path)
            )
            persistSessionDirectories(response.directories)
            loadProjectFileIndex()
            appendLocalCard("Added working directory:\n`\(response.path)`", autoDismissAfter: 8)
        } catch {
            appendLocalCard("Add directory failed: \(String(describing: error))")
        }
    }

    private func forkCurrentSession(task: String) async {
        guard hasPersistedSession else {
            appendLocalCard("No session yet. Send a message first or open an existing session with `/sessions`.")
            return
        }
        do {
            let titleTail = task.trimmingCharacters(in: .whitespacesAndNewlines)
            let child = try await runtime.service.createAgentSession(
                agentID: agent.id,
                request: AgentSessionCreateRequest(
                    title: titleTail.isEmpty ? "Fork of \(SloppyTUITheme.sessionDisplayTitle(session))" : "Fork: \(String(titleTail.prefix(48)))",
                    parentSessionId: session.id,
                    projectId: project.id
                )
            )
            session = child
            persistSelection()
            streamSession()
            await reloadSession()
            appendLocalCard("Forked into `\(child.title)`.", autoDismissAfter: 8)
            if !titleTail.isEmpty {
                await sendMessage(titleTail)
            }
        } catch {
            appendLocalCard("Fork failed: \(String(describing: error))")
        }
    }

    private func changeBarColor(_ rawColor: String?) {
        guard let rawColor, !rawColor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            appendLocalCard("Usage: `/bar <red|blue|green|yellow|purple|orange|pink|cyan|default>`")
            return
        }
        guard SloppyTUITheme.setBarColor(rawColor) else {
            appendLocalCard("Unknown bar color `\(rawColor)`. Use red, blue, green, yellow, purple, orange, pink, cyan, or default.")
            return
        }
        editor.apply(theme: SloppyTUITheme.palette)
        tui?.apply(theme: SloppyTUITheme.palette)
        refreshStaticChrome(statusLine: "bar color set to \(rawColor)")
        requestRender()
    }

    private func copyLastAssistantResponse() {
        guard let text = sessionCards.reversed().compactMap({ block -> String? in
            if case .message(let role, let text) = block, role == .assistant {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        }).first, !text.isEmpty else {
            appendLocalCard("No agent response to copy.", autoDismissAfter: 6)
            return
        }

        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        appendLocalCard("Copied last agent response to clipboard.", autoDismissAfter: 6)
        #else
        appendLocalCard("Clipboard copy is not available on this platform.", autoDismissAfter: 6)
        #endif
    }

    private func showDiff() async {
        do {
            let git = try await runtime.service.projectWorkingTreeGit(projectID: project.id)
            guard git.isGitRepository else {
                appendLocalCard(git.message ?? "This project folder is not a git repository.")
                return
            }
            guard !git.diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                appendLocalCard("No uncommitted changes.")
                return
            }
            let branch = git.branch ?? "unknown"
            let truncated = git.diffTruncated ? "\n\nDiff was truncated by the backend." : ""
            appendLocalCard("""
            ## Diff
            Branch: `\(branch)`  +\(git.linesAdded) -\(git.linesDeleted)

            \(fencedBlock("diff", git.diff, maxCharacters: 12_000))\(truncated)
            """)
        } catch {
            appendLocalCard("Could not read git diff: \(String(describing: error))")
        }
    }

    private func setReasoningEffort(_ raw: String?) {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !value.isEmpty else {
            let current = reasoningEffort?.rawValue ?? "default"
            appendLocalCard("Current reasoning effort: `\(current)`. Use `/effort low`, `/effort medium`, `/effort high`, or `/effort default`.")
            return
        }
        if value == "default" || value == "none" || value == "off" {
            reasoningEffort = nil
            appendLocalCard("Reasoning effort reset to model default.", autoDismissAfter: 6)
            return
        }
        guard let effort = ReasoningEffort(rawValue: value) else {
            appendLocalCard("Unknown effort `\(value)`. Use low, medium, high, or default.")
            return
        }
        reasoningEffort = effort
        appendLocalCard("Reasoning effort set to `\(effort.rawValue)`.", autoDismissAfter: 6)
    }

    private func showSkills() async {
        do {
            let response = try await runtime.service.listAgentSkills(agentID: agent.id)
            guard !response.skills.isEmpty else {
                appendLocalCard("No enabled skills for `\(agent.displayName)`.", autoDismissAfter: 8)
                return
            }
            let lines = response.skills.map { skill -> String in
                let slash = skillSlashCommands.first { $0.description?.hasPrefix(skill.name) == true }?.name
                let suffix = slash.map { " `/\($0)`" } ?? ""
                return "- \(skill.name)\(suffix) — `\(skill.id)`"
            }.joined(separator: "\n")
            appendLocalCard("""
            ## Skills
            \(lines)
            """)
        } catch {
            appendLocalCard("Could not load skills: \(String(describing: error))")
        }
    }

    private func openCodeEditor(_ args: [String]) async {
        do {
            let result = try await SloppyTUICodeEditorLauncher.open(path: runtime.cwd, preferredEditor: args)
            appendLocalCard("Opened `\(result.path)` in `\(result.label)`.", autoDismissAfter: 6)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            appendLocalCard("Could not open code editor: \(message)", autoDismissAfter: 10)
        }
    }

    private func showStatus() async {
        let config = try? await runtime.service.getAgentConfig(agentID: agent.id)
        let model = config?.selectedModel ?? selectedModel
        selectedModel = model
        let sessionLines = hasPersistedSession
            ? """
            - session: `\(session.title)`
            - session id: `\(session.id)`
            - resume: `sloppy -s \(session.id)`
            """
            : """
            - session: `not created yet`
            - resume: unavailable until the first message
            """
        appendLocalCard("""
        ## Status
        - project: `\(project.name)`
        - agent: `\(agent.displayName)`
        \(sessionLines)
        - model: `\(model)`
        - provider: `\(providerLabel(from: model))`
        - pet: \(petStatusSummary())
        """, autoDismissAfter: 20)
    }

    private func showPetStatus(toggle: Bool) {
        if toggle {
            state.petEnabled.toggle()
            stateStore.save(state)
        }
        appendLocalCard("""
        ## Sloppie pet
        - status: `\(state.petEnabled ? "on" : "off")`
        - face: `\(terminalPetFace())`
        - species: `\(agent.pet?.visual?.displayName ?? "legacy sloppie")`
        - stage: `\(agent.pet?.visual?.currentStage ?? 1)/\(agent.pet?.visual?.stageCount ?? 3)`
        - xp: `\(agent.pet?.evolution?.totalXp ?? 0)`
        """, autoDismissAfter: 12)
        refreshStaticChrome()
    }

    private func petStatusSummary() -> String {
        guard state.petEnabled else {
            return "`off`"
        }
        let visual = agent.pet?.visual
        let stage = visual.map { "\($0.currentStage)/\($0.stageCount)" } ?? "1/3"
        return "`\(terminalPetFace())` \(visual?.displayName ?? "Sloppie") stage \(stage)"
    }

    private func showAgentPicker() async {
        let agents = (try? await runtime.service.listAgents(includeSystem: false)) ?? []
        guard !agents.isEmpty else {
            appendLocalCard("No agents available.")
            return
        }
        let ordered = orderedAgentsForPicker(agents)
        activePicker = SloppyTUIPicker(
            kind: .agent,
            title: "Select agent",
            items: ordered.map { item in
                SloppyTUIPickerItem(
                    value: item.id,
                    label: item.displayName,
                    description: item.role.isEmpty ? item.id : item.role,
                    isCurrent: item.id == agent.id
                )
            },
            selectedIndex: 0
        )
        refreshStaticChrome(statusLine: "select agent with arrows, Enter to apply, Esc to cancel")
    }

    private func showSessionPicker() async {
        let sessions = ((try? await runtime.service.listAgentSessions(agentID: agent.id, projectID: project.id)) ?? [])
            .sorted { lhs, rhs in
                if lhs.id == session.id { return true }
                if rhs.id == session.id { return false }
                return lhs.updatedAt > rhs.updatedAt
            }

        guard !sessions.isEmpty else {
            appendLocalCard("No sessions for `\(agent.displayName)` in this directory.")
            return
        }

        activePicker = SloppyTUIPicker(
            kind: .session,
            title: "Select session",
            items: sessions.map { item in
                SloppyTUIPickerItem(
                    value: item.id,
                    label: SloppyTUITheme.sessionDisplayTitle(item),
                    description: SloppyTUITheme.sessionPickerDescription(item),
                    isCurrent: item.id == session.id
                )
            },
            selectedIndex: 0
        )
        refreshStaticChrome(statusLine: "select session with arrows, Enter to open, Esc to cancel")
    }

    private func showSubSessionPicker() {
        let children = orderedSubSessions()
        guard !children.isEmpty else {
            appendLocalCard("No subagent sessions have been spawned from this session yet.", autoDismissAfter: 8)
            return
        }

        activePicker = SloppyTUIPicker(
            kind: .subSession,
            title: "Open subagent session",
            items: children.map { item in
                SloppyTUIPickerItem(
                    value: item.childSessionId,
                    label: item.title,
                    description: "\(item.status.plainText) · \(item.childSessionId)",
                    isCurrent: false
                )
            },
            selectedIndex: 0
        )
        refreshStaticChrome(statusLine: "select subagent with arrows, Enter to enter, Esc to cancel")
    }

    private func openLatestSubSession() async {
        guard let child = orderedSubSessions().first else {
            appendLocalCard("No subagent session to enter yet.", autoDismissAfter: 6)
            return
        }
        await switchSession(child.childSessionId)
    }

    private func openParentSession() async {
        guard let parentSessionID = session.parentSessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !parentSessionID.isEmpty else {
            appendLocalCard("This session does not have a parent session.", autoDismissAfter: 6)
            return
        }
        await switchSession(parentSessionID)
    }

    private func orderedSubSessions() -> [SloppyTUISubSessionCard] {
        var seen: Set<String> = []
        return subSessionCards.reversed().compactMap { item in
            guard seen.insert(item.childSessionId).inserted else {
                return nil
            }
            return item
        }
    }

    private func switchModel(_ model: String?) async {
        guard let model, !model.isEmpty else {
            await showModelPicker()
            return
        }
        await applyModel(model)
    }

    private func showModelPicker(exitAfterSelection: Bool = false) async {
        exitAfterModelSelection = exitAfterSelection
        refreshStaticChrome(statusLine: "loading models from providers...")
        do {
            let config = try await runtime.service.getAgentConfig(agentID: agent.id)
            let selected = config.selectedModel ?? selectedModel
            selectedModel = selected
            let models = orderedModelsForPicker(
                await selectableModels(base: config.availableModels, selected: selected),
                selected: selected
            )
            guard !models.isEmpty else {
                appendLocalCard("No available models.")
                return
            }
            let items = models.map { model in
                let group = modelPickerGroup(for: model.id)
                return SloppyTUIPickerItem(
                    value: model.id,
                    label: modelPickerLabel(for: model.id, group: group),
                    description: SloppyTUITheme.modelPickerDescription(model),
                    isCurrent: model.id == selected,
                    group: group
                )
            }
            activePicker = SloppyTUIPicker(
                kind: .model,
                title: "Select model",
                items: items,
                selectedIndex: models.firstIndex(where: { $0.id == selected }) ?? 0,
                allItems: items,
                supportsSearch: true
            )
            refreshStaticChrome(statusLine: "type to search models, arrows to select, Enter to apply, Esc to cancel")
        } catch {
            exitAfterModelSelection = false
            appendLocalCard("Could not load models: \(String(describing: error))")
        }
    }

    private func applyPickerItem(_ item: SloppyTUIPickerItem, kind: SloppyTUIPickerKind) async {
        switch kind {
        case .model:
            await applyModel(item.value)
            if exitAfterModelSelection {
                await stopTUI(reason: "TUI model picker")
            }
        case .agent:
            await switchAgent(item.value)
        case .session:
            await switchSession(item.value)
        case .subSession:
            await switchSession(item.value)
        case .provider:
            if item.value == SloppyTUIProviderDefinition.addNewProviderValue {
                showProviderCatalogPicker()
            } else {
                await applyModel(item.value)
            }
        case .providerCatalog:
            await beginProviderSetup(item.value)
        case .projectFile:
            applyProjectFileSearchItem(item)
        case .projectTask:
            applyProjectTaskSearchItem(item)
        case .planInput:
            await answerPlanInput(with: item)
        }
    }

    private func selectableModels(base: [ProviderModelOption], selected: String) async -> [ProviderModelOption] {
        var seen: Set<String> = []
        var models: [ProviderModelOption] = []

        func add(_ option: ProviderModelOption) {
            let id = option.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else {
                return
            }
            models.append(ProviderModelOption(
                id: id,
                title: option.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? id : option.title,
                contextWindow: option.contextWindow,
                capabilities: option.capabilities
            ))
        }

        for option in base {
            add(option)
        }

        let config = await runtime.service.getConfig()
        for entry in config.models where !entry.disabled {
            let definition = providerDefinition(for: entry)
            let response = await runtime.service.probeProvider(
                request: ProviderProbeRequest(
                    providerId: definition.probeID,
                    apiKey: entry.apiKey,
                    apiUrl: entry.apiUrl
                )
            )
            guard response.ok else {
                continue
            }
            for option in response.models {
                let rawId = option.id.trimmingCharacters(in: .whitespacesAndNewlines)
                let id = runtimeModelID(rawId, provider: definition)
                add(ProviderModelOption(
                    id: id,
                    title: option.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? rawId : option.title,
                    contextWindow: option.contextWindow,
                    capabilities: option.capabilities
                ))
            }
        }

        if !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !seen.contains(selected) {
            add(CoreService.providerModelOption(for: selected))
        }

        return models
    }

    private func applyModel(_ model: String) async {
        do {
            let config = try await runtime.service.getAgentConfig(agentID: agent.id)
            _ = try await runtime.service.updateAgentConfig(
                agentID: agent.id,
                request: AgentConfigUpdateRequest(
                    role: config.role,
                    selectedModel: model,
                    documents: config.documents,
                    heartbeat: config.heartbeat,
                    channelSessions: config.channelSessions,
                    runtime: config.runtime
                )
            )
            selectedModel = model
            selectedModelContextWindowTokens = contextWindowTokens(for: model, in: config.availableModels)
            dismissFirstStartBootstrapCard()
            dismissModelSwitchCards()
            await refreshTokenUsage(includeCost: true)
            appendLocalCard("Model switched to `\(model)`.", autoDismissAfter: 6)
        } catch {
            appendLocalCard("Model switch failed: \(String(describing: error))")
        }
    }

    private func orderedModelsForPicker(_ models: [ProviderModelOption], selected: String) -> [ProviderModelOption] {
        let indexed = models.enumerated().map { index, model in
            (index: index, model: model, group: modelPickerGroup(for: model.id))
        }
        guard let selectedGroup = indexed.first(where: { $0.model.id == selected })?.group else {
            return indexed
                .sorted { lhs, rhs in
                    if lhs.group != rhs.group {
                        return lhs.group.localizedCaseInsensitiveCompare(rhs.group) == .orderedAscending
                    }
                    return lhs.index < rhs.index
                }
                .map { $0.model }
        }
        return indexed
            .sorted { lhs, rhs in
                if lhs.group == selectedGroup, rhs.group != selectedGroup { return true }
                if rhs.group == selectedGroup, lhs.group != selectedGroup { return false }
                if lhs.group != rhs.group {
                    return lhs.group.localizedCaseInsensitiveCompare(rhs.group) == .orderedAscending
                }
                if lhs.model.id == selected { return true }
                if rhs.model.id == selected { return false }
                return lhs.index < rhs.index
            }
            .map { $0.model }
    }

    private func modelPickerGroup(for modelID: String) -> String {
        let parts = modelID.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let provider = parts.count == 2 ? String(parts[0]) : "configured"
        let remainder = parts.count == 2 ? String(parts[1]) : modelID
        var groupParts = [modelPickerProviderTitle(provider)]

        let scopedParts = remainder.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        if scopedParts.count > 1 {
            groupParts.append(scopedParts[0])
            if let namespace = modelPickerNamespace(from: scopedParts.dropFirst().joined(separator: ":")) {
                groupParts.append(namespace)
            }
        } else if let namespace = modelPickerNamespace(from: remainder) {
            groupParts.append(namespace)
        }

        return groupParts.joined(separator: " / ")
    }

    private func modelPickerProviderTitle(_ provider: String) -> String {
        switch provider.lowercased() {
        case "anthropic":
            return "Anthropic"
        case "gemini":
            return "Gemini"
        case "ollama":
            return "Ollama"
        case "openai":
            return "OpenAI"
        case "opencode":
            return "OpenCode"
        case "openrouter":
            return "OpenRouter"
        case "configured":
            return "Configured"
        default:
            return provider
                .split(separator: "-")
                .map { segment in
                    segment.prefix(1).uppercased() + segment.dropFirst()
                }
                .joined(separator: " ")
        }
    }

    private func modelPickerNamespace(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let slash = trimmed.firstIndex(of: "/") {
            let namespace = String(trimmed[..<slash])
            return namespace.isEmpty ? nil : namespace
        }
        let separators: Set<Character> = ["-", "_", "."]
        let prefix = String(trimmed.prefix { !separators.contains($0) })
        guard prefix.count >= 2, prefix.count < trimmed.count else {
            return nil
        }
        return prefix
    }

    private func modelPickerLabel(for modelID: String, group: String) -> String {
        let providerTitle = group.split(separator: "/").first.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? ""
        let providerPrefix = providerTitle.isEmpty ? "" : providerTitle.lowercased() + ":"
        var label = modelID
        if let colon = label.firstIndex(of: ":") {
            label = String(label[label.index(after: colon)...])
        }
        let groupParts = group
            .split(separator: "/")
            .dropFirst()
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for part in groupParts {
            if label.hasPrefix(part + ":") {
                label = String(label.dropFirst(part.count + 1))
            } else if label.hasPrefix(part + "/") {
                label = String(label.dropFirst(part.count + 1))
            }
        }
        if label == modelID, !providerPrefix.isEmpty, modelID.lowercased().hasPrefix(providerPrefix) {
            label = String(modelID.dropFirst(providerPrefix.count))
        }
        return label
    }

    private func orderedAgentsForPicker(_ agents: [AgentSummary]) -> [AgentSummary] {
        guard let selectedIndex = agents.firstIndex(where: { $0.id == agent.id }) else {
            return agents
        }
        var ordered = agents
        let selectedAgent = ordered.remove(at: selectedIndex)
        ordered.insert(selectedAgent, at: 0)
        return ordered
    }

    private func showProviderPicker() async {
        let config = await runtime.service.getConfig()
        let agentConfig = try? await runtime.service.getAgentConfig(agentID: agent.id)
        let selected = agentConfig?.selectedModel ?? selectedModel
        selectedModel = selected

        var items = config.models
            .filter { !$0.disabled }
            .map { model -> SloppyTUIPickerItem in
                let runtimeModel = runtimeModelID(for: model)
                return SloppyTUIPickerItem(
                    value: runtimeModel,
                    label: providerTitle(for: model),
                    description: SloppyTUITheme.compactPickerDescription(runtimeModel),
                    isCurrent: runtimeModel == selected || model.model == selected
                )
            }

        items.sort { lhs, rhs in
            if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
            return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }
        items.append(
            SloppyTUIPickerItem(
                value: SloppyTUIProviderDefinition.addNewProviderValue,
                label: "+ Add new provider",
                description: "Configure another provider",
                isCurrent: false
            )
        )

        activePicker = SloppyTUIPicker(
            kind: .provider,
            title: "Select provider",
            items: items,
            selectedIndex: 0
        )
        refreshStaticChrome(statusLine: "select provider with arrows, Enter to apply, Esc to cancel")
    }

    private func showProviderCatalogPicker() {
        activePicker = SloppyTUIPicker(
            kind: .providerCatalog,
            title: "Add provider",
            items: SloppyTUIProviderDefinition.catalog.map { definition in
                SloppyTUIPickerItem(
                    value: definition.id,
                    label: definition.title,
                    description: definition.setupDescription,
                    isCurrent: false
                )
            },
            selectedIndex: 0
        )
        refreshStaticChrome(statusLine: "select provider type with arrows, Enter to configure, Esc to cancel")
    }

    private func beginProviderSetup(_ providerID: String) async {
        let definition = SloppyTUIProviderDefinition(providerID)
        switch definition.id {
        case "openai-oauth":
            await startOpenAIDeviceFlow()
        case "anthropic-oauth":
            await startAnthropicOAuth()
        default:
            if definition.requiresAPIKey {
                editor.setText("/provider \(definition.id) ")
                persistDraft(editor.getText())
                refreshStaticChrome(statusLine: "enter API key for \(definition.title), optionally followed by a model")
            } else {
                await configureProvider([definition.id])
            }
        }
    }

    private func switchAgent(_ agentID: String) async {
        do {
            let agents = try await runtime.service.listAgents(includeSystem: false)
            guard let nextAgent = agents.first(where: { $0.id == agentID }) else {
                appendLocalCard("Agent `\(agentID)` is no longer available.")
                return
            }
            agent = nextAgent
            session = SloppyTUIApp.makeDraftSession(agent: nextAgent, projectID: project.id)
            hasPersistedSession = false
            pendingDraftCheckpointSessionID = nil
            sessionCards = []
            subSessionCards = []
            invalidateSessionTimelineCache()
            lastRenderedSessionEventIDs = []
            persistSelection()
            streamTask?.cancel()
            await reloadSkillSlashCommands()
            await refreshSelectedModel()
            appendLocalCard("Agent switched to `\(nextAgent.displayName)`.")
        } catch {
            appendLocalCard("Agent switch failed: \(String(describing: error))")
        }
    }

    private func switchSession(_ sessionID: String) async {
        var sessions = (try? await runtime.service.listAgentSessions(agentID: agent.id, projectID: project.id)) ?? []
        if !sessions.contains(where: { $0.id == sessionID }) {
            sessions = (try? await runtime.service.listAgentSessions(agentID: agent.id)) ?? sessions
        }
        guard let nextSession = sessions.first(where: { $0.id == sessionID }) else {
            appendLocalCard("Session `\(sessionID)` is no longer available for `\(agent.displayName)`.")
            return
        }
        session = nextSession
        hasPersistedSession = true
        pendingDraftCheckpointSessionID = nil
        persistSelection()
        streamSession()
        await restorePersistedDirectoriesForCurrentSession()
        loadProjectFileIndex()
        await reloadSession()
        appendLocalCard("Session switched to `\(nextSession.title)`.\nResume shortcut: `sloppy -s \(nextSession.id)`")
    }

    private func attachContext(_ mode: String?) async {
        switch mode?.lowercased() {
        case "changes":
            guard let lastChangeBatch else {
                appendLocalCard("No workspace change batch yet.")
                return
            }
            let paths = lastChangeBatch.changes.map { "- \($0.kind.rawValue): \($0.path)" }.joined(separator: "\n")
            pendingContext = "Workspace changes:\n\(paths)"
            appendLocalCard("Workspace change list will be attached to the next message.")
        case "diff":
            do {
                let git = try await runtime.service.projectWorkingTreeGit(projectID: project.id)
                guard git.isGitRepository, !git.diff.isEmpty else {
                    appendLocalCard(git.message ?? "No git diff to attach.")
                    return
                }
                pendingContext = "Git working tree diff:\n```diff\n\(git.diff)\n```"
                appendLocalCard("Git diff will be attached to the next message.")
            } catch {
                appendLocalCard("Could not read git diff: \(String(describing: error))")
            }
        default:
            appendLocalCard("Use `/context changes` or `/context diff`.")
        }
    }

    private func reloadProjectForTaskAutocompleteIfNeeded() {
        guard SloppyTUIAutocompleteFeatureFlags.projectTaskAutocompleteEnabled,
              projectTaskAutocompleteTask == nil,
              !projectTaskAutocompleteLoading else {
            return
        }
        projectTaskAutocompleteLoading = true
        projectTaskAutocompleteTask = Task { [weak self] in
            guard let self else { return }
            do {
                let refreshed = try await runtime.service.getProject(id: project.id)
                await MainActor.run {
                    self.project = refreshed
                    self.projectTaskGeneration += 1
                    self.projectTaskSearchCache = nil
                    self.projectTaskAutocompleteLoading = false
                    self.projectTaskAutocompleteTask = nil
                    self.requestRender()
                }
            } catch {
                await MainActor.run {
                    self.projectTaskAutocompleteLoading = false
                    self.projectTaskAutocompleteTask = nil
                }
            }
        }
    }

    private func showTasks() async {
        do {
            let refreshed = try await runtime.service.getProject(id: project.id)
            project = refreshed
            projectTaskGeneration += 1
            projectTaskSearchCache = nil
            if refreshed.tasks.isEmpty {
                appendLocalCard("No project tasks.")
                return
            }
            appendLocalCard(refreshed.tasks.map { "- `\($0.id)` [\($0.status)] \($0.title)" }.joined(separator: "\n"))
        } catch {
            appendLocalCard("Could not load tasks: \(String(describing: error))")
        }
    }

    private func runtimeModelID(for model: CoreConfig.ModelConfig) -> String {
        let rawModel = model.model.trimmingCharacters(in: .whitespacesAndNewlines)
        return runtimeModelID(rawModel, provider: providerDefinition(for: model))
    }

    private func runtimeModelID(_ rawModel: String, provider: SloppyTUIProviderDefinition) -> String {
        let rawModel = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawModel.hasPrefix("openai:")
            || rawModel.hasPrefix("openrouter:")
            || rawModel.hasPrefix("ollama:")
            || rawModel.hasPrefix("gemini:")
            || rawModel.hasPrefix("anthropic:") {
            return rawModel
        }
        return provider.runtimeModelID(rawModel)
    }

    private func providerTitle(for model: CoreConfig.ModelConfig) -> String {
        providerDefinition(for: model).title
    }

    private func providerDefinition(for model: CoreConfig.ModelConfig) -> SloppyTUIProviderDefinition {
        if let catalog = model.providerCatalogId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !catalog.isEmpty {
            return SloppyTUIProviderDefinition(catalog)
        }
        let title = model.title.lowercased()
        let apiURL = model.apiUrl.lowercased()
        let rawModel = model.model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if rawModel.hasPrefix("openrouter:") {
            return SloppyTUIProviderDefinition("openrouter")
        }
        if rawModel.hasPrefix("ollama:") {
            return SloppyTUIProviderDefinition("ollama")
        }
        if rawModel.hasPrefix("gemini:") {
            return SloppyTUIProviderDefinition("gemini")
        }
        if rawModel.hasPrefix("anthropic:") {
            return SloppyTUIProviderDefinition("anthropic")
        }
        if rawModel.hasPrefix("openai:") {
            return title.contains("oauth") ? SloppyTUIProviderDefinition("openai-oauth") : SloppyTUIProviderDefinition("openai-api")
        }
        if title.contains("openrouter") || apiURL.contains("openrouter") {
            return SloppyTUIProviderDefinition("openrouter")
        }
        if title.contains("gemini") || apiURL.contains("generativelanguage") {
            return SloppyTUIProviderDefinition("gemini")
        }
        if title.contains("anthropic") || apiURL.contains("anthropic") {
            return SloppyTUIProviderDefinition("anthropic")
        }
        if title.contains("ollama") || apiURL.contains("11434") {
            return SloppyTUIProviderDefinition("ollama")
        }
        if title.contains("oauth") || apiURL.contains("chatgpt.com") {
            return SloppyTUIProviderDefinition("openai-oauth")
        }
        return SloppyTUIProviderDefinition("openai-api")
    }

    private func configureProvider(_ args: [String]) async {
        guard let providerID = args.first else {
            appendLocalCard("Usage: `/provider openai-api|openrouter|gemini|anthropic|ollama <api-key> [model]`")
            return
        }
        let key = args.dropFirst().first ?? ""
        let model = args.dropFirst(2).first
        let definition = SloppyTUIProviderDefinition(providerID)
        if definition.requiresAPIKey && key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendLocalCard("Enter an API key: `/provider \(definition.id) <api-key> [model]`")
            return
        }
        var config = await runtime.service.getConfig()
        config.workspace.name = CoreConfig.defaultWorkspaceName
        config.workspace.basePath = "~"
        let entry = CoreConfig.ModelConfig(
            title: definition.title,
            apiKey: definition.requiresAPIKey ? key : "",
            apiUrl: definition.apiURL,
            model: model ?? definition.model,
            providerCatalogId: definition.id
        )
        if let existingIndex = config.models.firstIndex(where: { providerDefinition(for: $0).id == definition.id }) {
            config.models[existingIndex] = entry
        } else {
            config.models.append(entry)
        }
        config.onboarding.completed = false
        do {
            _ = try await runtime.service.updateConfig(config)
            dismissFirstStartBootstrapCard()
            appendLocalCard("Provider saved as `\(definition.id)`. Use `/model \(definition.runtimeModelID(model ?? definition.model))` if you want to switch the active agent now.")
        } catch {
            appendLocalCard("Provider save failed: \(String(describing: error))")
        }
    }

    private func startOpenAIDeviceFlow() async {
        do {
            let response = try await runtime.service.startOpenAIDeviceCode()
            appendLocalCard("""
            ## OpenAI Codex device auth
            Open \(response.verificationURL) and enter code `\(response.userCode)`.
            Polling automatically until approval or timeout.
            """)
            devicePollTask?.cancel()
            devicePollTask = Task { [weak self] in
                guard let self else { return }
                let deadline = Date().addingTimeInterval(TimeInterval(response.expiresIn))
                while !Task.isCancelled, Date() < deadline {
                    try? await Task.sleep(nanoseconds: UInt64(max(response.interval, 2)) * 1_000_000_000)
                    guard !Task.isCancelled else { break }
                    do {
                        let poll = try await self.runtime.service.pollOpenAIDeviceCode(
                            request: .init(deviceAuthId: response.deviceAuthId, userCode: response.userCode)
                        )
                        await MainActor.run {
                            self.appendLocalCard("OpenAI device auth: \(poll.message)")
                        }
                        if poll.ok { break }
                    } catch {
                        await MainActor.run {
                            self.appendLocalCard("OpenAI device auth failed: \(String(describing: error))")
                        }
                        break
                    }
                }
            }
            await configureProvider(["openai-oauth"])
        } catch {
            appendLocalCard("Could not start OpenAI device flow: \(String(describing: error))")
        }
    }

    private func startAnthropicOAuth() async {
        do {
            let response = try await runtime.service.startAnthropicOAuth(
                request: .init(redirectURI: "http://localhost:54545/oauth/anthropic/callback")
            )
            appendLocalCard("""
            ## Anthropic OAuth
            Open \(response.authorizationURL)

            Then paste the callback URL with `/anthropic-callback <url>`.
            """)
            await configureProvider(["anthropic-oauth", ""])
        } catch {
            appendLocalCard("Could not start Anthropic OAuth: \(String(describing: error))")
        }
    }

    private func completeAnthropicOAuth(_ callbackURL: String) async {
        guard !callbackURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            appendLocalCard("Paste the full callback URL: `/anthropic-callback <url>`.")
            return
        }
        do {
            let response = try await runtime.service.completeAnthropicOAuth(request: .init(callbackURL: callbackURL))
            appendLocalCard(response.message)
        } catch {
            appendLocalCard("Anthropic OAuth failed: \(String(describing: error))")
        }
    }

    private func streamSession() {
        guard hasPersistedSession else {
            streamTask?.cancel()
            streamTask = nil
            return
        }
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await self.runtime.service.streamAgentSessionEvents(agentID: self.agent.id, sessionID: self.session.id)
                for await update in stream {
                    guard !Task.isCancelled else { break }
                    await MainActor.run {
                        if update.kind == .sessionDelta, let message = update.message {
                            self.updateLiveAssistantDraftTarget(message)
                        } else if update.kind == .sessionEvent, let event = update.event {
                            if let status = event.runStatus {
                                if status.stage == .done || status.stage == .interrupted {
                                    self.liveRunStatusLine = nil
                                } else {
                                    self.liveRunStatusLine = self.runStatusLine(status)
                                }
                                self.refreshStaticChrome()
                                self.notifyForRunStatus(status)
                            }
                            if let inputRequest = event.inputRequest {
                                self.settleLiveAssistantDraft()
                                self.notifyForInputRequest(inputRequest)
                            }
                            if self.isFinalAssistantMessage(event) {
                                self.clearLiveAssistantDraft()
                                self.stopThinkingAnimation()
                            }
                            Task { await self.reloadSession() }
                        } else if update.kind == .sessionClosed {
                            self.clearLiveAssistantDraft()
                            self.stopThinkingAnimation()
                            self.appendLocalCard(update.message ?? "Session closed.")
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.appendLocalCard("Session stream failed: \(String(describing: error))")
                }
            }
        }
    }

    private func streamChanges() {
        changeTask?.cancel()
        changeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await self.runtime.service.streamProjectWorkingTreeChanges(projectID: self.project.id)
                for await batch in stream {
                    guard !Task.isCancelled else { break }
                    await MainActor.run {
                        self.lastChangeBatch = batch
                        self.scheduleProjectFileReindex()
                    }
                }
            } catch {
                // Keep workspace watching silent so the timeline only shows agent output.
            }
        }
    }

    private func loadProjectFileIndex() {
        projectFileIndexTask?.cancel()
        projectFileIndexLoading = true
        requestRender()
        projectFileIndexTask = Task { [weak self] in
            guard let self else { return }
            do {
                let rootURL = try await runtime.service.resolveProjectWorkspaceRoot(projectID: project.id)
                projectFileRootURL = rootURL

                let additionalRoots = indexedAdditionalDirectoryURLs(projectRootURL: rootURL)
                let rootPath = projectFileIndexRootPath(rootURL: rootURL, additionalRootURLs: additionalRoots)
                let workspaceRoot = runtime.workspaceRoot
                let projectID = project.id
                let cached = await Task.detached(priority: .utility) {
                    ProjectFileIndexStore(workspaceRoot: workspaceRoot).load(projectId: projectID, rootPath: rootPath)
                }.value
                if let cached {
                    applyProjectFileIndex(cached)
                    scheduleProjectFileReindex(afterNanoseconds: 5_000_000_000)
                    return
                }

                rebuildProjectFileIndex(rootURL: rootURL)
            } catch {
                projectFileRootURL = nil
                applyProjectFileIndex(nil)
            }
        }
    }

    private func scheduleProjectFileReindex(afterNanoseconds delay: UInt64 = 1_200_000_000) {
        guard let rootURL = projectFileRootURL else {
            loadProjectFileIndex()
            return
        }

        projectFileReindexTask?.cancel()
        projectFileReindexTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.rebuildProjectFileIndex(rootURL: rootURL)
        }
    }

    private func rebuildProjectFileIndex(rootURL: URL) {
        projectFileReindexTask?.cancel()
        projectFileIndexLoading = true
        requestRender()
        let projectID = project.id
        let workspaceRoot = runtime.workspaceRoot
        let additionalRoots = indexedAdditionalDirectoryURLs(projectRootURL: rootURL)
        let rootPath = projectFileIndexRootPath(rootURL: rootURL, additionalRootURLs: additionalRoots)
        projectFileReindexTask = Task { [weak self] in
            let buildTask = Task.detached(priority: .utility) {
                var index = ProjectFileIndex.build(
                    projectId: projectID,
                    rootURL: rootURL,
                    additionalRootURLs: additionalRoots
                )
                index.rootPath = rootPath
                guard !Task.isCancelled else {
                    return nil as ProjectFileIndex?
                }
                ProjectFileIndexStore(workspaceRoot: workspaceRoot).save(index)
                return index as ProjectFileIndex?
            }
            let index = await withTaskCancellationHandler {
                await buildTask.value
            } onCancel: {
                buildTask.cancel()
            }

            guard !Task.isCancelled, let index else { return }
            self?.applyProjectFileIndex(index)
        }
    }

    private func applyProjectFileIndex(_ index: ProjectFileIndex?) {
        projectFileIndex = index
        projectFileIndexLoading = false
        projectFileIndexGeneration += 1
        projectFileSearchCache = nil
        requestRender()
    }

    private func reloadSkillSlashCommands() async {
        do {
            let response = try await runtime.service.buildAgentChatSlashCommands(agentID: agent.id)
            let skills = response.commands
                .filter { $0.source == "skill" }
                .compactMap { item -> SloppyTUISlashCommand? in
                    let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return nil }
                    return SloppyTUISlashCommand(name, item.description, argument: item.argument ?? "message")
                }
            skillSlashCommands = skills
            skillSlashCommandNames = Set(skills.map { $0.name.lowercased() })
            requestRender()
        } catch {
            skillSlashCommands = []
            skillSlashCommandNames = []
        }
    }

    private func reloadSession() async {
        guard hasPersistedSession else {
            sessionCards = []
            subSessionCards = []
            invalidateSessionTimelineCache()
            lastRenderedSessionEventIDs = []
            renderTimeline()
            refreshStaticChrome()
            return
        }
        let detail = try? await runtime.service.getAgentSession(agentID: agent.id, sessionID: session.id)
        var blocks: [SloppyTUITimelineBlock] = []
        var children: [SloppyTUISubSessionCard] = []
        let events = detail?.events ?? []
        let childStatuses = await subSessionStatuses(for: childSessionIDs(in: events))
        let answeredInputRequestIDs = Set(events.compactMap { event -> String? in
            event.type == .inputResponse ? event.inputResponse?.requestId : nil
        })
        let pendingInputRequest = events.compactMap { event -> PlanInputRequest? in
            event.type == .inputRequest ? event.inputRequest : nil
        }.last { request in
            !answeredInputRequestIDs.contains(request.id)
        }
        let latestBuildProgressID = events.reversed().first { event in
            event.type == .buildProgress && event.buildProgress != nil
        }?.id
        lastRenderedSessionEventIDs = Set(events.map(\.id))
        for event in events {
            if let message = event.message {
                let body = message.segments
                    .filter { $0.kind == .text }
                    .compactMap(\.text)
                    .joined(separator: "\n")
                let thinking = message.segments
                    .filter { $0.kind == .thinking }
                    .compactMap(\.text)
                    .joined(separator: "\n")
                let attachments = message.segments
                    .filter { $0.kind == .attachment }
                    .compactMap(\.attachment)
                if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let displayBody = SloppyTUITimelineDisplay.messageText(role: message.role, text: body)
                    if message.role == .assistant, SloppyTUITheme.isModelProviderError(body) {
                        blocks.append(.error(body))
                    } else {
                        blocks.append(.message(role: message.role, text: displayBody))
                    }
                }
                if !thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append(.thinking(thinking))
                }
                for attachment in attachments {
                    blocks.append(.attachment(name: attachment.name, mimeType: attachment.mimeType, sizeBytes: attachment.sizeBytes))
                }
            } else if let subSession = event.subSession {
                let card = SloppyTUISubSessionCard(
                    childSessionId: subSession.childSessionId,
                    title: subSession.title,
                    status: childStatuses[subSession.childSessionId] ?? .starting
                )
                children.append(card)
                blocks.append(.subSession(childSessionId: card.childSessionId, title: card.title, status: card.status))
            } else if let toolCall = event.toolCall {
                let display = toolCallDisplay(tool: toolCall.tool, arguments: toolCall.arguments)
                blocks.append(.toolCall(
                    tool: toolCall.tool,
                    reason: toolCall.reason,
                    summary: display.summary,
                    details: display.details
                ))
            } else if let toolResult = event.toolResult {
                blocks.append(.toolResult(
                    tool: toolResult.tool,
                    ok: toolResult.ok,
                    error: toolResult.error?.message,
                    durationMs: toolResult.durationMs,
                    details: toolResultDisplay(toolResult)
                ))
            } else if event.type == .inputRequest, let inputRequest = event.inputRequest {
                if !answeredInputRequestIDs.contains(inputRequest.id) {
                    blocks.append(.inputRequest(inputRequest))
                }
            } else if event.id == latestBuildProgressID, let progress = event.buildProgress {
                blocks.append(.buildProgress(progress))
            }
        }
        sessionCards = blocks
        subSessionCards = children
        invalidateSessionTimelineCache()
        updatePendingPlanInputRequest(pendingInputRequest)
        await refreshTokenUsage(includeCost: false)
        renderTimeline()
    }

    private func childSessionIDs(in events: [AgentSessionEvent]) -> [String] {
        var seen: Set<String> = []
        var ids: [String] = []
        for event in events {
            guard let childSessionID = event.subSession?.childSessionId,
                  seen.insert(childSessionID).inserted else {
                continue
            }
            ids.append(childSessionID)
        }
        return ids
    }

    private func subSessionStatuses(for childSessionIDs: [String]) async -> [String: SloppyTUISubSessionStatus] {
        var statuses: [String: SloppyTUISubSessionStatus] = [:]
        for childSessionID in childSessionIDs {
            guard let detail = try? await runtime.service.getAgentSession(agentID: agent.id, sessionID: childSessionID) else {
                statuses[childSessionID] = .starting
                continue
            }
            statuses[childSessionID] = subSessionStatus(from: detail.events)
        }
        return statuses
    }

    private func subSessionStatus(from events: [AgentSessionEvent]) -> SloppyTUISubSessionStatus {
        guard !events.isEmpty else {
            return .starting
        }

        let answeredInputRequestIDs = Set(events.compactMap { event -> String? in
            event.type == .inputResponse ? event.inputResponse?.requestId : nil
        })
        if let inputRequest = events.compactMap({ event -> PlanInputRequest? in
            event.type == .inputRequest ? event.inputRequest : nil
        }).last(where: { request in
            !answeredInputRequestIDs.contains(request.id)
        }) {
            return .waiting(planInputStatusLabel(inputRequest))
        }

        if let status = events.reversed().compactMap(\.runStatus).first {
            let label = status.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = label.isEmpty ? status.details?.trimmingCharacters(in: .whitespacesAndNewlines) : label
            switch status.stage {
            case .thinking, .searching, .responding:
                return .running(detail)
            case .paused:
                return .waiting(detail)
            case .done:
                return .done
            case .interrupted:
                return .interrupted(detail)
            }
        }

        let hasAssistantText = events.contains { event in
            guard event.type == .message,
                  let message = event.message,
                  message.role == .assistant else {
                return false
            }
            return message.segments.contains { segment in
                segment.kind == .text && segment.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            }
        }
        return hasAssistantText ? .done : .starting
    }

    private func planInputStatusLabel(_ request: PlanInputRequest) -> String {
        if let title = request.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        if let header = request.questions.first?.header?.trimmingCharacters(in: .whitespacesAndNewlines), !header.isEmpty {
            return header
        }
        return "input needed"
    }

    private func refreshTokenUsage(includeCost: Bool) async {
        let usage = await runtime.service.listTokenUsage(channelId: currentSessionChannelID())
        if includeCost {
            if let agentUsage = try? await runtime.service.getAgentTokenUsage(agentID: agent.id) {
                tokenUsageCostUSD = agentUsage.totalCostUSD
            }
        }
        tokenUsageSummary = SloppyTUITokenUsageSummary(
            promptTokens: usage.totalPromptTokens,
            completionTokens: usage.totalCompletionTokens,
            totalTokens: usage.totalTokens,
            contextWindowTokens: selectedModelContextWindowTokens,
            costUSD: tokenUsageCostUSD
        )
        refreshStaticChrome()
    }

    private func currentSessionChannelID() -> String {
        "agent:\(agent.id):session:\(session.id)"
    }

    private func contextWindowTokens(for modelID: String, in models: [ProviderModelOption]) -> Int {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let option = models.first { $0.id == trimmed } ?? models.first
        guard let value = option?.contextWindow else {
            return 0
        }
        return CoreService.parseContextWindowString(value)
    }

    private func isFinalAssistantMessage(_ event: AgentSessionEvent) -> Bool {
        guard event.type == .message,
              let message = event.message,
              message.role == .assistant else {
            return false
        }
        return message.segments.contains { segment in
            segment.kind == .text && segment.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }

    private func toolCallDisplay(
        tool: String,
        arguments: [String: JSONValue]
    ) -> (summary: String?, details: String?) {
        switch tool {
        case "runtime.exec":
            let command = arguments["command"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let argv = arguments["arguments"]?.asArray?.compactMap(\.asString) ?? []
            let fullCommand = ([command] + argv).filter { !$0.isEmpty }.map(shellQuote).joined(separator: " ")
            let cwd = arguments["cwd"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines)
            var details = fullCommand.isEmpty ? nil : fencedBlock("shell", fullCommand, maxCharacters: 4_000)
            if let cwd, !cwd.isEmpty {
                details = ([details, "cwd: `\(cwd)`"].compactMap { $0 }).joined(separator: "\n\n")
            }
            return (clip(fullCommand, maxCharacters: 160), details)
        case "files.edit":
            let path = arguments["path"]?.asString
            let search = arguments["search"]?.asString
            let replace = arguments["replace"]?.asString
            let details = editPreview(search: search, replace: replace)
            return (path.map { "path: \($0)" }, details)
        case "files.write":
            let path = arguments["path"]?.asString
            let content = arguments["content"]?.asString
            let details = content.map { fencedBlock("text", $0, maxCharacters: 4_000) }
            return (path.map { "path: \($0)" }, details)
        default:
            let keys = arguments.keys.sorted()
            let details = arguments.isEmpty ? nil : fencedBlock("json", prettyJSON(.object(arguments)), maxCharacters: 4_000)
            return (keys.isEmpty ? nil : keys.joined(separator: ", "), details)
        }
    }

    private func toolResultDisplay(_ result: AgentToolResultEvent) -> String? {
        var parts: [String] = []

        if let error = result.error {
            parts.append("error code: `\(error.code)`")
            if let hint = error.hint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
                parts.append("hint: \(hint)")
            }
        }

        if result.tool == "runtime.exec",
           let data = result.data?.asObject {
            if let exitCode = data["exitCode"]?.asInt {
                parts.append("exit code: `\(exitCode)`")
            }
            if data["timedOut"]?.asBool == true {
                parts.append("timed out")
            }
            if let stdout = data["stdout"]?.asString, !stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append("stdout:\n" + fencedBlock("text", stdout, maxCharacters: 6_000))
            }
            if let stderr = data["stderr"]?.asString, !stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append("stderr:\n" + fencedBlock("text", stderr, maxCharacters: 6_000))
            }
        } else if let data = result.data {
            parts.append(fencedBlock("json", prettyJSON(data), maxCharacters: 4_000))
        }

        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    private func editPreview(search: String?, replace: String?) -> String? {
        guard let search, let replace else {
            return nil
        }
        let removed = search.split(separator: "\n", omittingEmptySubsequences: false).map { "-\(String($0))" }
        let added = replace.split(separator: "\n", omittingEmptySubsequences: false).map { "+\(String($0))" }
        return fencedBlock("diff", (removed + added).joined(separator: "\n"), maxCharacters: 6_000)
    }

    private func fencedBlock(_ language: String, _ text: String, maxCharacters: Int) -> String {
        let safeText = clip(text.replacingOccurrences(of: "```", with: "` ` `"), maxCharacters: maxCharacters)
        return "```\(language)\n\(safeText)\n```"
    }

    private func prettyJSON(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return string
    }

    private func clip(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else {
            return text
        }
        return String(text.prefix(max(0, maxCharacters - 14))) + "\n... truncated"
    }

    private func shellQuote(_ value: String) -> String {
        guard !value.isEmpty else {
            return "''"
        }
        let safeCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
        if value.unicodeScalars.allSatisfy({ safeCharacters.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func invalidateSessionTimelineCache() {
        sessionTimelineRevision += 1
        sessionTimelineCache = nil
    }

    private func renderTimeline() {
        if sessionCards.isEmpty,
           liveAssistantDraft == nil,
           queuedMessages.isEmpty,
           localCards.isEmpty {
            timeline.text = ""
        }
        refreshStaticChrome()
        requestRender()
    }

    private func indexedAdditionalDirectoryURLs(projectRootURL: URL) -> [URL] {
        let projectRootPath = projectRootURL.resolvingSymlinksInPath().standardizedFileURL.path
        var seen = Set<String>()
        return persistedDirectoriesForCurrentSession().compactMap { path in
            let url = URL(fileURLWithPath: path, isDirectory: true)
                .resolvingSymlinksInPath()
                .standardizedFileURL
            guard url.path != projectRootPath,
                  seen.insert(url.path).inserted
            else {
                return nil
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                return nil
            }
            return url
        }
    }

    private func projectFileIndexRootPath(rootURL: URL, additionalRootURLs: [URL]) -> String {
        ([rootURL.resolvingSymlinksInPath().standardizedFileURL.path] + additionalRootURLs.map(\.path))
            .joined(separator: "\n")
    }

    private func liveAssistantBlocks() -> [SloppyTUITimelineBlock] {
        guard let liveAssistantDraft else {
            return []
        }

        let spinner = SloppyTUITheme.waitingIndicator(frame: thinkingFrame, word: thinkingWord)
        let body = liveAssistantDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty {
            return [.local(spinner)]
        }
        return [.message(role: .assistant, text: body + "\n\n" + spinner)]
    }

    private func queuedMessageBlocks() -> [SloppyTUITimelineBlock] {
        queuedMessages.messages.map { .queuedMessage($0) }
    }

    private func renderTimelineBlocks(width: Int, height: Int) -> [String] {
        let sessionTimeline = cachedSessionTimelineLines(width: width)
        let dynamicBlocks = liveAssistantBlocks() + queuedMessageBlocks() + localCards.map(\.block)
        let dynamicLines = renderTimelineLines(dynamicBlocks, width: width)
        let containsToolTranscriptBlock = sessionTimeline.containsToolTranscriptBlock
            || dynamicBlocks.contains(where: isToolTranscriptBlock)

        var segments: [[String]] = []
        if !sessionTimeline.lines.isEmpty {
            segments.append(sessionTimeline.lines)
        }
        if !dynamicLines.isEmpty {
            if !segments.isEmpty {
                segments.append([""])
            }
            segments.append(dynamicLines)
        }
        if transcriptExpanded || containsToolTranscriptBlock {
            if !segments.isEmpty {
                segments.append([""])
            }
            segments.append([
                SloppyTUITheme.transcriptHintLine(
                    expanded: transcriptExpanded,
                    childSessionCount: subSessionCards.count,
                    width: width
                ),
            ])
        }

        if segments.isEmpty {
            return timeline.render(width: width)
        }

        return visibleTimelineLines(segments, height: height)
    }

    private func cachedSessionTimelineLines(width: Int) -> (lines: [String], containsToolTranscriptBlock: Bool) {
        let animationFrameKey = shouldAnimateCachedSessionBlocks ? thinkingFrame : 0
        if let cache = sessionTimelineCache,
           cache.revision == sessionTimelineRevision,
           cache.width == width,
           cache.transcriptExpanded == transcriptExpanded,
           cache.animationFrameKey == animationFrameKey {
            return (cache.lines, cache.containsToolTranscriptBlock)
        }

        let lines = renderTimelineLines(sessionCards, width: width)
        let containsToolTranscriptBlock = sessionCards.contains(where: isToolTranscriptBlock)
        sessionTimelineCache = SloppyTUISessionTimelineCache(
            revision: sessionTimelineRevision,
            width: width,
            transcriptExpanded: transcriptExpanded,
            animationFrameKey: animationFrameKey,
            lines: lines,
            containsToolTranscriptBlock: containsToolTranscriptBlock
        )
        return (lines, containsToolTranscriptBlock)
    }

    private var shouldAnimateCachedSessionBlocks: Bool {
        sessionCards.count <= SloppyTUITimelinePerformance.animatedSessionBlockLimit
            && sessionCards.contains(where: isAnimatedTimelineBlock)
    }

    private func renderTimelineLines(_ blocks: [SloppyTUITimelineBlock], width: Int) -> [String] {
        guard !blocks.isEmpty else {
            return []
        }

        var lines: [String] = []
        var index = 0
        while index < blocks.count {
            let block = blocks[index]
            if !lines.isEmpty {
                lines.append("")
            }

            if !transcriptExpanded, isToolTranscriptBlock(block) {
                let endIndex = compactToolGroupEnd(startingAt: index, in: blocks)
                appendCompactToolGroup(Array(blocks[index..<endIndex]), to: &lines, width: width)
                index = endIndex
                continue
            }

            switch block {
            case .message(let role, let text):
                if role == .user {
                    lines.append(contentsOf: SloppyTUITheme.userMessageLines(text, width: width))
                } else {
                    lines.append(contentsOf: renderMarkdown(text, width: width))
                }
            case .local(let text):
                lines.append(contentsOf: renderMarkdown(text, width: width))
            case .queuedMessage(let message):
                lines.append(contentsOf: SloppyTUITheme.queuedMessageLines(message, width: width))
            case .error(let text):
                lines.append(contentsOf: renderMarkdown(SloppyTUITheme.errorBlock(text), width: width))
            case .thinking(let text):
                lines.append(contentsOf: SloppyTUITheme.thinkingLines(text, width: width))
            case .attachment(let name, let mimeType, let sizeBytes):
                lines.append(SloppyTUITheme.attachmentLine(name: name, mimeType: mimeType, sizeBytes: sizeBytes, width: width))
            case .subSession(let childSessionId, let title, let status):
                lines.append(SloppyTUITheme.subSessionLine(
                    title: title,
                    childSessionId: childSessionId,
                    status: status,
                    frame: thinkingFrame,
                    width: width
                ))
            case .buildProgress(let progress):
                lines.append(contentsOf: SloppyTUITheme.buildProgressLines(progress, width: width))
            case .inputRequest(let request):
                lines.append(contentsOf: renderMarkdown(SloppyTUIPlanInputPicker.requestText(request), width: width))
            case .toolCall(let tool, let reason, let summary, let details):
                lines.append(SloppyTUITheme.toolCallLine(tool: tool, reason: reason, summary: summary, width: width))
                if transcriptExpanded, let details, !details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines.append(contentsOf: renderMarkdown(details, width: width))
                }
            case .toolResult(let tool, let ok, let error, let durationMs, let details):
                lines.append(SloppyTUITheme.toolResultLine(tool: tool, ok: ok, error: error, durationMs: durationMs, width: width))
                if transcriptExpanded, let details, !details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines.append(contentsOf: renderMarkdown(details, width: width))
                }
            }
            index += 1
        }

        return lines
    }

    private func isToolTranscriptBlock(_ block: SloppyTUITimelineBlock) -> Bool {
        switch block {
        case .toolCall, .toolResult:
            return true
        default:
            return false
        }
    }

    private func isAnimatedTimelineBlock(_ block: SloppyTUITimelineBlock) -> Bool {
        switch block {
        case .subSession:
            return true
        default:
            return false
        }
    }

    private func updatePendingPlanInputRequest(_ request: PlanInputRequest?) {
        let previousRequestID = pendingPlanInputRequest?.id
        let previousSelectedIndex = activePicker?.kind == .planInput ? activePicker?.selectedIndex ?? 0 : 0
        pendingPlanInputRequest = request

        guard let request else {
            if activePicker?.kind == .planInput {
                activePicker = nil
                refreshStaticChrome()
            }
            return
        }

        guard activePicker == nil || activePicker?.kind == .planInput else {
            return
        }

        let selectedIndex = previousRequestID == request.id ? previousSelectedIndex : 0
        activePicker = SloppyTUIPlanInputPicker.picker(for: request, selectedIndex: selectedIndex)
        refreshStaticChrome(statusLine: "select answer with arrows, Enter to submit, Esc to cancel")
    }

    private func answerPlanInput(with item: SloppyTUIPickerItem) async {
        guard let request = pendingPlanInputRequest,
              let payload = SloppyTUIPlanInputPicker.answerRequest(for: item, request: request)
        else {
            appendLocalCard("Could not read the pending input request.", autoDismissAfter: 8)
            return
        }
        await submitPlanInput(request: request, payload: payload, busyLabel: "Submitting input answer...")
    }

    private func cancelPlanInputRequest() async {
        guard let request = pendingPlanInputRequest else {
            return
        }
        let payload = PlanInputAnswerRequest(status: .cancelled, answers: [], userId: "tui")
        await submitPlanInput(request: request, payload: payload, busyLabel: "Cancelling input request...")
    }

    private func submitPlanInput(
        request: PlanInputRequest,
        payload: PlanInputAnswerRequest,
        busyLabel: String
    ) async {
        guard !isPosting else {
            appendLocalCard("A message is already in flight. Use `/stop` if you need to interrupt it.")
            return
        }

        isPosting = true
        taskStartedAt = Date()
        lastTaskElapsed = nil
        liveRunStatusLine = busyLabel
        startThinkingAnimation()
        refreshStaticChrome(statusLine: busyLabel)
        let undoBaseline = await makeUndoBaseline()
        do {
            _ = try await runtime.service.answerAgentPlanInput(
                agentID: agent.id,
                sessionID: session.id,
                requestID: request.id,
                payload: payload
            )
            pendingPlanInputRequest = nil
            activePicker = nil
            recordUndoPointIfNeeded(undoBaseline)
            await reloadSession()
            await refreshTokenUsage(includeCost: true)
            petMood = payload.status == .answered ? .happy : petMood
        } catch {
            petMood = .sad
            pendingPlanInputRequest = request
            activePicker = SloppyTUIPlanInputPicker.picker(for: request)
            appendLocalCard("Input answer failed: \(String(describing: error))")
        }
        if let taskStartedAt {
            lastTaskElapsed = Date().timeIntervalSince(taskStartedAt)
        }
        taskStartedAt = nil
        isPosting = false
        stopThinkingAnimation()
        liveRunStatusLine = nil
        refreshStaticChrome()
        renderTimeline()
    }

    private func compactToolGroupEnd(startingAt startIndex: Int, in blocks: [SloppyTUITimelineBlock]) -> Int {
        var index = startIndex
        while index < blocks.count, isToolTranscriptBlock(blocks[index]) {
            index += 1
        }
        return index
    }

    private func appendCompactToolGroup(_ blocks: [SloppyTUITimelineBlock], to lines: inout [String], width: Int) {
        let visibleLimit = 4
        lines.append(SloppyTUITheme.toolPaddingLine(width: width))
        for block in blocks.prefix(visibleLimit) {
            switch block {
            case .toolCall(let tool, let reason, let summary, _):
                lines.append(SloppyTUITheme.toolCallLine(tool: tool, reason: reason, summary: summary, width: width))
            case .toolResult(let tool, let ok, let error, let durationMs, _):
                lines.append(SloppyTUITheme.toolResultLine(tool: tool, ok: ok, error: error, durationMs: durationMs, width: width))
            default:
                break
            }
        }
        let hiddenCount = blocks.count - visibleLimit
        if hiddenCount > 0 {
            lines.append(SloppyTUITheme.toolOverflowLine(hiddenCount: hiddenCount, width: width))
        }
        lines.append(SloppyTUITheme.toolPaddingLine(width: width))
    }

    private func visibleTimelineLines(_ segments: [[String]], height: Int) -> [String] {
        lastTimelineViewportHeight = max(1, height)
        let lineCount = segments.reduce(0) { $0 + $1.count }
        guard lineCount > height else {
            timelineScrollOffset = 0
            return segments.flatMap { $0 }
        }

        let maxOffset = max(0, lineCount - height)
        timelineScrollOffset = min(max(0, timelineScrollOffset), maxOffset)
        let end = lineCount - timelineScrollOffset
        let start = max(0, end - height)
        var visible: [String] = []
        visible.reserveCapacity(height)
        var segmentStart = 0
        for segment in segments {
            let segmentEnd = segmentStart + segment.count
            defer { segmentStart = segmentEnd }

            guard segmentEnd > start, segmentStart < end else {
                continue
            }

            let sliceStart = max(0, start - segmentStart)
            let sliceEnd = min(segment.count, end - segmentStart)
            visible.append(contentsOf: segment[sliceStart..<sliceEnd])
            if segmentEnd >= end {
                break
            }
        }
        return visible
    }

    private func renderMarkdown(_ text: String, width: Int) -> [String] {
        guard text.contains("```diff") else {
            return renderPlainMarkdown(text, width: width)
        }

        var lines: [String] = []
        var cursor = text.startIndex
        while let fenceStart = text[cursor...].range(of: "```diff") {
            appendPlainMarkdown(String(text[cursor..<fenceStart.lowerBound]), to: &lines, width: width)

            guard let firstNewline = text[fenceStart.upperBound...].firstIndex(of: "\n") else {
                cursor = fenceStart.upperBound
                continue
            }

            let diffStart = text.index(after: firstNewline)
            guard let fenceEnd = text[diffStart...].range(of: "```") else {
                lines.append(contentsOf: SloppyTUITheme.diffLines(String(text[diffStart...]), width: width))
                cursor = text.endIndex
                break
            }

            lines.append(contentsOf: SloppyTUITheme.diffLines(String(text[diffStart..<fenceEnd.lowerBound]), width: width))
            cursor = fenceEnd.upperBound
        }
        appendPlainMarkdown(String(text[cursor...]), to: &lines, width: width)
        return lines
    }

    private func appendPlainMarkdown(_ text: String, to lines: inout [String], width: Int) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        if !lines.isEmpty {
            lines.append("")
        }
        lines.append(contentsOf: renderPlainMarkdown(text, width: width))
    }

    private func renderPlainMarkdown(_ text: String, width: Int) -> [String] {
        let component = MarkdownComponent(
            text: text,
            padding: .init(horizontal: 1, vertical: 0),
            theme: timeline.theme
        )
        return component.render(width: width)
    }

    private func updateLiveAssistantDraftTarget(_ target: String) {
        guard !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        let current = liveAssistantDraft ?? ""
        if !SloppyTUILiveDraftPolicy.shouldInterpolate(current: current, target: target) {
            setLiveAssistantDraftImmediately(target)
            return
        }

        liveAssistantTarget = target
        if liveAssistantDraft == nil {
            liveAssistantDraft = ""
        }
        startLiveAssistantInterpolation()
    }

    private func setLiveAssistantDraftImmediately(_ value: String) {
        liveAssistantInterpolationTask?.cancel()
        liveAssistantInterpolationTask = nil
        liveAssistantTarget = value
        liveAssistantDraft = value
        renderTimeline()
    }

    private func settleLiveAssistantDraft() {
        liveAssistantInterpolationTask?.cancel()
        liveAssistantInterpolationTask = nil
        if let liveAssistantTarget {
            liveAssistantDraft = liveAssistantTarget
        }
        liveAssistantTarget = nil
        renderTimeline()
    }

    private func clearLiveAssistantDraft() {
        liveAssistantInterpolationTask?.cancel()
        liveAssistantInterpolationTask = nil
        liveAssistantTarget = nil
        liveAssistantDraft = nil
        renderTimeline()
    }

    private func startLiveAssistantInterpolation() {
        guard liveAssistantInterpolationTask == nil else {
            advanceLiveAssistantInterpolation()
            return
        }

        liveAssistantInterpolationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: SloppyTUIStreamTyping.intervalNanoseconds)
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    self?.advanceLiveAssistantInterpolation()
                }
            }
        }
        advanceLiveAssistantInterpolation()
    }

    private func advanceLiveAssistantInterpolation() {
        guard let target = liveAssistantTarget, let current = liveAssistantDraft else {
            liveAssistantInterpolationTask?.cancel()
            liveAssistantInterpolationTask = nil
            return
        }
        guard current != target else {
            liveAssistantInterpolationTask?.cancel()
            liveAssistantInterpolationTask = nil
            return
        }
        guard target.hasPrefix(current) else {
            setLiveAssistantDraftImmediately(target)
            return
        }

        let remaining = target.count - current.count
        let baseCharacters = max(
            1,
            Int(ceil(SloppyTUIStreamTyping.charactersPerSecond * SloppyTUIStreamTyping.intervalSeconds))
        )
        let catchupTicks = max(
            1,
            Int(ceil(SloppyTUIStreamTyping.maxCatchupSeconds / SloppyTUIStreamTyping.intervalSeconds))
        )
        let catchupCharacters = max(baseCharacters, Int(ceil(Double(remaining) / Double(catchupTicks))))
        let nextCount = current.count + min(remaining, catchupCharacters)
        let next = String(target.prefix(nextCount))
        liveAssistantDraft = next
        renderTimeline()
        if next == target {
            liveAssistantInterpolationTask?.cancel()
            liveAssistantInterpolationTask = nil
        }
    }

    private func startThinkingAnimation() {
        thinkingAnimationTask?.cancel()
        thinkingFrame = 0
        thinkingWord = SloppyTUITheme.waitingWord(seed: session.id + String(Date().timeIntervalSince1970))
        thinkingAnimationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 220_000_000)
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    guard let self, self.liveAssistantDraft != nil else { return }
                    self.thinkingFrame += 1
                    self.renderTimeline()
                }
            }
        }
    }

    private func stopThinkingAnimation() {
        thinkingAnimationTask?.cancel()
        thinkingAnimationTask = nil
        thinkingFrame = 0
        thinkingWord = "thinking"
    }

    private func appendLocalCard(_ text: String, autoDismissAfter seconds: TimeInterval? = nil) {
        nextLocalCardID += 1
        let id = nextLocalCardID
        localCards.append(SloppyTUILocalCard(id: id, block: .local(text)))
        if localCards.count > 24 {
            let removed = localCards.prefix(localCards.count - 24)
            for card in removed {
                localCardDismissTasks.removeValue(forKey: card.id)?.cancel()
            }
            localCards.removeFirst(localCards.count - 24)
        }
        let dismissAfter = seconds ?? inferredLocalCardDismissDelay(for: text)
        if let dismissAfter {
            scheduleLocalCardDismissal(id: id, after: dismissAfter)
        }
        renderTimeline()
    }

    private func dismissFirstStartBootstrapCard() {
        dismissLocalCards { block in
            if case .local(let text) = block.block {
                return text == Self.firstStartBootstrapCard
            }
            return false
        }
    }

    private func dismissModelSwitchCards() {
        dismissLocalCards { block in
            if case .local(let text) = block.block {
                return text.hasPrefix("Model switched to ")
            }
            return false
        }
    }

    private func clearLocalCards() {
        cancelLocalCardDismissTasks()
        localCards.removeAll()
    }

    private func dismissLocalCardsForUserMessage() {
        transientNoticeTask?.cancel()
        transientNoticeTask = nil
        transientNoticeLine = nil
        clearLocalCards()
    }

    private func dismissLocalCards(where shouldDismiss: (SloppyTUILocalCard) -> Bool) {
        let removedIDs = localCards.filter(shouldDismiss).map(\.id)
        guard !removedIDs.isEmpty else { return }
        for id in removedIDs {
            localCardDismissTasks.removeValue(forKey: id)?.cancel()
        }
        localCards.removeAll(where: shouldDismiss)
    }

    private func scheduleLocalCardDismissal(id: Int, after seconds: TimeInterval) {
        localCardDismissTasks[id]?.cancel()
        localCardDismissTasks[id] = Task { [weak self] in
            let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.localCardDismissTasks[id] = nil
                self.localCards.removeAll { $0.id == id }
                self.renderTimeline()
            }
        }
    }

    private func cancelLocalCardDismissTasks() {
        for task in localCardDismissTasks.values {
            task.cancel()
        }
        localCardDismissTasks.removeAll()
    }

    private func inferredLocalCardDismissDelay(for text: String) -> TimeInterval? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return SloppyTUILocalCardBehavior.autoDismissSeconds }
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count <= SloppyTUILocalCardBehavior.autoDismissLineLimit,
              trimmed.count <= SloppyTUILocalCardBehavior.autoDismissCharacterLimit,
              !trimmed.hasPrefix("## ")
        else {
            return nil
        }
        return SloppyTUILocalCardBehavior.autoDismissSeconds
    }

    private func showSystemNotice(_ text: String, autoDismissAfter seconds: TimeInterval = 6) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        transientNoticeLine = value
        transientNoticeTask?.cancel()
        transientNoticeTask = Task { [weak self] in
            let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.transientNoticeLine == value else { return }
                self.transientNoticeLine = nil
                self.transientNoticeTask = nil
                self.refreshStaticChrome()
            }
        }
        refreshStaticChrome()
    }

    private func refreshStaticChrome(statusLine: String? = nil) {
        header.text = SloppyTUITheme.header(
            project: project.name,
            agent: agent.displayName,
            session: SloppyTUITheme.sessionHeaderTitle(session)
        )
        let context = pendingContext == nil ? "" : "  context: queued"
        let attachments = pendingUploads.isEmpty ? "" : "  attachments: \(pendingUploads.count)"
        let queue = queuedMessages.isEmpty ? "" : "  queue: \(queuedMessages.count) ctrl+b cancel"
        let pet = state.petEnabled ? "  pet: \(terminalPetFace())" : ""
        let transcript = transcriptExpanded ? "  transcript: full" : ""
        let parent = session.parentSessionId == nil ? "" : "  parent: ctrl+p"
        let elapsed = elapsedStatusContext()
        let defaultStatus = SloppyTUITheme.sessionStatusLine(
            context: context + queue + pet + transcript + parent + elapsed.idleSuffix,
            attachments: attachments,
            sessionID: hasPersistedSession ? session.id : "not created"
        )
        let busyStatus = (statusLine ?? liveRunStatusLine).map { $0 + elapsed.busySuffix }
        let noticeStatus = transientNoticeLine.map { "notice: \($0)" + elapsed.idleSuffix }
        status.text = SloppyTUITheme.status(
            busyStatus ?? noticeStatus ?? defaultStatus,
            isBusy: busyStatus != nil
        )
        requestRender()
    }

    private func elapsedStatusContext() -> (busySuffix: String, idleSuffix: String) {
        if let taskStartedAt {
            let elapsed = SloppyTUITheme.elapsed(Date().timeIntervalSince(taskStartedAt))
            return ("  elapsed: \(elapsed)", "  elapsed: \(elapsed)")
        }
        if let lastTaskElapsed {
            return ("", "  last run: \(SloppyTUITheme.elapsed(lastTaskElapsed))")
        }
        return ("", "")
    }

    private func runStatusLine(_ status: AgentRunStatusEvent) -> String {
        let label = status.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let details = status.details?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !label.isEmpty, !details.isEmpty {
            return "\(label) - \(details)"
        }
        if !label.isEmpty {
            return label
        }
        return status.stage.rawValue
    }

    private func notifyForRunStatus(_ status: AgentRunStatusEvent) {
        switch status.stage {
        case .done:
            let body = sessionDisplayNotificationBody(fallback: status.details)
            let metadata = [
                "source": "tui",
                "agentId": agent.id,
                "sessionId": session.id
            ]
            Task {
                await desktopNotificationService.notify(
                    category: "session_done",
                    title: "Sloppy finished",
                    body: body,
                    metadata: metadata
                )
            }
        case .paused:
            let label = status.label.trimmingCharacters(in: .whitespacesAndNewlines)
            if label.caseInsensitiveCompare("Waiting for input") == .orderedSame {
                return
            }
            let isToolApproval = label.localizedCaseInsensitiveContains("approval")
            let body = sessionDisplayNotificationBody(fallback: status.details)
            let metadata = [
                "source": "tui",
                "agentId": agent.id,
                "sessionId": session.id
            ]
            Task {
                await desktopNotificationService.notify(
                    category: isToolApproval ? "tool_approval" : "input_required",
                    title: isToolApproval ? "Tool approval required" : "Input required",
                    body: body,
                    metadata: metadata
                )
            }
        case .thinking, .searching, .responding, .interrupted:
            break
        }
    }

    private func notifyForInputRequest(_ inputRequest: PlanInputRequest) {
        let body = sessionDisplayNotificationBody(fallback: inputRequest.title)
        let metadata = [
            "source": "tui",
            "agentId": agent.id,
            "sessionId": session.id,
            "requestId": inputRequest.id
        ]
        Task {
            await desktopNotificationService.notify(
                category: "input_required",
                title: "Input required",
                body: body,
                metadata: metadata
            )
        }
    }

    private func sessionDisplayNotificationBody(fallback: String?) -> String {
        let fallbackText = fallback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !fallbackText.isEmpty {
            return fallbackText
        }
        let title = SloppyTUITheme.sessionDisplayTitle(session).trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            return title
        }
        return agent.displayName
    }

    private func terminalPetFace() -> String {
        guard let faceSet = agent.pet?.visual?.terminalFaceSet else {
            return "(o_o)"
        }
        switch petMood {
        case .happy, .interacted:
            return faceSet.happy
        case .sad:
            return faceSet.sad
        case .sleep:
            return faceSet.sleep
        default:
            return faceSet.idle
        }
    }

    private func refreshSelectedModel() async {
        let config = try? await runtime.service.getAgentConfig(agentID: agent.id)
        selectedModel = config?.selectedModel ?? "default"
        selectedModelContextWindowTokens = config.map {
            contextWindowTokens(for: selectedModel, in: $0.availableModels)
        } ?? 0
        await refreshTokenUsage(includeCost: true)
        refreshStaticChrome()
    }

    private func requestRender() {
        tui?.requestRender()
    }

    private var shouldRenderWelcome: Bool {
        SloppyTUIWelcomeVisibility.shouldRender(
            welcomeDismissed: welcomeDismissed,
            hasPersistedSession: hasPersistedSession,
            hasSessionCards: !sessionCards.isEmpty,
            hasLiveAssistantDraft: liveAssistantDraft != nil,
            hasQueuedMessages: !queuedMessages.isEmpty,
            hasLocalCards: !localCards.isEmpty,
            hasTransientNotice: transientNoticeLine != nil
        )
    }

    private func stopTUI(reason: String) async {
        guard !isExiting else {
            return
        }
        isExiting = true
        await interruptCurrentRunForExit(reason: reason)
        onExit?()
    }

    private func interruptCurrentRunForExit(reason: String) async {
        guard hasPersistedSession else {
            return
        }
        guard isPosting || liveRunStatusLine != nil || pendingPlanInputRequest != nil else {
            return
        }

        isInterruptingRun = true
        refreshStaticChrome(statusLine: "Interrupting active agent run before exit.")
        do {
            _ = try await runtime.service.controlAgentSession(
                agentID: agent.id,
                sessionID: session.id,
                request: AgentSessionControlRequest(action: .interruptTree, requestedBy: "tui", reason: reason)
            )
        } catch {
            // Exit should not be blocked by a failed cooperative interrupt request.
        }
    }

    private func persistSelection() {
        let key = SloppyTUIStateStore.selectionKey(projectId: project.id)
        state.selections[key] = .init(agentId: agent.id, sessionId: hasPersistedSession ? session.id : nil)
        stateStore.save(state)
    }

    private func currentSessionDirectoryKey() -> String {
        SloppyTUIStateStore.sessionDirectoryKey(
            projectId: project.id,
            agentId: agent.id,
            sessionId: session.id
        )
    }

    private func persistedDirectoriesForCurrentSession() -> [String] {
        state.sessionDirectories[currentSessionDirectoryKey()] ?? []
    }

    private func persistSessionDirectories(_ directories: [String]) {
        let normalized = normalizedDirectoryList(directories)
        let key = currentSessionDirectoryKey()
        if normalized.isEmpty {
            state.sessionDirectories.removeValue(forKey: key)
        } else {
            state.sessionDirectories[key] = normalized
        }
        restoredDirectorySessionKeys.insert(key)
        stateStore.save(state)
    }

    private func restorePersistedDirectoriesForCurrentSession() async {
        guard hasPersistedSession else {
            return
        }
        let key = currentSessionDirectoryKey()
        guard restoredDirectorySessionKeys.insert(key).inserted else {
            return
        }

        var restored: [String] = []
        for directory in persistedDirectoriesForCurrentSession() {
            do {
                let response = try await runtime.service.addAgentSessionDirectory(
                    agentID: agent.id,
                    sessionID: session.id,
                    request: AgentSessionDirectoryRequest(path: directory)
                )
                restored = response.directories
            } catch {
                continue
            }
        }
        if !restored.isEmpty {
            state.sessionDirectories[key] = normalizedDirectoryList(restored)
            stateStore.save(state)
        }
    }

    private func applyDraftDirectories(_ directories: [String], previousKey: String) async {
        var restored: [String] = []
        for directory in directories {
            do {
                let response = try await runtime.service.addAgentSessionDirectory(
                    agentID: agent.id,
                    sessionID: session.id,
                    request: AgentSessionDirectoryRequest(path: directory)
                )
                restored = response.directories
            } catch {
                continue
            }
        }

        state.sessionDirectories.removeValue(forKey: previousKey)
        if !restored.isEmpty {
            state.sessionDirectories[currentSessionDirectoryKey()] = normalizedDirectoryList(restored)
            restoredDirectorySessionKeys.insert(currentSessionDirectoryKey())
        }
        stateStore.save(state)
    }

    private func normalizedDirectoryList(_ directories: [String]) -> [String] {
        var seen = Set<String>()
        return directories.compactMap { directory in
            let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return nil
            }
            let normalized = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true)
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path
            guard seen.insert(normalized).inserted else {
                return nil
            }
            return normalized
        }
    }

    private func appendingUniqueDirectory(_ directory: String, to directories: [String]) -> [String] {
        normalizedDirectoryList(directories + [directory])
    }

    private func resolveDraftSessionDirectoryPath(_ rawPath: String) async throws -> String {
        var trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) ||
            (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            trimmed = String(trimmed.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !trimmed.isEmpty else {
            throw CocoaError(.fileNoSuchFile)
        }

        let expanded = (trimmed as NSString).expandingTildeInPath
        let candidate: URL
        if expanded.hasPrefix("/") {
            candidate = URL(fileURLWithPath: expanded, isDirectory: true)
        } else {
            let root = (try? await runtime.service.resolveProjectWorkspaceRoot(projectID: project.id))
                ?? URL(fileURLWithPath: runtime.cwd, isDirectory: true)
            candidate = root.appendingPathComponent(expanded, isDirectory: true)
        }

        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw CocoaError(.fileNoSuchFile)
        }
        return resolved.path
    }

    private func persistDraft(_ value: String) {
        let key = SloppyTUIStateStore.draftKey(projectId: project.id, agentId: agent.id, sessionId: session.id)
        if value.isEmpty {
            state.drafts.removeValue(forKey: key)
        } else {
            state.drafts[key] = value
        }
        stateStore.save(state)
    }

    private func attachmentURLs(fromPastedText text: String) -> [URL] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let candidates = splitPastedPathCandidates(trimmed)
        guard !candidates.isEmpty else { return [] }

        var urls: [URL] = []
        for candidate in candidates {
            if let url = fileURL(fromPastedPathCandidate: candidate),
               FileManager.default.fileExists(atPath: url.path) {
                urls.append(url)
            } else {
                return []
            }
        }
        return urls
    }

    private func splitPastedPathCandidates(_ text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if lines.count > 1 {
            return lines.map(Self.unquotePathCandidate)
        }

        let single = Self.unquotePathCandidate(normalized.trimmingCharacters(in: .whitespacesAndNewlines))
        if FileManager.default.fileExists(atPath: (single as NSString).expandingTildeInPath)
            || single.hasPrefix("file://") {
            return [single]
        }

        return splitEscapedShellPaths(single)
    }

    private func splitEscapedShellPaths(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var isEscaped = false
        var quote: Character?

        for character in text {
            if isEscaped {
                current.append(character)
                isEscaped = false
                continue
            }
            if character == "\\" {
                isEscaped = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                continue
            }
            if character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current.removeAll()
                }
            } else {
                current.append(character)
            }
        }
        if isEscaped {
            current.append("\\")
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private func fileURL(fromPastedPathCandidate candidate: String) -> URL? {
        if candidate.hasPrefix("file://") {
            return URL(string: candidate.removingPercentEncoding ?? candidate)
        }
        let raw = candidate.removingPercentEncoding ?? candidate
        let expanded = (raw as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        return URL(fileURLWithPath: runtime.cwd)
            .appendingPathComponent(expanded)
            .standardizedFileURL
    }

    private static func unquotePathCandidate(_ value: String) -> String {
        var result = value
        if result.count >= 2,
           let first = result.first,
           let last = result.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            result.removeFirst()
            result.removeLast()
        }
        return result.replacingOccurrences(of: "\\ ", with: " ")
    }

    private func addPendingAttachmentFiles(_ urls: [URL]) {
        var added: [String] = []
        var skipped: [String] = []
        for url in urls {
            do {
                let upload = try makeAttachmentUpload(from: url)
                pendingUploads.append(upload)
                added.append(upload.name)
            } catch {
                skipped.append("\(url.lastPathComponent): \(String(describing: error))")
            }
        }
        if !added.isEmpty {
            showSystemNotice("Attached \(added.count) file(s): \(added.joined(separator: ", "))")
        }
        if !skipped.isEmpty {
            showSystemNotice("Attachment skipped: " + skipped.joined(separator: "; "))
        }
        refreshStaticChrome()
    }

    private func makeAttachmentUpload(from url: URL) throws -> AgentAttachmentUpload {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw SloppyTUIAttachmentError.notAFile
        }

        let data = try Data(contentsOf: url)
        guard data.count <= SloppyTUIAttachmentLimits.maxBytes else {
            throw SloppyTUIAttachmentError.tooLarge(data.count)
        }
        return AgentAttachmentUpload(
            name: url.lastPathComponent.isEmpty ? "attachment.bin" : url.lastPathComponent,
            mimeType: mimeType(for: url),
            sizeBytes: data.count,
            contentBase64: data.base64EncodedString()
        )
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "tif", "tiff": return "image/tiff"
        case "pdf": return "application/pdf"
        case "json": return "application/json"
        case "md", "markdown": return "text/markdown"
        case "txt", "log": return "text/plain"
        case "csv": return "text/csv"
        case "html", "htm": return "text/html"
        case "swift": return "text/x-swift"
        default: return "application/octet-stream"
        }
    }

    private func pasteAttachmentFromClipboard() {
        #if canImport(AppKit)
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           !urls.isEmpty {
            addPendingAttachmentFiles(urls)
            return
        }

        if let text = pasteboard.string(forType: .string) {
            let urls = attachmentURLs(fromPastedText: text)
            if !urls.isEmpty {
                addPendingAttachmentFiles(urls)
                return
            }
        }

        if let pngData = pasteboard.data(forType: NSPasteboard.PasteboardType("public.png")) {
            addPendingClipboardImage(data: pngData, mimeType: "image/png", extension: "png")
            return
        }
        if let tiffData = pasteboard.data(forType: .tiff),
           let image = NSImage(data: tiffData),
           let pngData = image.pngData() {
            addPendingClipboardImage(data: pngData, mimeType: "image/png", extension: "png")
            return
        }
        showSystemNotice("Clipboard does not contain a file, image, or file path.")
        #else
        showSystemNotice("Clipboard image paste is only available on macOS.")
        #endif
    }

    private func addPendingClipboardImage(data: Data, mimeType: String, extension pathExtension: String) {
        guard data.count <= SloppyTUIAttachmentLimits.maxBytes else {
            showSystemNotice("Clipboard image is too large (\(data.count) bytes).")
            return
        }
        let name = "clipboard-\(Self.clipboardTimestamp()).\(pathExtension)"
        pendingUploads.append(
            AgentAttachmentUpload(
                name: name,
                mimeType: mimeType,
                sizeBytes: data.count,
                contentBase64: data.base64EncodedString()
            )
        )
        showSystemNotice("Attached clipboard image: \(name)")
        refreshStaticChrome()
    }

    private static func clipboardTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private func messageContentWithInlineAttachments(
        _ raw: String,
        context: String?,
        uploads: [AgentAttachmentUpload]
    ) async -> String {
        var parts = [raw]
        if let pendingContext = context {
            parts.append("\n[Attached context]\n\(pendingContext)")
        }
        if !uploads.isEmpty {
            let list = uploads.map { "- \($0.name) (\($0.mimeType), \($0.sizeBytes) bytes)" }.joined(separator: "\n")
            parts.append("\n[Attached files]\n\(list)")
        }

        let paths = SloppyTUIProjectPathTokens.attachmentPaths(in: raw)
        for path in paths.prefix(8) {
            parts.append("\n\(await projectPathContext(for: path))")
        }
        return parts.joined(separator: "\n")
    }

    private func projectPathContext(for rawPath: String) async -> String {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("/") {
            return absolutePathContext(for: path)
        }
        let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let cachedType = projectFileIndex?.entries.first { $0.path == normalizedPath }?.type
        let shouldTryDirectoryFirst = path.hasSuffix("/") || cachedType == .directory

        if shouldTryDirectoryFirst, let manifest = await directoryContextBlock(path: path) {
            return manifest
        }

        do {
            let file = try await runtime.service.readProjectFile(projectID: project.id, path: path)
            return "[Attached file: \(file.path)]\n```\n\(file.content)\n```"
        } catch {
            if !shouldTryDirectoryFirst, let manifest = await directoryContextBlock(path: path) {
                return manifest
            }
            scheduleProjectFileReindex()
            return "[Attachment failed: \(path)] Cached path is stale or unavailable: \(String(describing: error))"
        }
    }

    private func directoryContextBlock(path: String) async -> String? {
        if path.hasPrefix("/") {
            return absoluteDirectoryContextBlock(path: path)
        }
        let manifestLimit = 80
        do {
            let rootURL: URL
            if let projectFileRootURL {
                rootURL = projectFileRootURL
            } else {
                rootURL = try await runtime.service.resolveProjectWorkspaceRoot(projectID: project.id)
                projectFileRootURL = rootURL
            }

            let projectID = project.id
            let entries = try await Task.detached(priority: .utility) {
                try ProjectFileIndex.directoryManifest(
                    projectId: projectID,
                    rootURL: rootURL,
                    path: path,
                    limit: manifestLimit
                )
            }.value
            let normalized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let lines = entries.map { entry in
                let suffix = entry.type == .directory ? "/" : ""
                return "- \(entry.path)\(suffix)"
            }.joined(separator: "\n")
            let body = lines.isEmpty ? "- (empty directory)" : lines
            return """
            [Attached directory: \(normalized)/]
            \(body)
            """
        } catch {
            return nil
        }
    }

    private func absolutePathContext(for rawPath: String) -> String {
        guard let url = allowedAbsoluteAttachmentURL(rawPath) else {
            return "[Attachment failed: \(rawPath)] Path is outside directories added with `/add_dir`."
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return "[Attachment failed: \(rawPath)] Path does not exist."
        }
        if isDirectory.boolValue {
            return absoluteDirectoryContextBlock(path: url.path) ?? "[Attached directory: \(url.path)/]\n- (empty directory)"
        }

        do {
            let maxBytes = 2 * 1024 * 1024
            let data = try Data(contentsOf: url)
            guard data.count <= maxBytes else {
                return "[Attachment failed: \(url.path)] File is too large."
            }
            guard let text = String(data: data, encoding: .utf8) else {
                return "[Attachment failed: \(url.path)] Only UTF-8 files are supported."
            }
            return "[Attached file: \(url.path)]\n```\n\(text)\n```"
        } catch {
            return "[Attachment failed: \(url.path)] \(String(describing: error))"
        }
    }

    private func absoluteDirectoryContextBlock(path: String) -> String? {
        guard let url = allowedAbsoluteAttachmentURL(path) else {
            return nil
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return nil
        }

        let entries = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let lines = entries
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(80)
            .map { entry -> String in
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
                return "- \(entry.path)\((values?.isDirectory == true) ? "/" : "")"
            }
            .joined(separator: "\n")
        return """
        [Attached directory: \(url.path)/]
        \(lines.isEmpty ? "- (empty directory)" : lines)
        """
    }

    private func allowedAbsoluteAttachmentURL(_ rawPath: String) -> URL? {
        let candidate = URL(fileURLWithPath: rawPath, isDirectory: false)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        for directory in persistedDirectoriesForCurrentSession() {
            let root = URL(fileURLWithPath: directory, isDirectory: true)
                .resolvingSymlinksInPath()
                .standardizedFileURL
            let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
            if candidate.path == root.path || candidate.path.hasPrefix(rootPrefix) {
                return candidate
            }
        }
        return nil
    }
}

#if canImport(AppKit)
private extension NSImage {
    func pngData() -> Data? {
        guard let tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffRepresentation) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}
#endif
