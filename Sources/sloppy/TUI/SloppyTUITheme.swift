import Foundation
import Protocols
import TauTUI

enum SloppyTUITheme {
    private static let resetBackground = "\u{001B}[49m"
    nonisolated(unsafe) private static var accentStyle: (String) -> String = AnsiStyling.rgb(82, 211, 194)
    nonisolated(unsafe) private static var accentBrightStyle: (String) -> String = AnsiStyling.rgb(103, 232, 249)
    private static let blue = AnsiStyling.rgb(96, 165, 250)
    private static let green = AnsiStyling.rgb(74, 222, 128)
    private static let yellow = AnsiStyling.rgb(250, 204, 21)
    private static let orange = AnsiStyling.rgb(251, 178, 123)
    private static let red = AnsiStyling.rgb(248, 113, 113)
    private static let muted = AnsiStyling.rgb(148, 163, 184)
    private static let foreground = AnsiStyling.rgb(226, 232, 240)
    private static let black = AnsiStyling.color(30)
    private static let panelBackground = AnsiStyling.Background.rgb(24, 24, 24)
    private static let userMessageBackground = AnsiStyling.Background.rgb(55, 55, 55)
    private static let toolBackground = AnsiStyling.Background.rgb(31, 41, 55)
    private static let thinkingBackground = AnsiStyling.Background.rgb(38, 38, 38)
    private static let attachmentBackground = AnsiStyling.Background.rgb(32, 45, 42)
    private static let blockHorizontalPadding = 2
    private static let blockVerticalPadding = 1
    private static let waitingFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    private static let thinkingWords = [
        "thinking",
        "processing",
        "looting",
        "brewing",
        "plotting",
        "untangling",
        "debugging",
        "polishing",
        "compiling",
        "noodling",
        "mulling",
        "pondering",
        "scheming",
        "conspiring",
        "ruminating",
        "calculating",
        "crunching",
        "simmering",
        "marinating",
        "stirring",
        "kneading",
        "seasoning",
        "toasting",
        "sizzling",
        "whisking",
        "fermenting",
        "distilling",
        "percolating",
        "decoding",
        "recursing",
        "refactoring",
        "spelunking",
        "triangulating",
        "calibrating",
        "aligning",
        "wrestling",
        "wrangling",
        "juggling",
        "balancing",
        "stacking",
        "unsticking",
        "unclumping",
        "deconfusing",
        "recombobulating",
        "decrinkling",
        "unspooling",
        "rewiring",
        "crosschecking",
        "sanitychecking",
        "overthinking",
        "underthinking",
        "sidequesting",
        "backtracking",
        "whiteboarding",
        "fingerpainting",
        "napkinmathing",
        "bikeshedding",
        "breadcrumbing",
        "threadpulling",
        "mapmaking",
        "sparkfinding",
        "buttonpushing",
        "leverpulling",
        "tinkering",
        "massaging",
        "tickling",
        "nudging",
        "squinting",
        "scrying",
        "divining",
        "unhexing",
        "dejinxing",
        "vibing",
        "vibechecking",
        "brainstorming",
        "mindmapping",
        "wordsmithing",
        "contextpacking",
        "answerbaking",
    ]

    static func setBarColor(_ raw: String) -> Bool {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "default":
            accentStyle = AnsiStyling.rgb(82, 211, 194)
            accentBrightStyle = AnsiStyling.rgb(103, 232, 249)
        case "red":
            accentStyle = red
            accentBrightStyle = AnsiStyling.rgb(252, 165, 165)
        case "blue":
            accentStyle = blue
            accentBrightStyle = AnsiStyling.rgb(147, 197, 253)
        case "green":
            accentStyle = green
            accentBrightStyle = AnsiStyling.rgb(134, 239, 172)
        case "yellow":
            accentStyle = yellow
            accentBrightStyle = AnsiStyling.rgb(254, 240, 138)
        case "purple":
            accentStyle = AnsiStyling.rgb(192, 132, 252)
            accentBrightStyle = AnsiStyling.rgb(216, 180, 254)
        case "orange":
            accentStyle = orange
            accentBrightStyle = AnsiStyling.rgb(253, 186, 116)
        case "pink":
            accentStyle = AnsiStyling.rgb(244, 114, 182)
            accentBrightStyle = AnsiStyling.rgb(249, 168, 212)
        case "cyan":
            accentStyle = AnsiStyling.rgb(34, 211, 238)
            accentBrightStyle = AnsiStyling.rgb(103, 232, 249)
        default:
            return false
        }
        return true
    }

    private static func accent(_ text: String) -> String {
        accentStyle(text)
    }

    private static func accentBright(_ text: String) -> String {
        accentBrightStyle(text)
    }

    static let selectListTheme = SelectListTheme(
        selectedPrefix: { accentBright($0) },
        selectedText: { accentBright(AnsiStyling.bold($0)) },
        description: { muted($0) },
        scrollInfo: { muted($0) },
        noMatch: { muted($0) }
    )

    static let palette = ThemePalette(
        editor: EditorTheme(
            borderColor: { accent($0) },
            selectList: selectListTheme
        ),
        selectList: selectListTheme,
        markdown: MarkdownComponent.MarkdownTheme(
            heading: { accentBright($0) },
            link: { blue(AnsiStyling.underline($0)) },
            linkUrl: { muted($0) },
            code: { yellow($0) },
            codeBlock: { green($0) },
            codeBlockBorder: { muted($0) },
            quote: { muted(AnsiStyling.italic($0)) },
            quoteBorder: { accent($0) },
            hr: { muted($0) },
            listBullet: { accent($0) },
            bold: AnsiStyling.bold,
            italic: AnsiStyling.italic,
            strikethrough: AnsiStyling.strikethrough,
            underline: AnsiStyling.underline
        ),
        textBackground: .init(red: 12, green: 16, blue: 22),
        loader: Loader.LoaderTheme(
            spinner: { accentBright($0) },
            message: { muted($0) }
        ),
        truncatedBackground: .rgb(12, 16, 22)
    )

    static func header(project: String, agent: String, session: String) -> String {
        let title = accentBright(AnsiStyling.bold("Sloppy TUI"))
        return "\(title)  \(muted("project:")) \(foreground(project))  \(muted("agent:")) \(foreground(agent))  \(muted("session:")) \(foreground(session))"
    }

    static func status(_ text: String, isBusy: Bool) -> String {
        if isBusy {
            return yellow(text)
        }
        if text.contains("\u{001B}[") {
            return text
        }
        return muted(text)
    }

    static func sessionStatusLine(context: String, attachments: String, sessionID: String) -> String {
        let details = (context + attachments).trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = details.isEmpty ? "" : "\(details)  "
        return muted("\(suffix)last: \(shortID(sessionID))")
    }

    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private static func formatTokenCountShort(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
        return "\(count)"
    }

    private static func formatUSD(_ value: Double) -> String {
        let amount = max(0, value)
        if amount > 0, amount < 0.01 {
            return String(format: "$%.4f", amount)
        }
        return String(format: "$%.2f", amount)
    }

    static func welcomeScreen(
        width: Int,
        cwd: String,
        project: String,
        agent: String,
        model: String,
        mode: AgentChatMode,
        tipOffset: Int = 0,
        includeFooter: Bool = true
    ) -> [String] {
        let contentWidth = welcomeContentWidth(for: width)
        let left = max(0, (width - contentWidth) / 2)
        let indent = String(repeating: " ", count: left)
        var lines: [String] = []

        lines.append("")
        lines.append("")
        lines.append(contentsOf: logoLines(width: width))
        lines.append("")
        lines.append(indent + welcomePromptLine(width: contentWidth))
        lines.append(indent + welcomeMetaLine(width: contentWidth, project: project, agent: agent, model: model, mode: mode))
        lines.append(indent + welcomeShortcutsLine(width: contentWidth))
        lines.append("")
        lines.append(contentsOf: welcomeTipLines(width: width, contentWidth: contentWidth, offset: tipOffset))
        lines.append("")
        if includeFooter {
            lines.append(welcomeFooter(width: width, cwd: cwd))
        }
        lines.append("")
        return lines
    }

    private static func welcomeContentWidth(for width: Int) -> Int {
        max(1, min(max(1, width - 4), 64))
    }

    static func composerMetaLine(width: Int, mode: AgentChatMode, model: String, agent: String, provider: String) -> String {
        let modelText = truncateEnd(compactModel(model), maxWidth: max(4, width / 3))
        let agentText = truncateEnd(agent, maxWidth: max(4, width / 5))
        let providerText = truncateEnd(provider, maxWidth: max(4, width / 5))
        let text = "  " + modeTitle(mode) + muted(" · ") + foreground(modelText) + muted("  ") + muted(agentText) + muted("  ") + muted(providerText)
        return applyPanelBackground(padded(text, width: width), width: width)
    }

    static func interruptControlLine(width: Int, frame: Int, isInterrupting: Bool) -> String {
        let bars = interruptBars(frame: frame)
        let action = isInterrupting ? "interrupting" : "interrupt"
        let text = "  " + orange(bars) + muted("  ") + foreground("esc") + muted(" \(action)")
        return applyPanelBackground(padded(fittedLine(text, width: width), width: width), width: width)
    }

    static func tokenUsageStatus(_ summary: SloppyTUITokenUsageSummary) -> String {
        var text = formatTokenCountShort(summary.totalTokens)
        if let percent = summary.usagePercent {
            text += " (\(percent)%)"
        }
        if let costUSD = summary.costUSD {
            text += " · \(formatUSD(costUSD))"
        }
        return muted("tokens: ") + foreground(text)
    }

    static func tokenUsageFooterLine(width: Int, summary: SloppyTUITokenUsageSummary) -> String {
        let text = "  " + tokenUsageStatus(summary)
        return applyPanelBackground(padded(fittedLine(text, width: width), width: width), width: width)
    }

    static func highlightedComposerLines(_ lines: [String]) -> [String] {
        var borderCount = 0
        var isContinuingProjectPath = false
        return lines.map { line in
            if isEditorBorderLine(line) {
                borderCount += 1
                isContinuingProjectPath = false
                return line
            }
            guard borderCount == 1 else {
                return line
            }
            let highlighted = highlightedComposerSyntax(
                in: line,
                isContinuingProjectPath: isContinuingProjectPath
            )
            isContinuingProjectPath = highlighted.isContinuingProjectPath
            return highlighted.line
        }
    }

    private static func modeTitle(_ mode: AgentChatMode) -> String {
        switch mode {
        case .ask:
            return green(mode.title)
        case .build:
            return blue(mode.title)
        case .plan:
            return accentBright(mode.title)
        case .debug:
            return yellow(mode.title)
        }
    }

    static func compactPickerDescription(_ model: String) -> String {
        compactModel(model)
    }

    static func modelPickerDescription(_ model: ProviderModelOption) -> String {
        var parts: [String] = []
        let title = model.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty, title != model.id {
            parts.append(title)
        }
        if let contextWindow = model.contextWindow?.trimmingCharacters(in: .whitespacesAndNewlines),
           !contextWindow.isEmpty {
            parts.append(contextWindow)
        }
        if !model.capabilities.isEmpty {
            parts.append(model.capabilities.joined(separator: ", "))
        }
        if parts.isEmpty {
            return compactModel(model.id)
        }
        return parts.joined(separator: " · ")
    }

    static func sessionDisplayTitle(_ session: AgentSessionSummary) -> String {
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = sessionPreviewText(session)
        let lowercasedTitle = title.lowercased()
        let isDefaultTitle = lowercasedTitle.hasPrefix("session session-")
        let isLegacyTUITitle = lowercasedTitle == "tui chat"
        if (isDefaultTitle || isLegacyTUITitle), !preview.isEmpty {
            return truncateEnd(preview, maxWidth: 80)
        }
        if !title.isEmpty {
            return title
        }
        if !preview.isEmpty {
            return truncateEnd(preview, maxWidth: 80)
        }
        return "Session"
    }

    static func sessionHeaderTitle(_ session: AgentSessionSummary) -> String {
        "\(sessionDisplayTitle(session)) (\(shortID(session.id)))"
    }

    static func sessionPickerDescription(_ session: AgentSessionSummary) -> String {
        let preview = sessionPreviewText(session)
        let detail = preview.isEmpty ? "\(session.messageCount) messages" : preview
        return "\(relativeTime(session.updatedAt)) · \(shortID(session.id)) · \(detail)"
    }

    private static func sessionPreviewText(_ session: AgentSessionSummary) -> String {
        let preview = session.lastMessagePreview?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ") ?? ""
        return preview.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    static func waitingIndicator(frame: Int, word: String) -> String {
        let spinner = waitingFrames[frame % waitingFrames.count]
        return muted("\(spinner) ") + accentBright(word)
    }

    static func waitingWord(seed: String) -> String {
        let value = seed.unicodeScalars.reduce(0) { partial, scalar in
            partial &+ Int(scalar.value)
        }
        return thinkingWords[value % thinkingWords.count]
    }

    static func userMessageLines(_ text: String, width: Int) -> [String] {
        let prefixWidth = VisibleWidth.measure("› ")
        let contentWidth = paddedBlockContentWidth(width: width, prefixWidth: prefixWidth)
        let rawLines = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .flatMap { line in
                AnsiWrapping.wrapText(String(line), width: contentWidth)
            }

        let lines = rawLines.isEmpty ? [""] : rawLines
        let contentLines = lines.enumerated().map { index, line in
            let prefix = index == 0 ? "› " : "  "
            return applyBackground(
                blockLeftPadding + muted(prefix) + highlightedMessageReferences(in: line),
                width: width,
                background: userMessageBackground
            )
        }
        return paddedBackgroundBlock(contentLines, width: width, background: userMessageBackground)
    }

    static func queuedMessageLines(_ message: SloppyTUIQueuedMessage, width: Int) -> [String] {
        let attachmentSuffix = message.uploads.isEmpty ? "" : " · attachments: \(message.uploads.count)"
        let contextSuffix = message.context == nil ? "" : " · context"
        let header = "queued · ctrl+b cancels" + attachmentSuffix + contextSuffix
        let prefixWidth = VisibleWidth.measure("⏳ ")
        let contentWidth = paddedBlockContentWidth(width: width, prefixWidth: prefixWidth)
        let rawLines = message.displayText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .flatMap { line in
                AnsiWrapping.wrapText(String(line), width: contentWidth)
            }
        let bodyLines = rawLines.isEmpty ? [""] : rawLines
        let lines = [header] + bodyLines
        let contentLines = lines.enumerated().map { index, line in
            let prefix = index == 0 ? "⏳ " : "  "
            let styled = index == 0 ? muted(line) : highlightedMessageReferences(in: line)
            return applyBackground(
                blockLeftPadding + muted(prefix) + styled,
                width: width,
                background: userMessageBackground
            )
        }
        return paddedBackgroundBlock(contentLines, width: width, background: userMessageBackground)
    }

    static func thinkingLines(_ text: String, width: Int) -> [String] {
        let prefixWidth = VisibleWidth.measure("thought ")
        let contentWidth = paddedBlockContentWidth(width: width, prefixWidth: prefixWidth)
        let rawLines = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .flatMap { line in
                AnsiWrapping.wrapText(String(line), width: contentWidth)
            }
        let lines = rawLines.isEmpty ? [""] : rawLines
        let contentLines = lines.enumerated().map { index, line in
            let prefix = index == 0 ? "thought " : "        "
            return applyBackground(
                blockLeftPadding + muted(prefix) + foreground(line),
                width: width,
                background: thinkingBackground
            )
        }
        return paddedBackgroundBlock(contentLines, width: width, background: thinkingBackground)
    }

    static func buildProgressLines(_ progress: AgentBuildProgressEvent, width: Int) -> [String] {
        let title = " " + accentBright(AnsiStyling.bold(progress.title.trimmingCharacters(in: .whitespacesAndNewlines)))
        var lines = [fittedLine(title, width: width)]

        for item in progress.items {
            let marker = buildProgressMarker(for: item.status)
            let itemPrefix = "  \(marker.text) "
            let detailPrefix = "      "
            let itemStyle = buildProgressStyle(for: item.status)
            lines.append(contentsOf: wrappedBuildProgressLines(
                item.title,
                firstPrefix: itemPrefix,
                continuationPrefix: detailPrefix,
                width: width,
                style: { itemStyle(AnsiStyling.bold($0)) },
                prefixStyle: marker.style
            ))
            lines.append(contentsOf: wrappedBuildProgressLines(
                "DoD: \(item.definitionOfDone)",
                firstPrefix: detailPrefix,
                continuationPrefix: detailPrefix,
                width: width,
                style: styledBuildProgressDetail
            ))
            if let details = item.details?.trimmingCharacters(in: .whitespacesAndNewlines), !details.isEmpty {
                lines.append(contentsOf: wrappedBuildProgressLines(
                    "Notes: \(details)",
                    firstPrefix: detailPrefix,
                    continuationPrefix: detailPrefix,
                    width: width,
                    style: styledBuildProgressDetail
                ))
            }
        }

        return lines
    }

    static func toolCallLine(tool: String, reason: String?, summary: String?, width: Int) -> String {
        let summaryText = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let args = summaryText?.isEmpty == false ? muted(" · \(summaryText!)") : ""
        let suffix = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        let reasonText = suffix?.isEmpty == false ? muted(" · \(suffix!)") : ""
        let line = fittedPaddedBlockLine(blue("tool") + foreground(" \(tool)") + args + reasonText, width: width)
        return applyBackground(padded(line, width: width), width: width, background: toolBackground)
    }

    static func toolResultLine(tool: String, ok: Bool, error: String?, durationMs: Int?, width: Int) -> String {
        let status = ok ? green("done") : red("failed")
        let duration = durationMs.map { muted(" · \($0)ms") } ?? ""
        let errorText = error?.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = errorText?.isEmpty == false ? muted(" · \(errorText!)") : ""
        let line = fittedPaddedBlockLine(status + foreground(" \(tool)") + duration + suffix, width: width)
        return applyBackground(padded(line, width: width), width: width, background: toolBackground)
    }

    static func toolOverflowLine(hiddenCount: Int, width: Int) -> String {
        let suffix = hiddenCount == 1 ? "1 tool event" : "\(hiddenCount) tool events"
        let line = fittedPaddedBlockLine(muted("... +\(suffix) (ctrl+o to expand)"), width: width)
        return applyBackground(padded(line, width: width), width: width, background: toolBackground)
    }

    static func toolPaddingLine(width: Int) -> String {
        backgroundPaddingLine(width: width, background: toolBackground)
    }

    static func subSessionLine(
        title: String,
        childSessionId: String,
        status: SloppyTUISubSessionStatus,
        frame: Int,
        width: Int
    ) -> String {
        let statusText: String
        switch status {
        case .starting:
            statusText = muted(waitingFrames[frame % waitingFrames.count] + " ") + accentBright("starting")
        case .running(let label):
            let detail = label?.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = detail?.isEmpty == false ? detail ?? "working" : "working"
            statusText = muted(waitingFrames[frame % waitingFrames.count] + " ") + accentBright(text)
        case .waiting(let label):
            let detail = label?.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = detail?.isEmpty == false ? "waiting: \(detail ?? "")" : "waiting"
            statusText = yellow(text)
        case .done:
            statusText = green("done")
        case .interrupted(let label):
            let detail = label?.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = detail?.isEmpty == false ? "stopped: \(detail ?? "")" : "stopped"
            statusText = red(text)
        }
        let line = fittedLine(
            blockLeftPadding
                + green("subagent")
                + foreground(" \(title)")
                + muted(" · ")
                + statusText
                + muted(" · \(shortID(childSessionId)) · ctrl+g to enter"),
            width: paddedBlockLineWidth(width)
        )
        return applyBackground(padded(line, width: width), width: width, background: toolBackground)
    }

    static func transcriptHintLine(expanded: Bool, childSessionCount: Int, width: Int) -> String {
        let mode = expanded ? "detailed transcript" : "compact transcript"
        let childHint = childSessionCount > 0 ? " · ctrl+g enters latest subagent · /subagents picks" : ""
        let line = fittedLine(" " + muted("\(mode) · ctrl+o toggles\(childHint)"), width: width)
        return applyPanelBackground(padded(line, width: width), width: width)
    }

    static func attachmentLine(name: String, mimeType: String, sizeBytes: Int, width: Int) -> String {
        let size = formattedBytes(sizeBytes)
        let line = fittedPaddedBlockLine(green("attached") + foreground(" ") + yellow(name) + muted("  \(mimeType), \(size)"), width: width)
        return applyBackground(padded(line, width: width), width: width, background: attachmentBackground)
    }

    static func diffLines(_ diff: String, width: Int) -> [String] {
        let contentWidth = max(1, width - 2)
        return diff
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { rawLine in
                let line = truncateEnd(String(rawLine), maxWidth: contentWidth)
                return " " + coloredDiffLine(line)
            }
    }

    private static func coloredDiffLine(_ line: String) -> String {
        if line.hasPrefix("diff --git") {
            return accentBright(line)
        }
        if line.hasPrefix("index ") || line.hasPrefix("\\ No newline") {
            return muted(line)
        }
        if line.hasPrefix("@@") {
            return blue(line)
        }
        if line.hasPrefix("+++") || line.hasPrefix("---") {
            return yellow(line)
        }
        if line.hasPrefix("+") {
            return green(line)
        }
        if line.hasPrefix("-") {
            return red(line)
        }
        return foreground(line)
    }

    static func commandPaletteLines(
        width: Int,
        commands: [SloppyTUISlashCommand],
        selectedIndex: Int,
        maxVisible: Int
    ) -> [String] {
        let paletteWidth = max(1, min(max(1, width - 4), 96))
        let left = max(0, (width - paletteWidth) / 2)
        let indent = String(repeating: " ", count: left)
        let visibleCount = max(1, min(maxVisible, commands.count))
        let start = max(0, min(selectedIndex - visibleCount / 2, commands.count - visibleCount))
        let end = min(commands.count, start + visibleCount)
        var lines: [String] = []

        for index in start..<end {
            let command = commands[index]
            let name = "/" + command.name
            let description = command.description ?? ""
            let raw: String
            if paletteWidth < 32 {
                raw = "  " + truncateEnd(name, maxWidth: max(1, paletteWidth - 2))
            } else {
                let nameWidth = max(10, min(22, paletteWidth / 3))
                let descWidth = max(1, paletteWidth - nameWidth - 4)
                raw = "  " + truncateEnd(name, maxWidth: nameWidth).padding(toLength: nameWidth, withPad: " ", startingAt: 0) + "  " + truncateEnd(description, maxWidth: descWidth)
            }
            let line = padded(raw, width: paletteWidth)
            if index == selectedIndex {
                lines.append(indent + selectedLine(line))
            } else {
                lines.append(indent + applyPanelBackground(foreground(line), width: paletteWidth))
            }
        }
        if commands.count > visibleCount {
            let info = "  " + muted("\(selectedIndex + 1)/\(commands.count)")
            lines.append(indent + applyPanelBackground(padded(info, width: paletteWidth), width: paletteWidth))
        }
        return lines
    }

    static func quickReferenceLines(
        width: Int,
        shortcuts: [SloppyTUIShortcutDescriptor] = SloppyTUIShortcutCatalog.all
    ) -> [String] {
        let contentWidth = max(1, min(max(1, width), 120))
        var lines = ["## Quick reference", ""]

        guard !shortcuts.isEmpty else {
            return lines
        }

        let columns: Int
        if contentWidth >= 104 {
            columns = 3
        } else if contentWidth >= 68 {
            columns = 2
        } else {
            columns = 1
        }

        if columns == 1 {
            lines += shortcuts.map { shortcut in
                fittedLine("- `\(shortcut.key)` \(shortcut.description)", width: contentWidth)
            }
            return lines
        }

        let gap = 2
        let columnWidth = max(1, (contentWidth - ((columns - 1) * gap)) / columns)
        let rowCount = Int(ceil(Double(shortcuts.count) / Double(columns)))
        for row in 0..<rowCount {
            var rowText = ""
            for column in 0..<columns {
                let index = row + (column * rowCount)
                guard shortcuts.indices.contains(index) else {
                    continue
                }

                let raw = "`\(shortcuts[index].key)` \(shortcuts[index].description)"
                let cell = fittedLine(raw, width: columnWidth)
                if column > 0 {
                    rowText += String(repeating: " ", count: gap)
                }
                rowText += padded(cell, width: columnWidth)
            }
            lines.append(fittedLine(rowText, width: contentWidth))
        }

        return lines
    }

    static func pickerLines(width: Int, picker: SloppyTUIPicker, maxVisible: Int) -> [String] {
        let paletteWidth = max(1, min(max(1, width - 4), 96))
        let left = max(0, (width - paletteWidth) / 2)
        let indent = String(repeating: " ", count: left)
        let visibleCount = max(1, min(maxVisible, picker.items.count))
        let start = max(0, min(picker.selectedIndex - visibleCount / 2, picker.items.count - visibleCount))
        let end = min(picker.items.count, start + visibleCount)
        let prompt = picker.supportsSearch
            ? "type search · Enter apply · Esc cancel"
            : "Enter apply · Esc cancel"
        var lines = [
            indent + padded("  " + foreground(AnsiStyling.bold(picker.title)) + "  " + muted(prompt), width: paletteWidth),
        ]
        if picker.supportsSearch {
            let query = picker.searchQuery.isEmpty ? muted("type to filter") : foreground(picker.searchQuery)
            let count = muted("\(picker.items.count)/\(picker.totalItemCount)")
            lines.append(indent + padded("  " + muted("Search: ") + query + muted("  matches ") + count, width: paletteWidth))
        }

        let groupCounts = pickerGroupCounts(picker.items)
        var lastGroup: String?
        for index in start..<end {
            let item = picker.items[index]
            if let group = item.group?.trimmingCharacters(in: .whitespacesAndNewlines),
               !group.isEmpty,
               group != lastGroup {
                let suffix = groupCounts[group].map { " (\($0))" } ?? ""
                lines.append(indent + padded("  " + muted(group + suffix), width: paletteWidth))
                lastGroup = group
            }
            let raw: String
            if picker.kind == .projectFile {
                raw = projectFilePickerLine(item: item, width: paletteWidth, styled: index != picker.selectedIndex)
            } else if paletteWidth < 32 {
                let marker = item.isCurrent ? "✓ " : "  "
                raw = "  " + marker + truncateEnd(item.label, maxWidth: max(1, paletteWidth - 4))
            } else {
                let nameWidth = max(14, min(42, paletteWidth / 2))
                let descWidth = max(1, paletteWidth - nameWidth - 6)
                let marker = item.isCurrent ? "✓ " : "  "
                let label = truncateEnd(item.label, maxWidth: nameWidth).padding(toLength: nameWidth, withPad: " ", startingAt: 0)
                raw = "  " + marker + label + "  " + truncateEnd(item.description ?? "", maxWidth: descWidth)
            }
            let line = padded(raw, width: paletteWidth)
            if index == picker.selectedIndex {
                lines.append(indent + selectedLine(line))
            } else {
                lines.append(indent + foreground(line))
            }
        }
        if picker.items.isEmpty, picker.supportsSearch {
            lines.append(indent + padded("  " + muted("No matching models"), width: paletteWidth))
        }
        if picker.items.count > visibleCount {
            let info = "  " + muted("\(picker.selectedIndex + 1)/\(picker.items.count)")
            lines.append(indent + padded(info, width: paletteWidth))
        }
        return lines
    }

    private static func pickerGroupCounts(_ items: [SloppyTUIPickerItem]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for item in items {
            guard let group = item.group?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !group.isEmpty
            else {
                continue
            }
            counts[group, default: 0] += 1
        }
        return counts
    }

    private static func projectFilePickerLine(item: SloppyTUIPickerItem, width: Int, styled: Bool) -> String {
        let isDirectory = item.value.hasSuffix("/")
        let icon = isDirectory ? "▣" : "◇"
        let name = item.label
        let parent = item.description ?? ""
        let prefix = "  \(icon) "
        let gap = parent.isEmpty ? "" : "  "
        let reserved = VisibleWidth.measure(prefix + gap)
        let available = max(1, width - reserved)

        if parent.isEmpty || available < 28 {
            let text = prefix + truncateEnd(name, maxWidth: max(1, width - VisibleWidth.measure(prefix)))
            return styled ? foreground(text) : text
        }

        let minimumNameWidth = min(max(12, width / 4), max(1, available))
        let idealNameWidth = min(max(minimumNameWidth, VisibleWidth.measure(name)), max(1, available / 2))
        let parentWidth = max(1, available - idealNameWidth)
        let renderedName = truncateEnd(name, maxWidth: idealNameWidth)
            .padding(toLength: idealNameWidth, withPad: " ", startingAt: 0)
        let renderedParent = truncateStart(parent, maxWidth: parentWidth)

        if styled {
            return foreground(prefix + renderedName + gap) + muted(renderedParent)
        }
        return prefix + renderedName + gap + renderedParent
    }

    static func overlayModal(
        base: [String],
        width: Int,
        title: String,
        subtitle: String,
        content: [String],
        maxWidth: Int
    ) -> [String] {
        let dimmed = base.map { AnsiStyling.dim($0) }
        let modalWidth = max(1, min(maxWidth, max(1, width - 8)))
        let left = max(0, (width - modalWidth) / 2)
        let top = max(1, (dimmed.count - content.count - 4) / 2)
        let indent = String(repeating: " ", count: left)
        var modal: [String] = []
        let titleText = truncateEnd(title, maxWidth: max(1, modalWidth / 2))
        let subtitleText = modalWidth > 36 ? truncateEnd(subtitle, maxWidth: max(1, modalWidth / 2)) : ""
        let gap = max(1, modalWidth - 4 - VisibleWidth.measure(titleText) - VisibleWidth.measure(subtitleText))
        modal.append(applyPanelBackground(padded("  " + foreground(AnsiStyling.bold(titleText)) + String(repeating: " ", count: gap) + muted(subtitleText) + "  ", width: modalWidth), width: modalWidth))
        modal.append(applyPanelBackground(padded("", width: modalWidth), width: modalWidth))
        for line in content {
            let inner = padded("  " + line, width: modalWidth)
            modal.append(applyPanelBackground(inner, width: modalWidth))
        }
        modal.append(applyPanelBackground(padded("", width: modalWidth), width: modalWidth))

        var result = dimmed
        for (offset, line) in modal.enumerated() {
            let index = top + offset
            guard result.indices.contains(index) else { continue }
            result[index] = overlay(line: result[index], overlay: indent + line, width: width)
        }
        return result
    }

    static func appFooter(width: Int, cwd: String) -> String {
        welcomeFooter(width: width, cwd: cwd)
    }

    private static func interruptBars(frame: Int) -> String {
        let cells = 12
        let litCount = 4
        let cursor = frame % cells
        return (0..<cells).map { index in
            let distance = (index - cursor + cells) % cells
            if distance < litCount {
                return "█"
            }
            if distance == litCount {
                return "▓"
            }
            return "▒"
        }.joined()
    }

    static func normalize(lines: [String], width: Int, height: Int) -> [String] {
        let normalized = lines.prefix(height).map { rawLine in
            let line = fittedLine(rawLine, width: width)
            let visible = VisibleWidth.measure(line)
            guard visible < width else { return line }
            return line + String(repeating: " ", count: width - visible)
        }
        if normalized.count >= height {
            return Array(normalized)
        }
        return normalized + Array(repeating: String(repeating: " ", count: width), count: height - normalized.count)
    }

    static func modelPickerPrompt(current: String) -> String {
        " " + accentBright(AnsiStyling.bold("Select model")) + "  " + muted("current:") + " " + foreground(current)
    }

    static func roleTitle(_ title: String, role: AgentMessageRole) -> String {
        switch role {
        case .assistant:
            return accentBright(title)
        case .user:
            return blue(title)
        case .system:
            return muted(title)
        }
    }

    static func runStatus(_ label: String) -> String {
        let normalized = label.lowercased()
        if normalized.contains("fail") || normalized.contains("error") {
            return red("_\(label)_")
        }
        if normalized.contains("complete") || normalized.contains("done") {
            return green("_\(label)_")
        }
        return yellow("_\(label)_")
    }

    static func isModelProviderError(_ text: String) -> Bool {
        text.localizedCaseInsensitiveContains("Model provider error")
            || text.localizedCaseInsensitiveContains("No models loaded")
    }

    static func errorBlock(_ text: String) -> String {
        "### \(red("Error"))\n\(text)"
    }

    private static func logoLines(width: Int) -> [String] {
        if width < 64 {
            return [center(accentBright(AnsiStyling.bold("sloppy")), width: width)]
        }
        let logo = [
            "███████╗██╗      ██████╗ ██████╗ ██████╗ ██╗   ██╗",
            "██╔════╝██║     ██╔═══██╗██╔══██╗██╔══██╗╚██╗ ██╔╝",
            "███████╗██║     ██║   ██║██████╔╝██████╔╝ ╚████╔╝ ",
            "╚════██║██║     ██║   ██║██╔═══╝ ██╔═══╝   ╚██╔╝  ",
            "███████║███████╗╚██████╔╝██║     ██║        ██║   ",
            "╚══════╝╚══════╝ ╚═════╝ ╚═╝     ╚═╝        ╚═╝   ",
        ]
        return logo.map { center(accentBright($0), width: width) }
    }

    private static func welcomePromptLine(width: Int) -> String {
        let text: String
        if width < 48 {
            text = muted("Ask anything...")
        } else {
            text = muted("Ask anything...  ") + foreground("\"What is the tech stack of this project?\"")
        }
        return accent("▌") + " " + padded(text, width: max(1, width - 2))
    }

    private static func welcomeMetaLine(width: Int, project: String, agent: String, model: String, mode: AgentChatMode) -> String {
        let modelText = truncateEnd(compactModel(model), maxWidth: max(8, width / 3))
        let agentText = truncateEnd(agent, maxWidth: max(6, width / 5))
        let projectText = truncateEnd(project, maxWidth: max(6, width / 5))
        let text = modeTitle(mode) + muted(" · ") + foreground(modelText) + muted("  ") + foreground(agentText) + muted("  ") + muted(projectText)
        return accent("▌") + " " + padded(text, width: max(1, width - 2))
    }

    private static func welcomeShortcutsLine(width: Int) -> String {
        let text: String
        if width < 48 {
            text = foreground("/help") + muted(" commands")
        } else {
            text = foreground("tab") + muted(" mode") + muted("     ") + foreground("/model") + muted(" models") + muted("     ") + foreground("/help") + muted(" commands")
        }
        return "  " + padded(text, width: max(1, width - 2))
    }

    private static func welcomeTipLines(width: Int, contentWidth: Int, offset: Int) -> [String] {
        let compact = contentWidth < 58
        let tips: [String] = compact
            ? [
                "/help lists commands and native scroll behavior.",
                "Use /pet to toggle your Sloppie.",
                "Type # to reference project tasks.",
                "/undo and /redo are per-session.",
            ]
            : [
                "Mouse or trackpad scroll uses your terminal's normal scrollback.",
                "Use /pet to toggle your terminal Sloppie and peek at its current mood.",
                "/undo and /redo restore file changes from the last completed TUI turn.",
                "Type @path to attach project files as explicit context with autocomplete.",
                "Type # to autocomplete active project tasks by id or title.",
                "Use /btw for a side question without disturbing the main task.",
                "Use /diff or /context diff when you want the agent to inspect local changes.",
            ]
        let count = min(tips.count, 1)
        let start = tips.isEmpty ? 0 : ((offset % tips.count) + tips.count) % tips.count
        let visibleTips = (0..<count).map { tips[(start + $0) % tips.count] }
        return visibleTips.map { tip in
            center(yellow("Tip") + muted("  ") + foreground(tip), width: width)
        }
    }

    private static func welcomeFooter(width: Int, cwd: String) -> String {
        let pathWidth = max(1, width - 24)
        let path = truncateStart(shortPath(cwd), maxWidth: pathWidth)
        let left = muted(path) + muted("  ") + green("○") + muted(" ") + foreground("1 MCP") + muted("  /status")
        let right = muted(SloppyVersion.current)
        let leftWidth = VisibleWidth.measure(left)
        let rightWidth = VisibleWidth.measure(right)
        guard leftWidth + rightWidth + 1 <= width else {
            return leftWidth <= width ? left : muted(truncateStart(path, maxWidth: width))
        }
        let gap = width - leftWidth - rightWidth
        return left + String(repeating: " ", count: gap) + right
    }

    private static func applyPanelBackground(_ line: String, width: Int) -> String {
        applyBackground(line, width: width, background: panelBackground)
    }

    private static func applyBackground(_ line: String, width: Int, background: AnsiStyling.Background) -> String {
        AnsiWrapping.applyBackgroundToLine(line, width: width, background: background) + resetBackground
    }

    private static var blockLeftPadding: String {
        String(repeating: " ", count: blockHorizontalPadding)
    }

    private static func paddedBlockContentWidth(width: Int, prefixWidth: Int) -> Int {
        max(1, width - (blockHorizontalPadding * 2) - prefixWidth)
    }

    private static func paddedBlockLineWidth(_ width: Int) -> Int {
        max(1, width - blockHorizontalPadding)
    }

    private static func fittedPaddedBlockLine(_ line: String, width: Int) -> String {
        fittedLine(blockLeftPadding + line, width: paddedBlockLineWidth(width))
    }

    private static func paddedBackgroundBlock(
        _ lines: [String],
        width: Int,
        background: AnsiStyling.Background
    ) -> [String] {
        let padding = Array(repeating: backgroundPaddingLine(width: width, background: background), count: blockVerticalPadding)
        return padding + lines + padding
    }

    private static func backgroundPaddingLine(width: Int, background: AnsiStyling.Background) -> String {
        applyBackground(padded("", width: width), width: width, background: background)
    }

    private static func wrappedBuildProgressLines(
        _ text: String,
        firstPrefix: String,
        continuationPrefix: String,
        width: Int,
        style: (String) -> String,
        prefixStyle: ((String) -> String)? = nil
    ) -> [String] {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let content = normalized.isEmpty ? " " : normalized
        let firstWidth = max(1, width - VisibleWidth.measure(firstPrefix))
        let firstWrapped = AnsiWrapping.wrapText(content, width: firstWidth)
        guard let first = firstWrapped.first else {
            return [fittedLine(firstPrefix, width: width)]
        }

        var lines = [styledBuildProgressLine(prefix: firstPrefix, text: first, style: style, prefixStyle: prefixStyle, width: width)]
        let remaining = firstWrapped.dropFirst()
        let continuationWidth = max(1, width - VisibleWidth.measure(continuationPrefix))
        for fragment in remaining {
            for wrapped in AnsiWrapping.wrapText(fragment, width: continuationWidth) {
                lines.append(styledBuildProgressLine(
                    prefix: continuationPrefix,
                    text: wrapped,
                    style: style,
                    prefixStyle: nil,
                    width: width
                ))
            }
        }
        return lines
    }

    private static func styledBuildProgressLine(
        prefix: String,
        text: String,
        style: (String) -> String,
        prefixStyle: ((String) -> String)?,
        width: Int
    ) -> String {
        let styledPrefix = prefixStyle?(prefix) ?? muted(prefix)
        return fittedLine(styledPrefix + style(text), width: width)
    }

    private static func styledBuildProgressDetail(_ text: String) -> String {
        if text.hasPrefix("DoD: ") {
            return muted("DoD: ") + foreground(String(text.dropFirst(5)))
        }
        if text.hasPrefix("Notes: ") {
            return muted("Notes: ") + foreground(String(text.dropFirst(7)))
        }
        return foreground(text)
    }

    private static func buildProgressMarker(for status: AgentBuildProgressStatus) -> (text: String, style: (String) -> String) {
        switch status {
        case .done:
            return ("[x]", green)
        case .inProgress:
            return ("[~]", orange)
        case .blocked:
            return ("[!]", red)
        case .skipped:
            return ("[-]", muted)
        case .pending:
            return ("[ ]", muted)
        }
    }

    private static func buildProgressStyle(for status: AgentBuildProgressStatus) -> (String) -> String {
        switch status {
        case .done:
            return green
        case .inProgress:
            return orange
        case .blocked:
            return red
        case .skipped, .pending:
            return muted
        }
    }

    private static func selectedLine(_ line: String) -> String {
        "\u{001B}[48;2;251;178;123m\u{001B}[38;2;0;0;0m\(line)\u{001B}[39m\u{001B}[49m"
    }

    private static func overlay(line: String, overlay: String, width: Int) -> String {
        let overlayWidth = VisibleWidth.measure(overlay)
        guard overlayWidth < width else { return overlay }
        let suffix = max(0, width - overlayWidth)
        return overlay + String(repeating: " ", count: suffix)
    }

    private static func center(_ text: String, width: Int) -> String {
        let visible = VisibleWidth.measure(text)
        guard visible < width else { return text }
        return String(repeating: " ", count: (width - visible) / 2) + text
    }

    private static func padded(_ text: String, width: Int) -> String {
        let visible = VisibleWidth.measure(text)
        if visible >= width { return text }
        return text + String(repeating: " ", count: width - visible)
    }

    static func fittedLine(_ text: String, width: Int) -> String {
        guard width > 0 else { return "" }
        guard VisibleWidth.measure(text) > width else { return text }

        let ellipsis = "…"
        let ellipsisWidth = VisibleWidth.measure(ellipsis)
        let contentWidth = max(0, width - ellipsisWidth)
        let truncated = truncateVisible(text, maxWidth: contentWidth)
        let reset = text.contains("\u{001B}") ? "\u{001B}[0m" : ""
        let result = truncated + ellipsis + reset
        guard VisibleWidth.measure(result) <= width else {
            return truncateVisible(result, maxWidth: width)
        }
        return result
    }

    private static func compactModel(_ model: String) -> String {
        let raw = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "default" }
        if let colon = raw.firstIndex(of: ":") {
            return String(raw[raw.index(after: colon)...])
        }
        return raw
    }

    private static func shortPath(_ path: String) -> String {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let expanded: String
        if standardized == homePath {
            expanded = "~"
        } else if standardized.hasPrefix(homePath + "/") {
            expanded = "~" + standardized.dropFirst(homePath.count)
        } else {
            expanded = standardized
        }
        let parts = expanded.split(separator: "/").map(String.init)
        guard parts.count > 2 else { return expanded }
        return "…/" + parts.suffix(2).joined(separator: "/")
    }

    private static func truncateEnd(_ text: String, maxWidth: Int) -> String {
        fittedLine(text, width: maxWidth)
    }

    private static func truncateStart(_ text: String, maxWidth: Int) -> String {
        guard maxWidth > 1, VisibleWidth.measure(text) > maxWidth else { return text }
        let ellipsis = "…"
        let limit = max(0, maxWidth - VisibleWidth.measure(ellipsis))
        var result = ""
        var visible = 0
        for character in text.reversed() {
            let next = String(character)
            let nextWidth = VisibleWidth.measure(next)
            guard visible + nextWidth <= limit else { break }
            result = next + result
            visible += nextWidth
        }
        return ellipsis + result
    }

    private static func highlightedMessageReferences(in line: String) -> String {
        let spans = messageHighlightSpans(in: line)
        guard !spans.isEmpty else {
            return foreground(line)
        }

        var result = ""
        var cursor = line.startIndex
        for span in spans {
            let range = span.range
            if range.lowerBound > cursor {
                result += foreground(String(line[cursor..<range.lowerBound]))
            }
            result += span.style(String(line[range]))
            cursor = range.upperBound
        }
        if cursor < line.endIndex {
            result += foreground(String(line[cursor..<line.endIndex]))
        }
        return result
    }

    private struct MessageHighlightSpan {
        var range: Range<String.Index>
        var style: (String) -> String
    }

    private struct ComposerHighlightSpan {
        var range: Range<Int>
        var style: (String) -> String
    }

    private static func highlightedComposerSyntax(
        in line: String,
        isContinuingProjectPath: Bool
    ) -> (line: String, isContinuingProjectPath: Bool) {
        let plain = strippingANSI(from: line)
        let (spans, nextIsContinuingProjectPath) = composerHighlightSpans(
            in: plain,
            isContinuingProjectPath: isContinuingProjectPath
        )
        guard !spans.isEmpty else {
            return (line, nextIsContinuingProjectPath)
        }

        var result = ""
        var visibleOffset = 0
        var index = line.startIndex
        while index < line.endIndex {
            if line[index] == "\u{001B}" {
                let escapeEnd = ansiEscapeEnd(in: line, from: index)
                result += String(line[index..<escapeEnd])
                index = escapeEnd
                continue
            }

            let character = String(line[index])
            if let span = spans.first(where: { $0.range.contains(visibleOffset) }) {
                result += span.style(character)
            } else {
                result += character
            }
            visibleOffset += 1
            index = line.index(after: index)
        }
        return (result, nextIsContinuingProjectPath)
    }

    private static func truncateVisible(_ text: String, maxWidth: Int) -> String {
        guard maxWidth > 0 else { return "" }

        var result = ""
        var visible = 0
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "\u{001B}" {
                let escapeEnd = ansiEscapeEnd(in: text, from: index)
                result += String(text[index..<escapeEnd])
                index = escapeEnd
                continue
            }

            let character = String(text[index])
            let characterWidth = VisibleWidth.measure(character)
            guard visible + characterWidth <= maxWidth else { break }
            result += character
            visible += characterWidth
            index = text.index(after: index)
        }
        return result
    }

    private static func composerHighlightSpans(
        in line: String,
        isContinuingProjectPath: Bool
    ) -> (spans: [ComposerHighlightSpan], isContinuingProjectPath: Bool) {
        var spans: [ComposerHighlightSpan] = []
        appendComposerSpans(
            pattern: #"(\[paste #[0-9]+(?: [^\]]+)?\])"#,
            captureGroup: 1,
            style: { orange(AnsiStyling.bold($0)) },
            line: line,
            spans: &spans
        )
        let nextIsContinuingProjectPath = appendComposerProjectPathSpans(
            line: line,
            isContinuingProjectPath: isContinuingProjectPath,
            spans: &spans
        )
        appendComposerSpans(
            pattern: #"(^|\s)(/[A-Za-z0-9_][A-Za-z0-9_-]*)"#,
            captureGroup: 2,
            style: { accentBright(AnsiStyling.bold($0)) },
            line: line,
            spans: &spans
        )
        appendComposerSpans(
            pattern: #"(^|\s)(#[A-Za-z0-9][A-Za-z0-9._:-]*)"#,
            captureGroup: 2,
            style: { green(AnsiStyling.bold($0)) },
            line: line,
            spans: &spans
        )
        return (
            spans.sorted { $0.range.lowerBound < $1.range.lowerBound },
            nextIsContinuingProjectPath
        )
    }

    private static func messageHighlightSpans(in line: String) -> [MessageHighlightSpan] {
        var spans: [MessageHighlightSpan] = []
        appendMessageSpans(
            pattern: #"(\[paste #[0-9]+(?: [^\]]+)?\])"#,
            captureGroup: 1,
            style: { orange(AnsiStyling.bold($0)) },
            line: line,
            spans: &spans
        )
        appendMessageSpans(
            pattern: #"(^|\s)(@[A-Za-z0-9._/\-~]+)"#,
            captureGroup: 2,
            style: { yellow($0) },
            line: line,
            spans: &spans
        )
        appendMessageSpans(
            pattern: #"(^|\s)(#[A-Za-z0-9][A-Za-z0-9._:-]*)"#,
            captureGroup: 2,
            style: { green(AnsiStyling.bold($0)) },
            line: line,
            spans: &spans
        )
        return spans.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private static func appendComposerSpans(
        pattern: String,
        captureGroup: Int,
        style: @escaping (String) -> String,
        line: String,
        spans: inout [ComposerHighlightSpan]
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return
        }

        let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
        for match in regex.matches(in: line, range: nsRange) {
            let capturedRange = match.range(at: captureGroup)
            guard capturedRange.location != NSNotFound,
                  let range = Range(capturedRange, in: line)
            else {
                continue
            }

            let lower = line.distance(from: line.startIndex, to: range.lowerBound)
            let upper = line.distance(from: line.startIndex, to: range.upperBound)
            let offsetRange = lower..<upper
            guard !spans.contains(where: { overlaps($0.range, offsetRange) }) else {
                continue
            }
            spans.append(ComposerHighlightSpan(range: offsetRange, style: style))
        }
    }

    private static func appendComposerProjectPathSpans(
        line: String,
        isContinuingProjectPath: Bool,
        spans: inout [ComposerHighlightSpan]
    ) -> Bool {
        var nextIsContinuingProjectPath = false
        var index = line.startIndex
        var activeStart: String.Index?
        var activeHasPathCharacter = isContinuingProjectPath

        if isContinuingProjectPath {
            activeStart = line.startIndex
        }

        while index < line.endIndex {
            let character = line[index]
            if let start = activeStart {
                if character.isWhitespace, !isEscapedProjectPathWhitespace(in: line, at: index, end: line.endIndex) {
                    appendComposerProjectPathSpan(
                        line: line,
                        start: start,
                        end: index,
                        hasPathCharacter: activeHasPathCharacter,
                        spans: &spans
                    )
                    activeStart = nil
                    activeHasPathCharacter = false
                } else if character != "@" {
                    activeHasPathCharacter = true
                }
            } else if character == "@", isProjectPathTokenStart(in: line, at: index) {
                activeStart = index
                activeHasPathCharacter = false
            }
            index = line.index(after: index)
        }

        if let start = activeStart {
            appendComposerProjectPathSpan(
                line: line,
                start: start,
                end: line.endIndex,
                hasPathCharacter: activeHasPathCharacter,
                spans: &spans
            )
            nextIsContinuingProjectPath = activeHasPathCharacter
        }
        return nextIsContinuingProjectPath
    }

    private static func appendComposerProjectPathSpan(
        line: String,
        start: String.Index,
        end: String.Index,
        hasPathCharacter: Bool,
        spans: inout [ComposerHighlightSpan]
    ) {
        guard hasPathCharacter, start < end else {
            return
        }
        let lower = line.distance(from: line.startIndex, to: start)
        let upper = line.distance(from: line.startIndex, to: end)
        let offsetRange = lower..<upper
        guard !spans.contains(where: { overlaps($0.range, offsetRange) }) else {
            return
        }
        spans.append(ComposerHighlightSpan(range: offsetRange, style: { yellow($0) }))
    }

    private static func isProjectPathTokenStart(in line: String, at index: String.Index) -> Bool {
        guard index > line.startIndex else {
            return true
        }
        let previous = line.index(before: index)
        return line[previous].isWhitespace
    }

    private static func isEscapedProjectPathWhitespace(in line: String, at index: String.Index, end: String.Index) -> Bool {
        if hasOddProjectPathBackslashRunBefore(index, in: line) {
            return true
        }
        let next = line.index(after: index)
        return next < end && line[next] == "\\"
    }

    private static func hasOddProjectPathBackslashRunBefore(_ index: String.Index, in line: String) -> Bool {
        var count = 0
        var cursor = index
        while cursor > line.startIndex {
            let previous = line.index(before: cursor)
            guard line[previous] == "\\" else {
                break
            }
            count += 1
            cursor = previous
        }
        return count % 2 == 1
    }

    private static func appendMessageSpans(
        pattern: String,
        captureGroup: Int,
        style: @escaping (String) -> String,
        line: String,
        spans: inout [MessageHighlightSpan]
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return
        }

        let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
        for match in regex.matches(in: line, range: nsRange) {
            let capturedRange = match.range(at: captureGroup)
            guard capturedRange.location != NSNotFound,
                  let range = Range(capturedRange, in: line)
            else {
                continue
            }

            guard !spans.contains(where: { overlaps($0.range, range) }) else {
                continue
            }
            spans.append(MessageHighlightSpan(range: range, style: style))
        }
    }

    private static func overlaps(_ lhs: Range<Int>, _ rhs: Range<Int>) -> Bool {
        lhs.lowerBound < rhs.upperBound && rhs.lowerBound < lhs.upperBound
    }

    private static func overlaps(_ lhs: Range<String.Index>, _ rhs: Range<String.Index>) -> Bool {
        lhs.lowerBound < rhs.upperBound && rhs.lowerBound < lhs.upperBound
    }

    private static func isEditorBorderLine(_ line: String) -> Bool {
        let plain = strippingANSI(from: line)
        return !plain.isEmpty && plain.allSatisfy { $0 == "─" }
    }

    private static func strippingANSI(from line: String) -> String {
        var result = ""
        var index = line.startIndex
        while index < line.endIndex {
            if line[index] == "\u{001B}" {
                index = ansiEscapeEnd(in: line, from: index)
                continue
            }
            result.append(line[index])
            index = line.index(after: index)
        }
        return result
    }

    private static func ansiEscapeEnd(in line: String, from start: String.Index) -> String.Index {
        let next = line.index(after: start)
        guard next < line.endIndex else {
            return next
        }

        if line[next] == "[" {
            var index = line.index(after: next)
            while index < line.endIndex {
                let scalar = line[index].unicodeScalars.first?.value ?? 0
                index = line.index(after: index)
                if scalar >= 0x40 && scalar <= 0x7E {
                    return index
                }
            }
            return line.endIndex
        }

        if line[next] == "]" {
            var index = line.index(after: next)
            while index < line.endIndex {
                if line[index] == "\u{0007}" {
                    return line.index(after: index)
                }
                if line[index] == "\u{001B}" {
                    let possibleTerminator = line.index(after: index)
                    if possibleTerminator < line.endIndex, line[possibleTerminator] == "\\" {
                        return line.index(after: possibleTerminator)
                    }
                }
                index = line.index(after: index)
            }
            return line.endIndex
        }

        return line.index(after: next)
    }

    private static func formattedBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let units = ["KB", "MB", "GB"]
        var value = Double(bytes) / 1024.0
        var unit = units[0]
        for nextUnit in units.dropFirst() where value >= 1024.0 {
            value /= 1024.0
            unit = nextUnit
        }
        return String(format: "%.1f %@", value, unit)
    }

    static func shortID(_ id: String) -> String {
        if id.hasPrefix("session-") {
            let compact = String(id.dropFirst("session-".count))
            guard compact.count > 8 else { return compact }
            return String(compact.prefix(8))
        }
        let compact = id
        guard compact.count > 12 else { return compact }
        return String(compact.prefix(8))
    }

    private static func relativeTime(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        if days < 7 { return "\(days)d ago" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
