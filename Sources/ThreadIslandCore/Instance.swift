import Foundation

public struct Instance: Codable, Hashable, Identifiable, Sendable {
    public enum Agent: String, CaseIterable, Codable, Sendable {
        case codex, claudeCode, pi

        public var isCodex: Bool { self == .codex }

        public var name: String {
            switch self {
            case .codex: "Codex"
            case .claudeCode: "Claude Code"
            case .pi: "Pi Agent"
            }
        }
    }

    public enum Origin: String, Codable, Sendable {
        case standard, cockpit, custom
    }

    // Keep the original persisted kind so existing preferences and unread turns decode.
    public enum Kind: String, Codable, Sendable {
        case standard, cockpit, custom, claudeCode, pi

        fileprivate var agent: Agent {
            switch self {
            case .claudeCode: .claudeCode
            case .pi: .pi
            default: .codex
            }
        }

        fileprivate var origin: Origin {
            switch self {
            case .cockpit: .cockpit
            case .custom: .custom
            default: .standard
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case name, root, kind
        case originOverride = "origin"
    }

    public var id: String { root.path }
    public var name: String
    public let root: URL
    public let kind: Kind
    private let originOverride: Origin?
    public var agent: Agent { kind.agent }
    public var origin: Origin { originOverride ?? kind.origin }

    public var sessionDirectory: URL {
        root.appending(path: agent == .claudeCode ? "projects" : "sessions")
    }

    public init(name: String, root: URL, kind: Kind) {
        self.init(name: name, root: root, agent: kind.agent, origin: kind.origin)
    }

    public init(name: String, root: URL, agent: Agent, origin: Origin) {
        self.name = name
        self.root = Self.canonical(root)
        self.kind = switch (agent, origin) {
        case (.codex, .standard): .standard
        case (.codex, .cockpit): .cockpit
        case (.codex, .custom): .custom
        case (.claudeCode, _): .claudeCode
        case (.pi, _): .pi
        }
        self.originOverride = kind.origin == origin ? nil : origin
    }

    public static func canonical(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }
}

public enum Discovery {
    // A Cockpit registry identifies a profile. Its Agent adapter owns the transcript format.
    private static let cockpitAgents: [(directory: String, agent: Instance.Agent)] = [
        ("codex", .codex),
        ("claude", .claudeCode)
    ]

    private struct Registry: Decodable {
        struct Profile: Decodable {
            let id: String
            let name: String?
            let userDataDir: String
        }

        let instances: [Profile]
    }

    public static func instances(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [Instance] {
        var found: [Instance] = []
        var seen: Set<String> = []
        func add(_ value: Instance) {
            guard Catalog.exists(for: value), seen.insert(value.id).inserted else { return }
            found.append(value)
        }
        add(Instance(name: "默认 Codex", root: home.appending(path: ".codex"), kind: .standard))

        let dataRoots = [environment["COCKPIT_TOOLS_DATA_DIR"]].compactMap { $0 }.map {
            URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath)
        } + [home.appending(path: ".cockpit_tools"), home.appending(path: ".antigravity_cockpit")]
        var readRoots: Set<URL> = []
        for dataRoot in dataRoots.map(Instance.canonical) where readRoots.insert(dataRoot).inserted {
            for (directory, agent) in cockpitAgents {
                let registryURL = dataRoot.appending(path: "\(directory)_instances.json")
                if let data = try? Data(contentsOf: registryURL),
                   let registry = try? JSONDecoder().decode(Registry.self, from: data) {
                    for item in registry.instances {
                        let path = NSString(string: item.userDataDir).expandingTildeInPath
                        guard path.hasPrefix("/") else { continue }
                        let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let label = name.isEmpty ? String(item.id.prefix(8)) : name
                        add(managed(agent, label: label, root: URL(fileURLWithPath: path)))
                    }
                }

                let parent = dataRoot.appending(path: "instances/\(directory)")
                let directories = (try? FileManager.default.contentsOfDirectory(
                    at: parent, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
                )) ?? []
                for root in directories.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    add(managed(agent, label: String(root.lastPathComponent.prefix(8)), root: root))
                }
            }
        }

        if let root = environment["CODEX_HOME"], !root.isEmpty {
            add(Instance(name: "自定义 Codex", root: URL(fileURLWithPath: NSString(string: root).expandingTildeInPath),
                         kind: .custom))
        }
        func addCLI(_ agent: Instance.Agent, path: String, environmentKey: String) {
            add(Instance(name: agent.name, root: home.appending(path: path), agent: agent, origin: .standard))
            guard let value = environment[environmentKey], !value.isEmpty else { return }
            let expanded = NSString(string: value).expandingTildeInPath
            guard expanded.hasPrefix("/") else { return }
            add(Instance(name: "自定义 \(agent.name)", root: URL(fileURLWithPath: expanded),
                         agent: agent, origin: .custom))
        }
        addCLI(.claudeCode, path: ".claude", environmentKey: "CLAUDE_CONFIG_DIR")
        addCLI(.pi, path: ".pi/agent", environmentKey: "PI_CODING_AGENT_DIR")
        return found
    }

    private static func managed(_ agent: Instance.Agent, label: String, root: URL) -> Instance {
        Instance(name: "Cockpit · \(agent.name) · \(label)", root: root, agent: agent, origin: .cockpit)
    }
}
