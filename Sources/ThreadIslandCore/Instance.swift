import Foundation

public struct Instance: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case standard, cockpit, custom
    }

    public var id: String { root.path }
    public var name: String
    public let root: URL
    public let kind: Kind

    public init(name: String, root: URL, kind: Kind) {
        self.name = name
        self.root = Self.canonical(root)
        self.kind = kind
    }

    public static func canonical(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }
}

public enum Discovery {
    private struct Registry: Decodable {
        struct Profile: Decodable {
            let id: String
            let name: String
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
            if let data = try? Data(contentsOf: dataRoot.appending(path: "codex_instances.json")),
               let registry = try? JSONDecoder().decode(Registry.self, from: data) {
                for item in registry.instances {
                    let path = NSString(string: item.userDataDir).expandingTildeInPath
                    guard path.hasPrefix("/") else { continue }
                    add(Instance(name: "Cockpit · " + (item.name.isEmpty ? String(item.id.prefix(8)) : item.name),
                                 root: URL(fileURLWithPath: path), kind: .cockpit))
                }
            }

            let parent = dataRoot.appending(path: "instances/codex")
            let directories = (try? FileManager.default.contentsOfDirectory(
                at: parent, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )) ?? []
            for root in directories.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                add(Instance(name: "Cockpit · \(root.lastPathComponent.prefix(8))", root: root, kind: .cockpit))
            }
        }

        if let root = environment["CODEX_HOME"], !root.isEmpty {
            add(Instance(name: "自定义 Codex", root: URL(fileURLWithPath: NSString(string: root).expandingTildeInPath),
                         kind: .custom))
        }
        return found
    }
}
