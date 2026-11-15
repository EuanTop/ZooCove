import Foundation

public struct IslandLabels: Codable, Equatable {
    private var order: [Session.ID] = []
    private var topics: [Session.ID: String] = [:]

    public init() {}

    public mutating func ordered(_ sessions: [Session]) -> [(Session, String)] {
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        order.removeAll { byID[$0] == nil }
        topics = topics.filter { byID[$0.key] != nil }
        var seen = Set(order)
        order.append(contentsOf: sessions.map(\.id).filter { seen.insert($0).inserted })

        let sorted = order.compactMap { byID[$0] }
        let groups = Dictionary(grouping: sorted) { Self.key(Self.project(for: $0)) }
        var used = Set(topics.values.map(Self.key))
        let singleProjects = Set(groups.compactMap { entry in
            entry.value.count == 1 && topics[entry.value[0].id] == nil ? entry.key : nil
        })
        for session in sorted where topics[session.id] == nil {
            let project = Self.project(for: session)
            let peers = (groups[Self.key(project)] ?? []).filter { $0.id != session.id }
            guard !peers.isEmpty || used.contains(Self.key(project)) else { continue }
            let peerTerms = Set(peers.flatMap { Self.terms($0.title).map(Self.key) })
            let terms = Self.terms(session.title)
            let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let firstTerm = terms.first ?? project
            let repeatsTitle = peers.contains {
                Self.key($0.title.trimmingCharacters(in: .whitespacesAndNewlines)) == Self.key(title)
            }
            let distinct = terms.filter { !peerTerms.contains(Self.key($0)) }
            let alternatives = distinct + (repeatsTitle ? [firstTerm] : [title, firstTerm])
            let base = alternatives.first {
                let key = Self.key($0)
                return !$0.isEmpty && !used.contains(key) && !singleProjects.contains(key)
            }
            var label = base ?? firstTerm
            var suffix = 2
            while used.contains(Self.key(label)) || singleProjects.contains(Self.key(label)) {
                label = "\(firstTerm) \(suffix)"
                suffix += 1
            }
            used.insert(Self.key(label))
            topics[session.id] = label
        }
        return sorted.map { ($0, topics[$0.id] ?? Self.project(for: $0)) }
    }

    public static func project(for session: Session) -> String {
        if let directory = session.directory {
            let name = (directory as NSString).lastPathComponent
            if let first = terms(name).first { return first }
        }
        return terms(session.title).first ?? "会话"
    }

    private static func terms(_ title: String) -> [String] {
        title.split { $0.isWhitespace || "-_/:·—–：，。！？｜|（）()[]".contains($0) }.map(String.init)
    }

    private static func key(_ label: String) -> String {
        label.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }
}
