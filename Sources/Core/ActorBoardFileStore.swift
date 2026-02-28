import Foundation
import Protocols

final class ActorBoardFileStore {
    enum StoreError: Error {
        case invalidPayload
        case actorNotFound
        case storageFailure
    }

    private enum SystemActor {
        static let adminID = "human:admin"
        static let adminChannelID = "channel:admin"
    }

    private let fileManager: FileManager
    private var workspaceRootURL: URL

    init(workspaceRootURL: URL, fileManager: FileManager = .default) {
        self.workspaceRootURL = workspaceRootURL
        self.fileManager = fileManager
    }

    func updateWorkspaceRootURL(_ url: URL) {
        self.workspaceRootURL = url
    }

    func loadBoard(agents: [AgentSummary]) throws -> ActorBoardSnapshot {
        let stored = try readStoredBoard()
        let synchronized = try synchronizeSystemActors(snapshot: stored, agents: agents)
        if synchronized != stored {
            try writeBoard(synchronized)
        }
        return synchronized
    }

    func saveBoard(_ request: ActorBoardUpdateRequest, agents: [AgentSummary]) throws -> ActorBoardSnapshot {
        do {
            let sanitized = try sanitizeRequest(request)
            let synchronized = try synchronizeSystemActors(
                snapshot: ActorBoardSnapshot(
                    nodes: sanitized.nodes,
                    links: sanitized.links,
                    teams: sanitized.teams,
                    updatedAt: Date()
                ),
                agents: agents
            )
            try writeBoard(synchronized)
            return synchronized
        } catch {
            throw mapError(error)
        }
    }

    func resolveRoute(_ request: ActorRouteRequest, agents: [AgentSummary]) throws -> ActorRouteResponse {
        let normalizedActorID = request.fromActorId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedActorID.isEmpty else {
            throw StoreError.invalidPayload
        }

        let board = try loadBoard(agents: agents)
        let nodeIDs = Set(board.nodes.map(\.id))
        guard nodeIDs.contains(normalizedActorID) else {
            throw StoreError.actorNotFound
        }

        var recipients = Set<String>()

        for link in board.links {
            if let communicationType = request.communicationType, link.communicationType != communicationType {
                continue
            }

            if link.sourceActorId == normalizedActorID {
                recipients.insert(link.targetActorId)
            } else if link.direction == .twoWay, link.targetActorId == normalizedActorID {
                recipients.insert(link.sourceActorId)
            }
        }

        recipients.remove(normalizedActorID)
        return ActorRouteResponse(
            fromActorId: normalizedActorID,
            recipientActorIds: recipients.sorted()
        )
    }

    private func sanitizeRequest(_ request: ActorBoardUpdateRequest) throws -> ActorBoardUpdateRequest {
        var seenNodeIDs = Set<String>()
        var nodes: [ActorNode] = []

        for rawNode in request.nodes {
            let nodeID = normalizedIdentifier(rawNode.id)
            guard !nodeID.isEmpty else {
                continue
            }

            if !seenNodeIDs.insert(nodeID).inserted {
                continue
            }

            var node = rawNode
            node.id = nodeID
            node.displayName = normalizedDisplayName(rawNode.displayName, fallback: nodeID)
            node.channelId = normalizedOptionalValue(rawNode.channelId)
            node.role = normalizedOptionalValue(rawNode.role)
            node.linkedAgentId = normalizedOptionalValue(rawNode.linkedAgentId)
            node.positionX = rawNode.positionX.isFinite ? rawNode.positionX : 0
            node.positionY = rawNode.positionY.isFinite ? rawNode.positionY : 0
            nodes.append(node)
        }

        let nodeIDs = Set(nodes.map(\.id))
        var seenLinkIDs = Set<String>()
        var links: [ActorLink] = []

        for rawLink in request.links {
            let linkID = normalizedIdentifier(rawLink.id)
            guard !linkID.isEmpty else {
                continue
            }

            if !seenLinkIDs.insert(linkID).inserted {
                continue
            }

            let sourceID = normalizedIdentifier(rawLink.sourceActorId)
            let targetID = normalizedIdentifier(rawLink.targetActorId)
            guard !sourceID.isEmpty, !targetID.isEmpty, sourceID != targetID else {
                continue
            }

            guard nodeIDs.contains(sourceID), nodeIDs.contains(targetID) else {
                continue
            }

            var link = rawLink
            link.id = linkID
            link.sourceActorId = sourceID
            link.targetActorId = targetID
            links.append(link)
        }

        var seenTeamIDs = Set<String>()
        var teams: [ActorTeam] = []
        for rawTeam in request.teams {
            let teamID = normalizedIdentifier(rawTeam.id)
            guard !teamID.isEmpty else {
                continue
            }

            if !seenTeamIDs.insert(teamID).inserted {
                continue
            }

            let teamName = normalizedDisplayName(rawTeam.name, fallback: teamID)
            let memberActorIDs = Array(
                Set(rawTeam.memberActorIds.map(normalizedIdentifier).filter { nodeIDs.contains($0) })
            ).sorted()

            var team = rawTeam
            team.id = teamID
            team.name = teamName
            team.memberActorIds = memberActorIDs
            teams.append(team)
        }

        return ActorBoardUpdateRequest(nodes: nodes, links: links, teams: teams)
    }

    private func synchronizeSystemActors(snapshot: ActorBoardSnapshot?, agents: [AgentSummary]) throws -> ActorBoardSnapshot {
        var nodesByID: [String: ActorNode] = [:]
        if let snapshot {
            for node in snapshot.nodes {
                nodesByID[node.id] = node
            }
        }

        if nodesByID[SystemActor.adminID] == nil {
            nodesByID[SystemActor.adminID] = ActorNode(
                id: SystemActor.adminID,
                displayName: "Admin",
                kind: .human,
                channelId: SystemActor.adminChannelID,
                role: "Workspace administrator",
                positionX: 120,
                positionY: 380
            )
        } else {
            var admin = nodesByID[SystemActor.adminID]!
            admin.kind = .human
            admin.displayName = "Admin"
            admin.channelId = SystemActor.adminChannelID
            admin.role = "Workspace administrator"
            nodesByID[SystemActor.adminID] = admin
        }

        let currentAgentIDs = Set(agents.map(\.id))
        var agentNodeIDs = Set<String>()

        for (index, agent) in agents.enumerated() {
            let preferredID = "agent:\(agent.id)"
            agentNodeIDs.insert(preferredID)
            let existingNode = nodesByID[preferredID]
            let existingPositionX = existingNode?.positionX ?? (120 + Double(index % 5) * 220)
            let existingPositionY = existingNode?.positionY ?? (120 + Double(index / 5) * 180)
            nodesByID[preferredID] = ActorNode(
                id: preferredID,
                displayName: agent.displayName,
                kind: .agent,
                linkedAgentId: agent.id,
                channelId: "agent:\(agent.id)",
                role: agent.role,
                positionX: existingPositionX,
                positionY: existingPositionY,
                createdAt: existingNode?.createdAt ?? agent.createdAt
            )
        }

        let agentNodesToRemove = nodesByID.compactMap { entry -> String? in
            let nodeID = entry.key
            let node = entry.value
            if node.kind != .agent {
                return nil
            }

            let linkedAgentID = node.linkedAgentId?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let linkedAgentID, currentAgentIDs.contains(linkedAgentID), agentNodeIDs.contains(nodeID) {
                return nil
            }

            if nodeID == SystemActor.adminID {
                return nil
            }

            return nodeID
        }

        for nodeID in agentNodesToRemove {
            nodesByID.removeValue(forKey: nodeID)
        }

        let allNodeIDs = Set(nodesByID.keys)

        let links = (snapshot?.links ?? []).filter { link in
            allNodeIDs.contains(link.sourceActorId) && allNodeIDs.contains(link.targetActorId) && link.sourceActorId != link.targetActorId
        }

        let teams = (snapshot?.teams ?? []).map { team in
            ActorTeam(
                id: team.id,
                name: team.name,
                memberActorIds: team.memberActorIds.filter { allNodeIDs.contains($0) }.sorted(),
                createdAt: team.createdAt
            )
        }

        let sortedNodes = nodesByID.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        let sortedLinks = links.sorted { $0.createdAt < $1.createdAt }
        let sortedTeams = teams.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let hasStructuralChanges = snapshot?.nodes != sortedNodes || snapshot?.links != sortedLinks || snapshot?.teams != sortedTeams

        return ActorBoardSnapshot(
            nodes: sortedNodes,
            links: sortedLinks,
            teams: sortedTeams,
            updatedAt: hasStructuralChanges ? Date() : (snapshot?.updatedAt ?? Date())
        )
    }

    private func readStoredBoard() throws -> ActorBoardSnapshot? {
        let fileURL = boardFileURL()
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(ActorBoardSnapshot.self, from: data)
        } catch {
            throw StoreError.storageFailure
        }
    }

    private func writeBoard(_ snapshot: ActorBoardSnapshot) throws {
        do {
            try ensureActorsDirectory()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let payload = try encoder.encode(snapshot) + Data("\n".utf8)
            try payload.write(to: boardFileURL(), options: .atomic)
        } catch {
            throw StoreError.storageFailure
        }
    }

    private func ensureActorsDirectory() throws {
        try fileManager.createDirectory(at: actorsRootURL(), withIntermediateDirectories: true)
    }

    private func actorsRootURL() -> URL {
        workspaceRootURL.appendingPathComponent("actors", isDirectory: true)
    }

    private func boardFileURL() -> URL {
        actorsRootURL().appendingPathComponent("board.json")
    }

    private func normalizedIdentifier(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:/")
        if trimmed.rangeOfCharacter(from: allowed.inverted) != nil {
            return ""
        }
        if trimmed.count > 180 {
            return ""
        }
        return trimmed
    }

    private func normalizedDisplayName(_ raw: String, fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func normalizedOptionalValue(_ raw: String?) -> String? {
        guard let raw else {
            return nil
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func mapError(_ error: Error) -> StoreError {
        if let storeError = error as? StoreError {
            return storeError
        }
        return .storageFailure
    }
}
