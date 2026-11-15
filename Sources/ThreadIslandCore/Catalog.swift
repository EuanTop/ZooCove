import Foundation
import SQLite3

public struct Session: Identifiable, Equatable, Codable, Sendable {
    public struct ID: Hashable, Codable, Sendable {
        public let instanceID: String
        public let threadID: String
    }

    public let instance: Instance
    public let threadID: String
    public let title: String
    public let directory: String?
    public let updated: Date
    public let rolloutPath: String?
    public var id: ID { ID(instanceID: instance.id, threadID: threadID) }

    public init(instance: Instance, threadID: String, title: String, directory: String?,
                updated: Date, rolloutPath: String?) {
        self.instance = instance
        self.threadID = threadID
        self.title = title
        self.directory = directory
        self.updated = updated
        self.rolloutPath = rolloutPath
    }
}

public enum CatalogError: LocalizedError {
    case unavailable
    case unsupported
    case busy
    case readFailed

    public var errorDescription: String? {
        switch self {
        case .unavailable: "找不到可读取的会话索引"
        case .unsupported: "这个版本的会话索引暂不支持"
        case .busy: "Codex 正在更新索引，请稍后重试"
        case .readFailed: "会话索引读取失败"
        }
    }
}

public enum Catalog {
    private static let indexName = "session_index.jsonl"
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public static func exists(for instance: Instance) -> Bool {
        if !instance.agent.isCodex {
            return (try? instance.sessionDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        return databaseURL(for: instance) != nil ||
        FileManager.default.isReadableFile(atPath: instance.root.appending(path: indexName).path)
    }

    public static func isCatalogEvent(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        if name == indexName { return true }
        return name.hasPrefix("state_") &&
            [".sqlite", ".sqlite-wal", ".sqlite-shm"].contains(where: { name.hasSuffix($0) }) &&
            !name.hasSuffix("-shm")
    }

    public static func isThreadID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil ||
            (value.hasPrefix("thr_") && (5...96).contains(value.utf8.count) &&
             value.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) ||
                                    ($0 >= 97 && $0 <= 122) || $0 == 95 || $0 == 45 })
    }

    public static func sessions(in instance: Instance, matching query: String = "",
                                limit: Int = 60, offset: Int = 0) throws -> [Session] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let window = min(max(limit, 1), 200)
        if !instance.agent.isCodex {
            return AgentSessions.sessions(in: instance, matching: search, limit: window, offset: max(0, offset))
        }
        do {
            return try sqliteSessions(in: instance, query: search, limit: window, offset: max(0, offset))
        } catch CatalogError.unsupported {
            return try indexSessions(in: instance, query: search, limit: window, offset: max(0, offset))
        } catch CatalogError.unavailable {
            return try indexSessions(in: instance, query: search, limit: window, offset: max(0, offset))
        }
    }

    public static func session(id: String, in instance: Instance) throws -> Session? {
        guard isThreadID(id) else { return nil }
        if !instance.agent.isCodex {
            return AgentSessions.sessions(in: instance, matching: "", limit: 1, offset: 0, exactID: id).first
        }
        do {
            return try sqliteSessions(in: instance, query: "", limit: 1, offset: 0, exactID: id).first
        } catch CatalogError.unsupported {
            return try indexSessions(in: instance, query: "", limit: 1, offset: 0, exactID: id).first
        } catch CatalogError.unavailable {
            return try indexSessions(in: instance, query: "", limit: 1, offset: 0, exactID: id).first
        }
    }

    public static func interactiveSession(id: String, in instance: Instance) throws -> Session? {
        guard isThreadID(id) else { return nil }
        if !instance.agent.isCodex { return try session(id: id, in: instance) }
        return try sqliteSessions(in: instance, query: "", limit: 1, offset: 0,
                                  exactID: id, interactiveOnly: true).first
    }

    private static func databaseURL(for instance: Instance) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: instance.root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        )) ?? []
        return files.compactMap { url -> (url: URL, version: Int)? in
            let name = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "sqlite", name.hasPrefix("state_"),
                  let version = Int(name.dropFirst(6)),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  Instance.canonical(url).deletingLastPathComponent().path == instance.root.path else { return nil }
            return (url, version)
        }.max(by: { $0.version < $1.version })?.url
    }

    private static func sqliteSessions(in instance: Instance, query: String, limit: Int, offset: Int,
                                       exactID: String? = nil, interactiveOnly: Bool = false) throws -> [Session] {
        guard let url = databaseURL(for: instance) else { throw CatalogError.unavailable }
        var db: OpaquePointer?
        let opened = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        defer { sqlite3_close(db) }
        guard opened == SQLITE_OK, let db else { throw CatalogError.readFailed }
        sqlite3_busy_timeout(db, 250)
        sqlite3_db_configDefensive(db)

        var schema: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(threads)", -1, &schema, nil) == SQLITE_OK,
              let schema else { throw CatalogError.readFailed }
        var columns: Set<String> = []
        while sqlite3_step(schema) == SQLITE_ROW {
            if let name = string(schema, 1) { columns.insert(name) }
        }
        sqlite3_finalize(schema)
        guard columns.contains("id"), columns.contains("title"),
              columns.contains("updated_at") || columns.contains("updated_at_ms") ||
              columns.contains("recency_at_ms") else { throw CatalogError.unsupported }

        let dateColumn = ["recency_at_ms", "updated_at_ms", "updated_at"].first { columns.contains($0) }!
        let title = columns.contains("name") ? "COALESCE(NULLIF(name, ''), title)" : "title"
        let cwd = columns.contains("cwd") ? "cwd" : "NULL"
        let rollout = columns.contains("rollout_path") ? "rollout_path" : "NULL"
        var predicates = ["id IS NOT NULL"]
        var parameters: [String] = []
        if let exactID {
            predicates.append("id = ?")
            parameters.append(exactID)
        }
        if exactID == nil || interactiveOnly {
            if columns.contains("archived") { predicates.append("archived = 0") }
            if exactID == nil && columns.contains("has_user_event") {
                predicates.append("(has_user_event = 1 OR LENGTH(TRIM(\(title))) > 0)")
            }
            if columns.contains("source") {
                predicates.append("COALESCE(source, '') <> 'exec'")
                predicates.append("COALESCE(source, '') NOT LIKE '%subagent%'")
            }
            if !query.isEmpty {
                let value = "%" + query.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_") + "%"
                predicates.append("(\(title) LIKE ? ESCAPE '\\' OR \(cwd) LIKE ? ESCAPE '\\' OR id LIKE ? ESCAPE '\\')")
                parameters += [value, value, value]
            }
        }
        func prepare(table: String) -> OpaquePointer? {
            let sql = """
                SELECT id, \(title), \(cwd), \(dateColumn), \(rollout) FROM \(table)
                WHERE \(predicates.joined(separator: " AND "))
                ORDER BY \(dateColumn) DESC, id DESC LIMIT ? OFFSET ?
                """
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK { return statement }
            sqlite3_finalize(statement)
            return nil
        }
        let recentIndex = exactID == nil && dateColumn == "recency_at_ms"
            ? prepare(table: "threads INDEXED BY idx_threads_recency_at_ms") : nil
        guard let statement = recentIndex ?? prepare(table: "threads") else { throw CatalogError.readFailed }
        defer { sqlite3_finalize(statement) }
        for (index, value) in parameters.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
        }
        sqlite3_bind_int64(statement, Int32(parameters.count + 1), Int64(limit))
        sqlite3_bind_int64(statement, Int32(parameters.count + 2), Int64(offset))

        var rows: [Session] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if let id = string(statement, 0), isThreadID(id) {
                let date = Double(sqlite3_column_int64(statement, 3)) / (dateColumn.hasSuffix("_ms") ? 1_000 : 1)
                rows.append(Session(instance: instance, threadID: id, title: displayTitle(string(statement, 1)),
                                    directory: string(statement, 2), updated: Date(timeIntervalSince1970: date),
                                    rolloutPath: string(statement, 4)))
            }
            result = sqlite3_step(statement)
        }
        if result == SQLITE_BUSY || result == SQLITE_LOCKED { throw CatalogError.busy }
        guard result == SQLITE_DONE else { throw CatalogError.readFailed }
        return rows
    }

    private struct IndexEntry: Decodable {
        let id: String
        let thread_name: String?
        let updated_at: String?
    }

    private static func indexSessions(in instance: Instance, query: String, limit: Int, offset: Int,
                                       exactID: String? = nil) throws -> [Session] {
        let url = instance.root.appending(path: indexName)
        guard Instance.canonical(url).deletingLastPathComponent().path == instance.root.path,
              let handle = try? FileHandle(forReadingFrom: url) else { throw CatalogError.unavailable }
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        let budget: UInt64 = 2 * 1_024 * 1_024
        try handle.seek(toOffset: length > budget ? length - budget : 0)
        let data = try handle.read(upToCount: Int(budget)) ?? Data()
        let decoder = JSONDecoder()
        let date = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var latest: [String: Session] = [:]
        for line in data.split(separator: 10).dropFirst(length > budget ? 1 : 0) {
            guard let row = try? decoder.decode(IndexEntry.self, from: Data(line)),
                  isThreadID(row.id) else { continue }
            if let exactID, row.id != exactID { continue }
            let updated = row.updated_at.flatMap { fractional.date(from: $0) ?? date.date(from: $0) }
            let title = displayTitle(row.thread_name)
            let session = Session(instance: instance, threadID: row.id, title: title, directory: nil,
                                  updated: updated ?? .distantPast, rolloutPath: nil)
            if let existing = latest[row.id], existing.updated > session.updated { continue }
            latest[row.id] = session
        }
        let filtered = latest.values.filter {
            query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) ||
                $0.threadID.localizedCaseInsensitiveContains(query)
        }.sorted {
            $0.updated == $1.updated ? $0.threadID > $1.threadID : $0.updated > $1.updated
        }
        return Array(filtered.dropFirst(offset).prefix(limit))
    }

    private static func string(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        sqlite3_column_text(stmt, index).map { String(cString: $0) }
    }

    private static func displayTitle(_ value: String?) -> String {
        let cleaned = value?.split(whereSeparator: \.isWhitespace).joined(separator: " ") ?? ""
        return cleaned.isEmpty ? "未命名会话" : String(cleaned.prefix(250))
    }
}

private func sqlite3_db_configDefensive(_ db: OpaquePointer) {
    // The owner's database supplies data. This connection never evaluates application-defined SQL.
    sqlite3_exec(db, "PRAGMA query_only = ON; PRAGMA trusted_schema = OFF;", nil, nil, nil)
}
