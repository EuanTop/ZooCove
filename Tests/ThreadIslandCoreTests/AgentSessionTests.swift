import Foundation
import Testing
@testable import ThreadIslandCore

private let agentSessionID = "20000000-1234-4234-8234-123456789abc"

private struct AgentFixture {
    let home: URL
    let claude: Instance
    let pi: Instance
    let claudeFile: URL
    let piFile: URL

    init() throws {
        home = Instance.canonical(FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        claude = Instance(name: "Claude Code", root: home.appending(path: ".claude"), kind: .claudeCode)
        pi = Instance(name: "Pi Agent", root: home.appending(path: ".pi/agent"), kind: .pi)
        claudeFile = claude.sessionDirectory.appending(path: "project/\(agentSessionID).jsonl")
        piFile = pi.sessionDirectory.appending(path: "--test--/2026-11-15T12-00-00_\(agentSessionID).jsonl")
        for file in [claudeFile, piFile] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        }
        try write([
            "{\"type\":\"user\",\"sessionId\":\"\(agentSessionID)\",\"uuid\":\"claude-turn\",\"cwd\":\"/tmp/claude-demo\",\"message\":{\"role\":\"user\",\"content\":\"Claude synthetic question\"}}",
            #"{"type":"assistant","isSidechain":true,"message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Hidden subagent"}]}}"#
        ], to: claudeFile)
        try write([
            "{\"type\":\"session\",\"version\":3,\"id\":\"\(agentSessionID)\",\"cwd\":\"/tmp/pi-demo\"}",
            #"{"type":"message","id":"pi-turn","parentId":null,"message":{"role":"user","content":"Pi synthetic question"}}"#,
            #"{"type":"message","id":"tool","parentId":"pi-turn","message":{"role":"assistant","stopReason":"toolUse","content":[{"type":"toolCall","name":"read"}]}}"#
        ], to: piFile)
    }

    func write(_ lines: [String], to file: URL) throws {
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
    }

    func append(_ line: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    func remove() { try? FileManager.default.removeItem(at: home) }
}

@Test func discoversCLIProfilesAndResumesTheCorrectSession() throws {
    let fixture = try AgentFixture()
    defer { fixture.remove() }

    let instances = Discovery.instances(home: fixture.home, environment: [:])
    #expect(instances.map(\.kind) == [.claudeCode, .pi])
    let claudeLookup = try Catalog.session(id: agentSessionID, in: fixture.claude)
    let claude = try #require(claudeLookup)
    let pi = try #require(Catalog.sessions(in: fixture.pi, matching: "Pi synthetic").first)
    #expect(claude.id != pi.id)
    #expect(try Transcript.read(claude).messages.map(\.text) == ["Claude synthetic question"])
    #expect(SessionLink.terminalCommand(for: claude)?.contains("claude --resume '\(agentSessionID)'") == true)
    #expect(SessionLink.terminalCommand(for: pi)?.hasSuffix("pi --session '\(fixture.piFile.path)'") == true)

    let wrongProfile = Session(instance: fixture.claude, threadID: pi.threadID, title: pi.title,
                               directory: pi.directory, updated: pi.updated, rolloutPath: pi.rolloutPath)
    #expect(throws: CatalogError.self) { try Transcript.read(wrongProfile) }
    #expect(SessionLink.terminalCommand(for: wrongProfile) == nil)
}

@Test func cliToolCallsStayRunningAndOnlySuccessfulRepliesComplete() async throws {
    let fixture = try AgentFixture()
    defer { fixture.remove() }

    let tracker = LiveSessions()
    let instances = [fixture.claude, fixture.pi]
    let started = await tracker.update(instances: instances, paths: [fixture.claudeFile.path, fixture.piFile.path], seed: false)
    #expect(Set(started.running.map(\.session.instance.kind)) == [.claudeCode, .pi])
    #expect(started.completed.isEmpty)

    try fixture.append(#"{"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use"}}"#,
                       to: fixture.claudeFile)
    try fixture.append(#"{"type":"message","id":"result","parentId":"tool","message":{"role":"toolResult","content":"A tool result"}}"#,
                       to: fixture.piFile)
    let afterTools = await tracker.update(instances: instances, paths: [fixture.claudeFile.path, fixture.piFile.path], seed: false)
    #expect(afterTools.running.count == 2)
    #expect(afterTools.completed.isEmpty)

    try fixture.append(#"{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Claude reply"}]}}"#,
                       to: fixture.claudeFile)
    try fixture.append(#"{"type":"message","id":"abort","parentId":"result","message":{"role":"assistant","stopReason":"aborted","content":[]}}"#,
                       to: fixture.piFile)
    let first = await tracker.update(instances: instances, paths: [fixture.claudeFile.path, fixture.piFile.path], seed: false)
    #expect(first.running.isEmpty)
    #expect(first.completed.map(\.session.instance.kind) == [.claudeCode])
    #expect(first.completed.map(\.turnID) == ["claude-turn"])

    try fixture.append(#"{"type":"message","id":"retry","parentId":"pi-turn","message":{"role":"user","content":"Try another branch"}}"#,
                       to: fixture.piFile)
    try fixture.append(#"{"type":"message","id":"final","parentId":"retry","message":{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"Pi reply"}]}}"#,
                       to: fixture.piFile)
    // A filesystem event can deliver both the prompt and stop in one update.
    let timestamped = ISO8601DateFormatter().string(from: Date.now.addingTimeInterval(1))
    try fixture.append("{\"type\":\"message\",\"id\":\"newturn\",\"parentId\":\"final\",\"timestamp\":\"\(timestamped)\",\"message\":{\"role\":\"user\",\"content\":\"Next Pi prompt\"}}",
                       to: fixture.piFile)
    try fixture.append("{\"type\":\"message\",\"id\":\"next\",\"parentId\":\"newturn\",\"timestamp\":\"\(timestamped)\",\"message\":{\"role\":\"assistant\",\"stopReason\":\"stop\",\"content\":[{\"type\":\"text\",\"text\":\"Next Pi reply\"}]}}",
                       to: fixture.piFile)
    let second = await tracker.update(instances: instances, paths: [fixture.piFile.path], seed: false)
    #expect(second.running.isEmpty)
    #expect(second.completed.map(\.turnID) == ["newturn"])
    let piLookup = try Catalog.session(id: agentSessionID, in: fixture.pi)
    let pi = try #require(piLookup)
    #expect(try Transcript.read(pi).messages.map(\.text) ==
            ["Pi synthetic question", "Try another branch", "Pi reply", "Next Pi prompt", "Next Pi reply"])
}

@Test func cockpitClaudeStaysSeparateFromTheDefaultProfile() async throws {
    let fixture = try AgentFixture()
    defer { fixture.remove() }

    let cockpit = fixture.home.appending(path: ".antigravity_cockpit")
    let managedRoot = cockpit.appending(path: "instances/claude/managed-profile")
    let managedFile = managedRoot.appending(path: "projects/project/\(agentSessionID).jsonl")
    try FileManager.default.createDirectory(at: managedFile.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: fixture.claudeFile, to: managedFile)
    try FileManager.default.createSymbolicLink(at: fixture.home.appending(path: ".cockpit_tools"),
                                             withDestinationURL: cockpit)
    let registry = ["instances": [["id": "managed-profile", "name": "Studio", "userDataDir": managedRoot.path]]]
    try JSONSerialization.data(withJSONObject: registry).write(to: cockpit.appending(path: "claude_instances.json"))

    let instances = Discovery.instances(home: fixture.home, environment: [:])
    let claudeProfiles = instances.filter { $0.agent == .claudeCode }
    #expect(claudeProfiles.count == 2)
    let managed = try #require(claudeProfiles.first { $0.origin == .cockpit })
    #expect(managed.name == "Cockpit · Claude Code · Studio")
    #expect(managed.root.path == managedRoot.path)
    let standard = try #require(claudeProfiles.first { $0.origin == .standard })
    let managedLookup = try Catalog.session(id: agentSessionID, in: managed)
    let standardLookup = try Catalog.session(id: agentSessionID, in: standard)
    let managedSession = try #require(managedLookup)
    let standardSession = try #require(standardLookup)
    #expect(managedSession.id != standardSession.id)
    #expect(SessionLink.terminalCommand(for: managedSession)?.contains("CLAUDE_CONFIG_DIR='\(managedRoot.path)' claude --resume") == true)
    #expect(try JSONDecoder().decode(Instance.self, from: JSONEncoder().encode(managed)).origin == .cockpit)
    let legacy = Instance(name: "Claude Code", root: standard.root, kind: .claudeCode)
    #expect(try JSONDecoder().decode(Instance.self, from: JSONEncoder().encode(legacy)).origin == .standard)

    let tracker = LiveSessions()
    let first = await tracker.update(instances: instances, paths: [managedFile.path, fixture.claudeFile.path], seed: false)
    #expect(Set(first.running.map(\.session.instance.origin)) == [.standard, .cockpit])
    try fixture.append(#"{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Managed reply"}]}}"#,
                       to: managedFile)
    let second = await tracker.update(instances: instances, paths: [managedFile.path], seed: false)
    #expect(second.running.map(\.id) == [standardSession.id])
    #expect(second.completed.map(\.session.id) == [managedSession.id])
}
