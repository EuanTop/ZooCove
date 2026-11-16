import Darwin
import Foundation

public struct RunningSession: Equatable, Identifiable, Sendable {
    public let session: Session
    public let lastActivity: Date
    public let rolloutPath: String
    public let turnID: String
    public var id: Session.ID { session.id }

    public var trackedTurn: TrackedTurn {
        TrackedTurn(id: id, path: rolloutPath, turnID: turnID)
    }
}

public struct TrackedTurn: Codable, Equatable, Sendable {
    public let id: Session.ID
    public let path: String
    public let turnID: String
}

public struct CompletedTurn: Codable, Equatable, Sendable {
    public let session: Session
    public let turnID: String
    public let completedAt: Date
}

public struct LiveUpdate: Sendable {
    public let running: [RunningSession]
    public let completed: [CompletedTurn]
    public let watchedRollouts: Set<String>
}

struct TurnCursor {
    struct Completion {
        let turnID: String
        let timestamp: Date?
    }

    private enum Marker: String, CaseIterable, Decodable {
        case taskStarted = "task_started"
        case turnStarted = "turn_started"
        case taskComplete = "task_complete"
        case turnComplete = "turn_complete"
        case turnCompleted = "turn_completed"
        case turnAborted = "turn_aborted"
        case turnFailed = "turn_failed"

        var starts: Bool { self == .taskStarted || self == .turnStarted }
        var succeeds: Bool { self == .taskComplete || self == .turnComplete || self == .turnCompleted }
    }

    private struct Line: Decodable {
        struct Payload: Decodable {
            let type: Marker
            let turn_id: String?
            let status: String?
        }

        let type: String
        let timestamp: String?
        let payload: Payload
    }

    private static let markers = Marker.allCases.map { Data(("\"" + $0.rawValue + "\"").utf8) }
    private static let eventMessage = Data("\"event_msg\"".utf8)
    private var offset: UInt64 = 0
    private var inode: UInt64?
    private var discardPartialLine = false
    private(set) var turn: String?
    private(set) var modified = Date.distantPast
    private(set) var completions: [Completion] = []

    mutating func update(_ url: URL, agent: Instance.Agent = .codex, modifiedSince cutoff: Date? = nil) throws {
        completions.removeAll(keepingCapacity: true)
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var info = stat()
        guard fstat(file.fileDescriptor, &info) == 0, info.st_size >= 0 else { throw CatalogError.readFailed }
        let length = UInt64(info.st_size)
        modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) +
                        Double(info.st_mtimespec.tv_nsec) / 1e9)
        if let cutoff, modified < cutoff { return }
        if inode != info.st_ino || offset > length {
            inode = info.st_ino
            offset = 0
            turn = nil
            discardPartialLine = false
        }
        guard length > offset else { return }
        let budget: UInt64 = 2 * 1_024 * 1_024
        if length - offset > budget {
            let alreadyRead = offset != 0
            offset = length - budget
            discardPartialLine = true
            // A large discontinuity may contain a newer terminal event.
            if alreadyRead { turn = nil }
        }

        try file.seek(toOffset: offset)
        let data = try file.read(upToCount: Int(length - offset)) ?? Data()
        guard let lastNewline = data.lastIndex(of: 10) else { return }
        var start = data.startIndex
        if discardPartialLine, let first = data.firstIndex(of: 10) {
            start = data.index(after: first)
            discardPartialLine = false
        }
        let decoder = JSONDecoder()
        let complete = data[start..<data.index(after: lastNewline)]
        for raw in complete.split(separator: 10) {
            if !agent.isCodex {
                guard let (event, timestamp) = AgentSessions.event(in: Data(raw), agent: agent) else { continue }
                switch event {
                case .start(let id):
                    turn = id
                case .finish:
                    if let turn { completions.append(Completion(turnID: turn, timestamp: timestamp)) }
                    turn = nil
                case .cancel:
                    turn = nil
                }
                continue
            }
            let header = raw.prefix(512)
            guard header.range(of: Self.eventMessage) != nil,
                  Self.markers.contains(where: { raw.range(of: $0) != nil }),
                  let line = try? decoder.decode(Line.self, from: Data(raw)),
                  line.type == "event_msg" else { continue }
            let id = line.payload.turn_id
            if line.payload.type.starts {
                turn = id ?? ""
            } else if turn == nil || id == nil || turn == id || turn == "" {
                if let ended = id ?? turn, !ended.isEmpty, line.payload.type.succeeds,
                   !["failed", "interrupted", "cancelled", "canceled", "aborted"].contains(line.payload.status ?? "") {
                    let timestamp = line.timestamp.flatMap { value in
                        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value)) ??
                            (try? Date.ISO8601FormatStyle().parse(value))
                    }
                    completions.append(Completion(turnID: ended, timestamp: timestamp))
                }
                turn = nil
            }
        }
        offset += UInt64(lastNewline + 1)
    }
}

public actor LiveSessions {
    private struct Record {
        let instance: Instance
        var cursor: TurnCursor
        var session: Session?
    }

    public static let activityTimeout: TimeInterval = 20 * 60
    private static let recentRolloutLimit = 12
    private var records: [URL: Record] = [:]
    private var recentCodexRollouts: [Instance.ID: [String]] = [:]
    private var delivered: [Session.ID: CompletedTurn] = [:]
    private let startedAt = Date.now

    public init() {}

    public func update(instances: [Instance], paths: Set<String>, seed: Bool,
                       recovering tracked: [TrackedTurn] = []) -> LiveUpdate {
        let enabled = Set(instances.map(\.id))
        records = records.filter { enabled.contains($0.value.instance.id) }
        recentCodexRollouts = recentCodexRollouts.filter { enabled.contains($0.key) }
        let cutoff = Date.now.addingTimeInterval(-Self.activityTimeout)
        var completed: [Session.ID: CompletedTurn] = [:]
        var candidates = paths
        let recovered = Dictionary(tracked.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        candidates.formUnion(recovered.keys)

        if seed {
            for instance in instances {
                guard let recent = try? Catalog.sessions(in: instance, limit: Self.recentRolloutLimit) else { continue }
                let rollouts = recent.compactMap { session -> (URL, Session)? in
                    guard let url = try? Transcript.scopedRollout(for: session) else { return nil }
                    return (url, session)
                }
                if instance.agent.isCodex {
                    // Codex keeps its rollout open between turns. Directory events can miss appends.
                    recentCodexRollouts[instance.id] = rollouts.map { $0.0.path }
                }
                for (url, session) in rollouts where recovered[url.path] == nil {
                    read(url, instance: instance, id: session.threadID, knownSession: session,
                         recovering: nil, cutoff: cutoff, completed: &completed)
                    candidates.remove(url.path)
                }
            }
        }
        for path in candidates.sorted() {
            let recorded = URL(fileURLWithPath: path)
            let url = Instance.canonical(recorded)
            guard let instance = instances.first(where: { url.path.hasPrefix($0.sessionDirectory.path + "/") }) else { continue }
            let id: String
            if instance.agent.isCodex {
                guard let thread = Self.threadID(in: path) else { continue }
                id = thread
            } else {
                guard AgentSessions.scopedFile(recorded, in: instance) != nil,
                      let thread = AgentSessions.id(at: url, agent: instance.agent) else { continue }
                id = thread
            }
            let previous = recovered[path]
            read(url, instance: instance, id: id, knownSession: nil,
                 recovering: previous?.id.instanceID == instance.id && previous?.id.threadID == id ? previous : nil,
                 cutoff: cutoff, completed: &completed)
        }
        records = records.filter { $0.value.cursor.modified >= cutoff }
        if records.count > 128 {
            let recent = records.sorted { $0.value.cursor.modified > $1.value.cursor.modified }.prefix(128)
            records = Dictionary(uniqueKeysWithValues: recent.map { ($0.key, $0.value) })
        }
        var active: [Session.ID: RunningSession] = [:]
        for (url, record) in records {
            guard let turn = record.cursor.turn, let session = record.session else { continue }
            let candidate = RunningSession(session: session, lastActivity: record.cursor.modified,
                                           rolloutPath: url.path, turnID: turn)
            if let previous = active[session.id], previous.lastActivity >= candidate.lastActivity { continue }
            active[session.id] = candidate
        }
        let ordered = active.values.sorted {
            let order = $0.session.instance.name.localizedStandardCompare($1.session.instance.name)
            if order != .orderedSame { return order == .orderedAscending }
            if $0.session.instance.id != $1.session.instance.id { return $0.session.instance.id < $1.session.instance.id }
            return $0.session.threadID < $1.session.threadID
        }
        let watched = Set(ordered.map(\.rolloutPath)).union(recentCodexRollouts.values.joined())
        return LiveUpdate(running: ordered, completed: Array(completed.values), watchedRollouts: watched)
    }

    public nonisolated static func isRollout(_ path: String) -> Bool { threadID(in: path) != nil }

    private func read(_ url: URL, instance: Instance, id: String, knownSession: Session?,
                      recovering: TrackedTurn?, cutoff: Date, completed: inout [Session.ID: CompletedTurn]) {
        var record = records[url] ?? Record(instance: instance, cursor: TurnCursor())
        let previous = record.cursor.turn ?? recovering?.turnID
        do {
            try record.cursor.update(url, agent: instance.agent, modifiedSince: recovering == nil ? cutoff : nil)
            let eligible = record.cursor.completions.filter {
                $0.turnID == previous || ($0.timestamp.map { $0 >= startedAt } ?? false)
            }
            if record.session == nil, record.cursor.turn != nil || !eligible.isEmpty {
                record.session = knownSession ?? (instance.agent.isCodex
                    ? (try? Catalog.interactiveSession(id: id, in: instance))
                    : AgentSessions.session(at: url, in: instance, modified: record.cursor.modified))
            }
            if let session = record.session {
                if instance.agent.isCodex, record.cursor.turn != nil || !eligible.isEmpty {
                    var recent = recentCodexRollouts[instance.id] ?? []
                    if recent.first != url.path {
                        recent.removeAll { $0 == url.path }
                        recent.insert(url.path, at: 0)
                        recentCodexRollouts[instance.id] = Array(recent.prefix(Self.recentRolloutLimit))
                    }
                }
                for event in eligible {
                    let time = event.timestamp ?? record.cursor.modified
                    if let old = delivered[session.id], old.turnID == event.turnID || old.completedAt > time { continue }
                    let result = CompletedTurn(session: session, turnID: event.turnID, completedAt: time)
                    delivered[session.id] = result
                    completed[session.id] = result
                }
            }
            records[url] = record
        } catch {
            records.removeValue(forKey: url)
        }
    }

    nonisolated static func threadID(in path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { return nil }
        var stem = name.dropLast(6)
        // Resumed Cockpit rollouts use <thread UUID>_<rollout UUID>.
        if stem.count > 37, stem.dropLast(36).last == "_",
           UUID(uuidString: String(stem.suffix(36))) != nil {
            stem = stem.dropLast(37)
        }
        let uuid = String(stem.suffix(36))
        if UUID(uuidString: uuid) != nil { return uuid }
        if let range = stem.range(of: "-thr_", options: .backwards) {
            let id = String(stem[stem.index(after: range.lowerBound)...])
            if Catalog.isThreadID(id) { return id }
        }
        return nil
    }
}
