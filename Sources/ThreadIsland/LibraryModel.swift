import AppKit
import Observation
import ThreadIslandCore
import UniformTypeIdentifiers

struct IslandSession: Equatable, Identifiable {
    let session: Session
    let label: String
    let running: Bool
    let ready: Bool
    var id: Session.ID { session.id }
}

@MainActor @Observable
final class LibraryModel {
    private struct LiveState: Codable, Equatable {
        var tracking: [TrackedTurn] = []
        var pending: [Session.ID: CompletedTurn] = [:]
        var labels = IslandLabels()
    }

    var instances: [Instance] = []
    var onInstancesChanged: (([Instance]) -> Void)?
    var enabled: Set<String> = []
    var source: String?
    var query = "" { didSet { if query != oldValue { limit = 40; refresh(delay: .milliseconds(150)) } } }
    var sessions: [Session] = []
    var selected: Session.ID?
    var detail: Session?
    var transcript: Transcript?
    var loadingDetail = false
    var detailError: String?
    var settings = false
    var loading = false
    var canLoadMore = false
    var issues: [String: String] = [:]
    var notice: String?
    var desktopAvailable = false
    var shortcutConflicts: [String] = []
    private var avatarRevision = 0
    @ObservationIgnored private let avatarStore = SessionAvatars()
    @ObservationIgnored private var avatarCache: [Session.ID: SessionAvatar] = [:]
    private(set) var islandSessions: [IslandSession] = []
    var onIslandChanged: (() -> Void)?
    @ObservationIgnored private var liveState = LiveState()
    @ObservationIgnored private var running: [Session] = []

    var trackedTurns: [TrackedTurn] { liveState.tracking }

    func avatar(for session: Session) -> SessionAvatar {
        _ = avatarRevision
        if let choice = avatarCache[session.id] { return choice }
        let choice = avatarStore.avatar(for: session.id)
        avatarCache[session.id] = choice
        return choice
    }

    func reloadAvatars() {
        avatarCache.removeAll(keepingCapacity: true)
        avatarRevision += 1
        onIslandChanged?()
    }

    func updateLive(_ update: LiveUpdate) {
        let sessions = update.running.map(\.session)
        let tracking = update.running.map(\.trackedTurn)
        guard running != sessions || liveState.tracking != tracking || !update.completed.isEmpty else { return }
        let previous = liveState
        running = sessions
        liveState.tracking = tracking
        for result in update.completed {
            if let current = liveState.pending[result.session.id], current.completedAt > result.completedAt { continue }
            liveState.pending[result.session.id] = result
        }
        updateIsland()
        persistLive(ifChangedFrom: previous)
    }

    func pendingResult(for session: Session) -> CompletedTurn? { liveState.pending[session.id] }

    func markViewed(_ result: CompletedTurn?) {
        guard let result, liveState.pending[result.session.id]?.turnID == result.turnID else { return }
        let previous = liveState
        liveState.pending.removeValue(forKey: result.session.id)
        updateIsland()
        persistLive(ifChangedFrom: previous)
        onIslandChanged?()
    }

    private func updateIsland(preservingTracked: Bool = false) {
        let runningIDs = Set(running.map(\.id))
        let ready = liveState.pending.values.filter {
            enabled.contains($0.session.instance.id) && !runningIDs.contains($0.session.id)
        }.sorted { $0.completedAt < $1.completedAt }
        let candidates = running + ready.map(\.session)
        var labels = liveState.labels
        let items = labels.ordered(candidates)
        // Keep the previous order until startup has had a chance to recover running turns.
        if !preservingTracked { liveState.labels = labels }
        islandSessions = items.map { session, label in
            IslandSession(session: session, label: label, running: runningIDs.contains(session.id),
                          ready: !runningIDs.contains(session.id))
        }
    }

    private func persistLive(ifChangedFrom previous: LiveState) {
        guard liveState != previous, let data = try? JSONEncoder().encode(liveState) else { return }
        defaults.set(data, forKey: "liveState")
    }

    func chooseAvatar(_ avatar: SessionAvatar?, for session: Session) {
        do {
            try avatarStore.set(avatar, for: session.id)
            reloadAvatars()
            notice = nil
        } catch {
            notice = error.localizedDescription
        }
    }

    func importAvatar(for session: Session) {
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.image]
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        picker.prompt = "使用图片"
        picker.directoryURL = session.directory.map { URL(fileURLWithPath: $0, isDirectory: true) }
        guard picker.runModal() == .OK, let file = picker.url else { return }
        do {
            chooseAvatar(try SessionAvatars.rasterize(file), for: session)
        } catch {
            notice = error.localizedDescription
        }
    }

    func installAvatarSkill() {
        do {
            _ = try AvatarAgent.installSkill()
            notice = "已安装。可以在新的 Codex 会话中使用 ZooCove 头像技能。"
        } catch {
            notice = error.localizedDescription
        }
    }

    private var displayedQuery: String?
    private var displayedSource: String?
    @ObservationIgnored private var visible = false
    @ObservationIgnored private var limit = 40
    @ObservationIgnored private let watcher = CatalogWatcher()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var custom: [Instance] = []

    init() {
        if let data = defaults.data(forKey: "liveState"),
           let saved = try? JSONDecoder().decode(LiveState.self, from: data) {
            liveState = saved
        }
        if let stored = defaults.data(forKey: "customInstances"),
           let list = try? JSONDecoder().decode([Instance].self, from: stored) { custom = list }
        updateInstances()
        if let stored = defaults.stringArray(forKey: "enabledInstances") {
            enabled = Set(stored)
        } else {
            enabled = Set(instances.map(\.id))
        }
        updateIsland(preservingTracked: true)
    }

    var chosenSession: Session? {
        if let detail { return detail }
        guard displayedQuery == query, displayedSource == source else { return nil }
        return displayedSessions.first { $0.id == selected } ?? displayedSessions.first
    }

    var displayedSessions: [Session] {
        let catalogIDs = Set(sessions.map(\.id))
        let foreground = islandSessions.filter { item in
            (source == nil || item.id.instanceID == source) && (query.isEmpty || catalogIDs.contains(item.id))
        }
        let priority = (foreground.filter(\.ready) + foreground.filter(\.running)).map(\.session)
        let featured = Set(priority.map(\.id))
        return priority + sessions.filter {
            enabled.contains($0.instance.id) && (source == nil || $0.instance.id == source) && !featured.contains($0.id)
        }
    }

    var activeInstances: [Instance] { instances.filter { enabled.contains($0.id) } }

    var panelHeight: CGFloat {
        let maximum = ExpandedIslandLayout.maxBodyHeight
        if settings {
            let messages = notice == nil ? 0 : 28
            return min(maximum, CGFloat(126 + instances.count * 50 + messages))
        }
        if detail != nil { return maximum }
        let rows = min(displayedSessions.count, 8)
        return min(maximum, CGFloat(max(126, 86 + rows * 49 + (canLoadMore ? 36 : 0))))
    }

    func didOpen() {
        visible = true
        notice = nil
        refresh()
        watch()
    }

    func didClose() {
        visible = false
        watcher.stop()
        refreshTask?.cancel()
        detailTask?.cancel()
        detail = nil
        transcript = nil
        settings = false
        loading = false
    }

    func selectSource(_ id: String?) {
        guard id != source else { return }
        source = id
        selected = nil
        limit = 40
        refresh()
    }

    func toggleInstance(_ instance: Instance) {
        if !enabled.insert(instance.id).inserted { enabled.remove(instance.id) }
        if source == instance.id, !enabled.contains(instance.id) { source = nil }
        persist()
        watch()
        refresh()
    }

    func detectInstances() {
        let previous = Set(instances.map(\.id))
        updateInstances()
        enabled.formUnion(Set(instances.map(\.id)).subtracting(previous))
        persist()
        watch()
        refresh()
    }

    func addInstance() {
        let picker = NSOpenPanel()
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false
        picker.showsHiddenFiles = true
        picker.prompt = "添加实例"
        picker.message = "选择包含 state_*.sqlite 或 session_index.jsonl 的 CODEX_HOME 目录。"
        let answer = picker.runModal()
        guard answer == .OK, let root = picker.url else { return }
        let instance = Instance(name: root.lastPathComponent, root: root, kind: .custom)
        guard Catalog.exists(for: instance) else {
            notice = "这个文件夹里找不到 Codex 会话索引。"
            return
        }
        if !instances.contains(where: { $0.id == instance.id }) {
            custom.append(instance)
            updateInstances()
        }
        enabled.insert(instance.id)
        persist()
        watch()
        refresh()
        notice = "已启用 \(instances.first(where: { $0.id == instance.id })?.name ?? instance.name)。"
    }

    func forget(_ instance: Instance) {
        custom.removeAll { $0.id == instance.id }
        enabled.remove(instance.id)
        let previous = liveState
        liveState.pending = liveState.pending.filter { $0.key.instanceID != instance.id }
        liveState.tracking.removeAll { $0.id.instanceID == instance.id }
        if source == instance.id { source = nil }
        updateInstances()
        persist()
        persistLive(ifChangedFrom: previous)
        watch()
        refresh()
    }

    func loadMore() {
        guard canLoadMore else { return }
        limit = min(limit + 40, 200)
        refresh()
    }

    func moveSelection(by offset: Int) {
        let rows = displayedSessions
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex(where: { $0.id == selected }) ?? 0
        selected = rows[max(0, min(rows.count - 1, current + offset))].id
    }

    func show(_ session: Session) {
        detail = session
        transcript = nil
        detailError = nil
        loadingDetail = true
        notice = nil
        updateDesktopStatus(session)
        detailTask?.cancel()
        detailTask = Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try Transcript.read(session) } }.value
            guard !Task.isCancelled else { return }
            loadingDetail = false
            switch result {
            case .success(let result): transcript = result
            case .failure: detailError = "这个会话的记录文件暂时无法读取。"
            }
        }
    }

    func back() {
        detailTask?.cancel()
        detail = nil
        transcript = nil
        notice = nil
    }

    func copyCommand(_ session: Session) {
        guard let command = SessionLink.terminalCommand(for: session) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        notice = "已复制适用于「\(session.instance.name)」的恢复命令。"
    }

    func updateDesktopStatus(_ session: Session) {
        desktopAvailable = (try? DesktopRouter.destination(for: session.instance)) != nil
    }

    func openDesktop(_ session: Session) {
        let result = pendingResult(for: session)
        Task {
            do {
                try await DesktopRouter.open(session)
                markViewed(result)
                notice = "已将会话链接发送给「\(session.instance.name)」。"
            } catch { notice = error.localizedDescription }
        }
    }

    private func updateInstances() {
        var roots: Set<String> = []
        instances = (Discovery.instances() + custom).filter { roots.insert($0.id).inserted }
    }

    private func persist() {
        defaults.set(Array(enabled).sorted(), forKey: "enabledInstances")
        let previous = liveState
        running.removeAll { !enabled.contains($0.instance.id) }
        updateIsland()
        persistLive(ifChangedFrom: previous)
        onIslandChanged?()
        onInstancesChanged?(activeInstances)
        if let data = try? JSONEncoder().encode(custom) { defaults.set(data, forKey: "customInstances") }
    }

    private func watch() {
        guard visible else { return }
        watcher.start(instances: instances.filter { enabled.contains($0.id) }) { [weak self] in
            self?.refresh(delay: .milliseconds(250))
        }
    }

    private func refresh(delay: Duration? = nil) {
        guard visible else { return }
        refreshTask?.cancel()
        let inputs = instances.filter { enabled.contains($0.id) && (source == nil || source == $0.id) }
        let search = query
        let limit = limit
        if delay == nil && sessions.isEmpty { loading = true }
        refreshTask = Task {
            if let delay { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }

            let result = await Task.detached(priority: .userInitiated) { () -> ([Session], [String: String], Bool) in
                var rows: [Session] = []
                var errors: [String: String] = [:]
                var more = false
                for instance in inputs {
                    do {
                        let page = try Catalog.sessions(in: instance, matching: search, limit: limit + 1)
                        more = more || page.count > limit
                        rows.append(contentsOf: page.prefix(limit))
                    } catch { errors[instance.id] = error.localizedDescription }
                }
                let ordered = rows.sorted {
                    if $0.updated != $1.updated { return $0.updated > $1.updated }
                    if $0.instance.id != $1.instance.id { return $0.instance.id < $1.instance.id }
                    return $0.threadID > $1.threadID
                }
                return (ordered, errors, more && limit < 200)
            }.value

            guard !Task.isCancelled else { return }
            let selected = self.selected
            displayedQuery = search
            displayedSource = source
            sessions = result.0
            issues = result.1
            canLoadMore = result.2
            let rows = displayedSessions
            if !rows.contains(where: { $0.id == selected }) { self.selected = rows.first?.id }
            loading = false
        }
    }
}
