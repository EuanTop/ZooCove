import Foundation

/// Read-only adapters for the Claude Code and Pi CLI transcript trees.
enum AgentSessions {
    struct Entry {
        let fields: [String: Any]
        let message: [String: Any]

        init?(_ data: Data) {
            guard let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            self.fields = fields
            self.message = fields["message"] as? [String: Any] ?? [:]
        }

        var type: String? { fields["type"] as? String }
        var role: String? { message["role"] as? String }
        var timestamp: Date? {
            guard let text = fields["timestamp"] as? String else { return nil }
            return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
                ?? (try? Date.ISO8601FormatStyle().parse(text))
        }

        var text: String? {
            if let text = message["content"] as? String { return text }
            let blocks = message["content"] as? [[String: Any]] ?? []
            let text = blocks.filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }.joined(separator: "\n")
            return text.isEmpty ? nil : text
        }

        func isMessage(_ agent: Instance.Agent) -> Bool {
            if agent == .pi { return type == "message" }
            return type == role && fields["isSidechain"] as? Bool != true && fields["isMeta"] as? Bool != true
        }

        var isUserPrompt: Bool {
            guard role == "user", let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            return !["<local-command", "<command-name>", "<task-notification>", "[Request interrupted by user"]
                .contains { text.hasPrefix($0) }
        }
    }

    enum Event {
        case start(String)
        case finish
        case cancel
    }

    static func event(in raw: Data, agent: Instance.Agent) -> (Event, Date?)? {
        let header = raw.prefix(512)
        guard (agent == .pi && header.range(of: Data("\"message\"".utf8)) != nil)
                || (agent == .claudeCode && (header.range(of: Data("\"user\"".utf8)) != nil
                                  || header.range(of: Data("\"assistant\"".utf8)) != nil)),
              let row = Entry(raw) else { return nil }
        if agent == .claudeCode,
           row.type == "user", row.role == "user", row.fields["isSidechain"] as? Bool != true,
           row.text?.hasPrefix("[Request interrupted by user") == true {
            return (.cancel, row.timestamp)
        }
        guard row.isMessage(agent) else { return nil }
        if row.isUserPrompt, let id = row.fields[agent == .pi ? "id" : "uuid"] as? String {
            return (.start(id), row.timestamp)
        }
        guard row.role == "assistant" else { return nil }
        if row.fields["isApiErrorMessage"] as? Bool == true { return (.cancel, row.timestamp) }
        let stop = row.message[agent == .pi ? "stopReason" : "stop_reason"] as? String
        switch (agent, stop) {
        case (.pi, "stop"), (.claudeCode, "end_turn"), (.claudeCode, "stop_sequence"):
            return (.finish, row.timestamp)
        case (.pi, "error"), (.pi, "aborted"), (.pi, "length"), (.claudeCode, "max_tokens"),
             (.claudeCode, "refusal"), (.claudeCode, "error"):
            return (.cancel, row.timestamp)
        default:
            return nil
        }
    }

    static func id(at url: URL, agent: Instance.Agent) -> String? {
        guard url.pathExtension == "jsonl" else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        if agent == .pi, name.dropLast(36).hasSuffix("_") {
            let id = String(name.suffix(36))
            return UUID(uuidString: id) == nil ? nil : id
        }
        return UUID(uuidString: name) == nil ? nil : name
    }

    static func scopedFile(_ url: URL, in instance: Instance) -> URL? {
        let root = instance.sessionDirectory
        let file = Instance.canonical(url)
        guard file.path.hasPrefix(root.path + "/"), file.path == url.standardizedFileURL.path,
              (1...2).contains(file.pathComponents.count - root.pathComponents.count),
              id(at: file, agent: instance.agent) != nil,
              (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return file
    }

    static func sessions(in instance: Instance, matching query: String, limit: Int,
                         offset: Int, exactID: String? = nil) -> [Session] {
        let manager = FileManager.default
        let root = instance.sessionDirectory
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        let contents = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: keys,
                                                         options: [.skipsHiddenFiles])) ?? []
        var candidates: [(url: URL, modified: Date)] = []
        for item in contents {
            let metadata = try? item.resourceValues(forKeys: Set(keys))
            guard metadata?.isSymbolicLink != true else { continue }
            let paths = metadata?.isDirectory == true
                ? (try? manager.contentsOfDirectory(at: item, includingPropertiesForKeys: keys,
                                                    options: [.skipsHiddenFiles])) ?? []
                : [item]
            for path in paths {
                guard let id = id(at: path, agent: instance.agent),
                      exactID.map({ id.caseInsensitiveCompare($0) == .orderedSame }) ?? true,
                      let modified = try? path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                else { continue }
                candidates.append((path, modified))
            }
        }
        candidates.sort {
            if $0.modified != $1.modified { return $0.modified > $1.modified }
            return $0.url.path < $1.url.path
        }
        var result: [Session] = []
        var seen: Set<String> = []
        var remaining = offset
        for item in candidates {
            guard let session = session(at: item.url, in: instance, modified: item.modified),
                  [session.title, session.directory ?? "", session.threadID]
                    .contains(where: { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }),
                  seen.insert(session.threadID.lowercased()).inserted else { continue }
            if remaining > 0 { remaining -= 1; continue }
            result.append(session)
            if result.count == limit { break }
        }
        return result
    }

    static func session(at url: URL, in instance: Instance, modified: Date? = nil) -> Session? {
        guard let file = scopedFile(url, in: instance), let id = id(at: file, agent: instance.agent),
              let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 96 * 1024), !data.isEmpty else { return nil }
        let lines = data.split(separator: 10)
        var directory: String?
        var title: String?
        if instance.agent == .pi {
            guard let line = lines.first, let first = Entry(Data(line)), first.type == "session",
                  (first.fields["id"] as? String)?.caseInsensitiveCompare(id) == .orderedSame else { return nil }
            directory = first.fields["cwd"] as? String
        }
        for line in lines {
            guard let row = Entry(Data(line)) else { continue }
            if instance.agent == .claudeCode {
                guard (row.fields["sessionId"] as? String)?.caseInsensitiveCompare(id) == .orderedSame
                        || row.type == "custom-title" else { continue }
                if directory == nil { directory = row.fields["cwd"] as? String }
            }
            if let named = row.fields["customTitle"] as? String ?? row.fields["name"] as? String,
               row.type == "custom-title" || row.type == "session_info" {
                title = named
            } else if title == nil, row.isMessage(instance.agent), row.isUserPrompt {
                title = row.text
            }
            if directory != nil && title != nil { break }
        }
        if let directoryValue = directory, !directoryValue.hasPrefix("/") { directory = nil }
        if instance.agent == .claudeCode, directory == nil, title == nil { return nil }
        let label = title?.split(whereSeparator: \.isWhitespace).joined(separator: " ") ?? ""
        let fallback = directory.map { URL(fileURLWithPath: $0).lastPathComponent } ?? id
        return Session(instance: instance, threadID: id, title: label.isEmpty ? fallback : String(label.prefix(120)),
                       directory: directory, updated: modified ?? fileDate(file), rolloutPath: file.path)
    }

    private static func fileDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
