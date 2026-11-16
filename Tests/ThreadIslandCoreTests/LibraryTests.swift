import Foundation
import SQLite3
import Testing
@testable import ThreadIslandCore

@Test func hotkeyCycleFollowsVisibleOrderAfterACompletedIconIsRemoved() {
    let left = Session.ID(instanceID: "default", threadID: "left")
    let middle = Session.ID(instanceID: "default", threadID: "middle")
    let right = Session.ID(instanceID: "cockpit", threadID: "right")
    var cycle = IslandCycle()
    let order = [left, middle, right]
    #expect(cycle.next(in: order) == left)
    cycle.selected(middle, in: order)
    #expect(cycle.next(in: order) == right)
    #expect(cycle.next(in: [left, right]) == right)
    cycle.selected(right, in: [left, right])
    #expect(cycle.next(in: [left, right]) == left)
    #expect(cycle.next(in: []) == nil)
}

private let duplicatedID = "12345678-1234-4234-8234-123456789abc"
private let otherID = "12345678-1234-4234-8234-123456789abd"

@Test func sameThreadInTwoInstancesKeepsBothOrigins() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let standard = fixture.instance("default", kind: .standard)
    let cockpit = fixture.instance("cockpit", kind: .cockpit)
    try fixture.makeCatalog(standard, title: "Standard 100%")
    try fixture.makeCatalog(cockpit, title: "Cockpit chat")
    let defaultRows = try Catalog.sessions(in: standard)
    let alternateRows = try Catalog.sessions(in: cockpit)
    #expect(defaultRows.count == 1)
    #expect(alternateRows.count == 1)
    #expect(defaultRows.first?.threadID == alternateRows.first?.threadID)
    #expect(defaultRows.first?.id != alternateRows.first?.id)
    #expect(try Catalog.sessions(in: standard, matching: "%").count == 1)
    #expect(try Catalog.sessions(in: cockpit, matching: "%").isEmpty)
    #expect(try Catalog.session(id: otherID, in: cockpit)?.title == "Archived")
    #expect(try Catalog.sessions(in: cockpit, offset: 1).isEmpty)
}

@Test func fallbackIndexRetainsLatestEntryAndDiscoveryDeduplicatesSymlinks() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let home = fixture.root
    let homeDir = home.appending(path: ".codex")
    try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)
    let index = """
        {"id":"\(duplicatedID)","thread_name":"Newer","updated_at":"2026-11-15T12:00:00.000Z"}
        {"id":"\(duplicatedID)","thread_name":"Older","updated_at":"2026-11-15T11:00:00Z"}
        bad record
        """
    try index.write(to: homeDir.appending(path: "session_index.jsonl"), atomically: true, encoding: .utf8)
    let alias = home.appending(path: "alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: homeDir)
    let instances = Discovery.instances(home: home, environment: ["CODEX_HOME": alias.path])
    #expect(instances.count == 1)
    let instance = try #require(instances.first)
    #expect(try Catalog.sessions(in: instance).map(\.title) == ["Newer"])
}

@Test func transcriptIsScopedAndCommandsAreQuoted() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let first = fixture.instance("first's home", kind: .custom)
    let other = fixture.instance("alternate", kind: .cockpit)
    let records = other.root.appending(path: "sessions/2026/11/15")
    try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
    let file = records.appending(path: "rollout.jsonl")
    let json = """
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"text":"Question"}]}}
        {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"text":"Answer"}]}}
        {"type":"response_item","payload":{"type":"message","role":"developer","content":[{"text":"Excluded"}]}}
        """
    try json.write(to: file, atomically: true, encoding: .utf8)
    let external = Session(instance: first, threadID: duplicatedID, title: "Example", directory: nil,
                           updated: .now, rolloutPath: file.path)
    let own = Session(instance: other, threadID: duplicatedID, title: "Example", directory: nil,
                      updated: .now, rolloutPath: file.path)
    #expect(throws: CatalogError.self) { try Transcript.read(external) }
    #expect(try Transcript.read(own).messages.map(\.text) == ["Question", "Answer"])
    #expect(SessionLink.terminalCommand(for: external)?.contains("first'\\''s home") == true)
    #expect(SessionLink.desktopURL(for: "evil?id=1") == nil)
}

private struct Fixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
    func instance(_ name: String, kind: Instance.Kind) -> Instance {
        Instance(name: name, root: root.appending(path: name), kind: kind)
    }

    func makeCatalog(_ instance: Instance, title: String) throws {
        try FileManager.default.createDirectory(at: instance.root, withIntermediateDirectories: true)
        let dbURL = instance.root.appending(path: "state_5.sqlite")
        var db: OpaquePointer?
        try #require(sqlite3_open(dbURL.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
            CREATE TABLE threads(id TEXT PRIMARY KEY, name TEXT, title TEXT, cwd TEXT, rollout_path TEXT,
                                 updated_at_ms INTEGER, recency_at_ms INTEGER, archived INTEGER,
                                 has_user_event INTEGER, source TEXT);
            INSERT INTO threads VALUES ('\(duplicatedID)', NULL, '\(title)', '/tmp/work', NULL,
                                        100, 100, 0, 0, 'cli');
            INSERT INTO threads VALUES ('\(otherID)', NULL, 'Archived', NULL, NULL, 10, 10, 1, 1, 'cli');
            """
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }
}

@Test func importedAbsolutePathReadsTheSelectedInstancesCopy() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let source = fixture.instance("source", kind: .standard)
    let importTarget = fixture.instance("import", kind: .cockpit)
    let relative = "sessions/2026/11/15/rollout-2026-11-15T14-00-00-\(duplicatedID).jsonl"
    let original = source.root.appending(path: relative)
    let copy = importTarget.root.appending(path: relative)
    for (url, message) in [(original, "Original"), (copy, "Imported copy")] {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = """
            {"type":"event_msg","payload":{"type":"user_message","message":"\(message)"}}
            """
        try line.write(to: url, atomically: true, encoding: .utf8)
    }
    let item = Session(instance: importTarget, threadID: duplicatedID, title: "Imported", directory: nil,
                       updated: .now, rolloutPath: original.path)
    #expect(try Transcript.read(item).messages.map(\.text) == ["Imported copy"])
    try FileManager.default.removeItem(at: copy)
    #expect(throws: CatalogError.self) { try Transcript.read(item) }
}

@Test func liveIconsTrackEachInstanceAndDisappearOnCompletion() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let standard = fixture.instance("default", kind: .standard)
    let cockpit = fixture.instance("cockpit", kind: .cockpit)
    try fixture.makeCatalog(standard, title: "Default working")
    try fixture.makeCatalog(cockpit, title: "Cockpit working")

    func rollout(_ instance: Instance) throws -> URL {
        let directory = instance.root.appending(path: "sessions/2026/11/15")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suffix = instance.kind == .cockpit ? "_\(otherID)" : ""
        let file = directory.appending(path: "rollout-2026-11-15T15-00-00-\(duplicatedID)\(suffix).jsonl")
        try Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"turn-1\"}}\n".utf8)
            .write(to: file)
        return file
    }
    let first = try rollout(standard)
    let second = try rollout(cockpit)
    let tracker = LiveSessions()
    let instances = [standard, cockpit]
    let started = await tracker.update(instances: instances, paths: [first.path, second.path], seed: false)
    #expect(Set(started.running.map(\.session.instance.id)) == Set(instances.map(\.id)))
    #expect(Set(started.running.map(\.session.threadID)) == [duplicatedID])
    #expect(Set(started.running.map(\.id)).count == 2)

    let handle = try FileHandle(forWritingTo: second)
    defer { try? handle.close() }
    try handle.seekToEnd()
    let longMessage = String(repeating: "a", count: 900)
    let ending = """
        {"type":"event_msg","payload":{"last_agent_message":"\(longMessage)","type":"task_complete","turn_id":"turn-1"}}
        """
    try handle.write(contentsOf: Data(ending.utf8))
    let partial = await tracker.update(instances: instances, paths: [second.path], seed: false)
    #expect(partial.running.count == 2)
    #expect(partial.completed.isEmpty)
    try handle.write(contentsOf: Data([10]))
    let finished = await tracker.update(instances: instances, paths: [second.path], seed: false)
    #expect(finished.running.map(\.session.instance.id) == [standard.id])
    #expect(finished.completed.map(\.session.instance.id) == [cockpit.id])
    #expect(finished.completed.map(\.turnID) == ["turn-1"])

    let recovered = await LiveSessions().update(instances: instances, paths: [second.path], seed: true,
                                                recovering: started.running.map(\.trackedTurn))
    #expect(recovered.completed.map(\.session.instance.id) == [cockpit.id])
    let historical = await LiveSessions().update(instances: instances, paths: [second.path], seed: true)
    #expect(historical.completed.isEmpty)

    let cancelled = try FileHandle(forWritingTo: first)
    defer { try? cancelled.close() }
    try cancelled.seekToEnd()
    try cancelled.write(contentsOf: Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"turn_aborted\",\"turn_id\":\"turn-1\"}}\n".utf8))
    let stopped = await tracker.update(instances: instances, paths: [first.path], seed: false)
    #expect(stopped.running.isEmpty)
    #expect(stopped.completed.isEmpty)
}

@Test func idleCodexRolloutRemainsWatchedAcrossTurns() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let cockpit = fixture.instance("cockpit", kind: .cockpit)
    try fixture.makeCatalog(cockpit, title: "Existing chat")
    let directory = cockpit.sessionDirectory.appending(path: "2026/11/15")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appending(path: "rollout-2026-11-15T15-00-00-\(duplicatedID)_\(otherID).jsonl")
    try Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"earlier\"}}\n".utf8)
        .write(to: file)
    try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-3_600)],
                                          ofItemAtPath: file.path)
    var database: OpaquePointer?
    try #require(sqlite3_open(cockpit.root.appending(path: "state_5.sqlite").path, &database) == SQLITE_OK)
    defer { sqlite3_close(database) }
    let sql = "UPDATE threads SET rollout_path = '\(file.path)' WHERE id = '\(duplicatedID)'"
    try #require(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)

    let monitor = LiveSessions()
    let idle = await monitor.update(instances: [cockpit], paths: [], seed: true)
    #expect(idle.running.isEmpty && idle.completed.isEmpty)
    #expect(idle.watchedRollouts == [file.path])

    let writer = try FileHandle(forWritingTo: file)
    defer { try? writer.close() }
    try writer.seekToEnd()
    try writer.write(contentsOf: Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"next\"}}\n".utf8))
    let started = await monitor.update(instances: [cockpit], paths: [file.path], seed: false)
    #expect(started.running.map(\.turnID) == ["next"])

    try writer.write(contentsOf: Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"next\"}}\n".utf8))
    let completed = await monitor.update(instances: [cockpit], paths: [file.path], seed: false)
    #expect(completed.running.isEmpty)
    #expect(completed.completed.map(\.turnID) == ["next"])
    #expect(completed.watchedRollouts == [file.path])

    let disabled = await monitor.update(instances: [], paths: [file.path], seed: false)
    #expect(disabled.watchedRollouts.isEmpty)
}

@Test func islandLabelsDisambiguateSameProjectWithoutRenamingVisibleResults() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let standard = fixture.instance("default", kind: .standard)
    let cockpit = fixture.instance("cockpit", kind: .cockpit)
    let first = Session(instance: standard, threadID: duplicatedID, title: "VisBloom/main",
                        directory: "/work/artworks", updated: .now, rolloutPath: nil)
    let second = Session(instance: cockpit, threadID: duplicatedID, title: "发布流程",
                         directory: "/work/artworks", updated: .now, rolloutPath: nil)
    var labels = IslandLabels()
    #expect(labels.ordered([first]).map { $0.1 } == ["artworks"])
    #expect(labels.ordered([second, first]).map { $0.1 } == ["VisBloom", "发布流程"])
    let data = try JSONEncoder().encode(labels)
    var restored = try JSONDecoder().decode(IslandLabels.self, from: data)
    #expect(restored.ordered([first]).map { $0.1 } == ["VisBloom"])
    #expect(restored.ordered([]).isEmpty)
    #expect(restored.ordered([first]).map { $0.1 } == ["artworks"])

    let duplicateTitle = Session(instance: cockpit, threadID: otherID, title: first.title,
                                 directory: first.directory, updated: .now, rolloutPath: nil)
    #expect(restored.ordered([first, duplicateTitle]).map { $0.1 } == ["VisBloom", "VisBloom 2"])
}

@Test func largeUnterminatedRolloutLineDoesNotCrashTheCursor() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let file = fixture.root.appending(path: "oversize.jsonl")
    var bytes = Data(repeating: 97, count: 2 * 1_024 * 1_024 + 20)
    bytes.append(10)
    try bytes.write(to: file)
    var cursor = TurnCursor()
    try cursor.update(file)
    #expect(cursor.turn == nil)
}
