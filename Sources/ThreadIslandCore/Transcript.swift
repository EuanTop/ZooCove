import Foundation

public struct Message: Equatable, Identifiable, Sendable {
    public enum Role: String, Sendable { case user, assistant }
    public let id: Int
    public let role: Role
    public let text: String
}

public struct Transcript: Sendable {
    public let messages: [Message]
    public let truncated: Bool

    public static func read(_ session: Session) throws -> Transcript {
        let url = try scopedRollout(for: session)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        let budget: UInt64 = 1_048_576
        let start = length > budget ? length - budget : 0
        try handle.seek(toOffset: start)
        let data = try handle.read(upToCount: Int(min(length, budget))) ?? Data()
        if !session.instance.agent.isCodex {
            return cliTranscript(data, agent: session.instance.agent, truncated: start > 0)
        }
        var messages: [Message] = []
        var events: [Message] = []
        for (number, line) in data.split(separator: 10).dropFirst(start > 0 ? 1 : 0).enumerated() {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = entry["payload"] as? [String: Any] else { continue }
            if entry["type"] as? String == "response_item",
               payload["type"] as? String == "message",
               let value = payload["role"] as? String, let role = Message.Role(rawValue: value),
               let content = payload["content"] as? [[String: Any]] {
                let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
                if let message = makeMessage(number, role, text) { messages.append(message) }
            } else if entry["type"] as? String == "event_msg",
                      let type = payload["type"] as? String,
                      let text = payload["message"] as? String,
                      let role = ["user_message": Message.Role.user, "agent_message": .assistant][type],
                      let message = makeMessage(number, role, text) {
                events.append(message)
            }
        }
        let records = messages.isEmpty ? events : messages
        return Transcript(messages: Array(records.suffix(40)), truncated: start > 0 || records.count > 40)
    }

    private static func cliTranscript(_ data: Data, agent: Instance.Agent, truncated: Bool) -> Transcript {
        let rows = data.split(separator: 10).dropFirst(truncated ? 1 : 0)
            .compactMap { AgentSessions.Entry(Data($0)) }
        var transcript = rows
        if agent == .pi {
            let indexed = rows.compactMap { row -> (String, AgentSessions.Entry)? in
                guard row.type != "session", let id = row.fields["id"] as? String else { return nil }
                return (id, row)
            }
            let entries = Dictionary(indexed, uniquingKeysWith: { _, latest in latest })
            var branch: [AgentSessions.Entry] = []
            var seen: Set<String> = []
            var leaf = indexed.last?.0
            while let id = leaf, seen.insert(id).inserted, let entry = entries[id] {
                branch.append(entry)
                leaf = entry.fields["parentId"] as? String
            }
            transcript = Array(branch.reversed())
        }
        let messages = transcript.enumerated().compactMap { index, entry -> Message? in
            guard entry.isMessage(agent), let role = entry.role.flatMap(Message.Role.init(rawValue:)),
                  role != .user || entry.isUserPrompt, let text = entry.text else { return nil }
            return makeMessage(index, role, text)
        }
        return Transcript(messages: Array(messages.suffix(40)), truncated: truncated || messages.count > 40)
    }

    static func scopedRollout(for session: Session) throws -> URL {
        guard let path = session.rolloutPath, path.hasPrefix("/") else { throw CatalogError.unavailable }
        let recorded = URL(fileURLWithPath: path)
        if !session.instance.agent.isCodex {
            guard let file = AgentSessions.scopedFile(recorded, in: session.instance),
                  AgentSessions.id(at: file, agent: session.instance.agent) == session.threadID else {
                throw CatalogError.unavailable
            }
            return file
        }
        let root = Instance.canonical(session.instance.root.appending(path: "sessions"))
        guard root.path.hasPrefix(session.instance.root.path + "/") else { throw CatalogError.unavailable }

        func ownFile(_ candidate: URL) -> URL? {
            let url = Instance.canonical(candidate)
            guard url.pathExtension == "jsonl", url.path.hasPrefix(root.path + "/"),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { return nil }
            return url
        }

        if let direct = ownFile(recorded) { return direct }

        // Cockpit copies the rollouts with their date hierarchy, but some imported rows
        // still have the source instance's absolute path. Only read the local matching file.
        let components = recorded.pathComponents
        let relative = Array(components.suffix(5))
        guard relative.count == 5, relative[0] == "sessions",
              zip(relative[1...3], [4, 2, 2]).allSatisfy({ part, length in
                  part.utf8.count == length && part.utf8.allSatisfy { (48...57).contains($0) }
              }), Catalog.isThreadID(session.threadID),
              LiveSessions.threadID(in: relative[4]) == session.threadID,
              let relocated = ownFile(relative.dropFirst().reduce(root) { $0.appending(path: $1) })
        else { throw CatalogError.unavailable }
        return relocated
    }

    private static func makeMessage(_ id: Int, _ role: Message.Role, _ text: String) -> Message? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let limit = 20_000
        return Message(id: id, role: role, text: String(text.prefix(limit)) + (text.count > limit ? "…" : ""))
    }
}

public enum SessionLink {
    public static func desktopURL(for threadID: String) -> URL? {
        guard Catalog.isThreadID(threadID) else { return nil }
        return URL(string: "codex://threads/\(threadID)")
    }

    public static func terminalCommand(for session: Session) -> String? {
        guard Catalog.isThreadID(session.threadID) else { return nil }
        let prefix = session.directory.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
            .map { "cd -- \(quote($0)) && " } ?? ""
        switch session.instance.agent {
        case .claudeCode:
            guard (try? Transcript.scopedRollout(for: session)) != nil,
                  let directory = session.directory else { return nil }
            return "cd -- \(quote(directory)) && CLAUDE_CONFIG_DIR=\(quote(session.instance.root.path)) claude --resume \(quote(session.threadID))"
        case .pi:
            guard let file = try? Transcript.scopedRollout(for: session) else { return nil }
            return "\(prefix)PI_CODING_AGENT_DIR=\(quote(session.instance.root.path)) pi --session \(quote(file.path))"
        default:
            return "\(prefix)CODEX_HOME=\(quote(session.instance.root.path)) codex resume \(quote(session.threadID))"
        }
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
