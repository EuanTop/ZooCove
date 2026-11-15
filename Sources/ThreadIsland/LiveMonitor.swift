import CoreServices
import Foundation
import ThreadIslandCore

@MainActor
final class LiveMonitor {
    private let source = LiveSessions()
    private var instances: [Instance] = []
    private var stream: FSEventStreamRef?
    private var activeFiles: [String: DispatchSourceFileSystemObject] = [:]
    private var tasks: Task<Void, Never>?
    private var expire: Task<Void, Never>?
    private var pending: Set<String> = []
    private var needsSeed = false
    private var recovering: [TrackedTurn] = []
    private var generation = 0
    var onChange: ((LiveUpdate) -> Void)?

    func start(_ instances: [Instance], recovering: [TrackedTurn] = []) {
        stop()
        self.instances = instances
        self.recovering = recovering
        let paths = instances.map(\.sessionDirectory.path)
            .filter { FileManager.default.fileExists(atPath: $0) }
        if !paths.isEmpty { watch(paths) }
        refresh(seed: true)
    }

    func stop() {
        generation += 1
        tasks?.cancel()
        tasks = nil
        expire?.cancel()
        expire = nil
        pending.removeAll()
        needsSeed = false
        recovering.removeAll()
        for source in activeFiles.values { source.cancel() }
        activeFiles.removeAll()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    func resync() { refresh(seed: true) }

    private func watch(_ directories: [String]) {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let owner = Unmanaged<LiveMonitor>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            let lostEvents = UnsafeBufferPointer(start: flags, count: count).contains {
                $0 & UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged) != 0
            }
            MainActor.assumeIsolated {
                owner.refresh(paths: Set(paths.filter { $0.hasSuffix(".jsonl") }), seed: lostEvents)
            }
        }
        let flags = kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents |
                    kFSEventStreamCreateFlagWatchRoot
        guard let newStream = FSEventStreamCreate(nil, callback, &context, directories as CFArray,
                                                   FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                                   1.0, FSEventStreamCreateFlags(flags)) else { return }
        stream = newStream
        FSEventStreamSetDispatchQueue(newStream, .main)
        if !FSEventStreamStart(newStream) {
            FSEventStreamInvalidate(newStream)
            FSEventStreamRelease(newStream)
            stream = nil
        }
    }

    private func refresh(paths: Set<String> = [], seed: Bool = false, expireOnly: Bool = false,
                         coalesceWrites: Bool = false) {
        guard !paths.isEmpty || seed || expireOnly else { return }
        pending.formUnion(paths)
        needsSeed = needsSeed || seed
        guard tasks == nil else { return }
        let version = generation
        tasks = Task(priority: .utility) { [weak self] in
            if coalesceWrites { try? await Task.sleep(for: .milliseconds(180)) }
            guard let self, !Task.isCancelled, version == generation else { return }
            repeat {
                let paths = pending
                let seed = needsSeed
                pending.removeAll()
                needsSeed = false
                let recovery = recovering
                recovering.removeAll()
                let result = await source.update(instances: instances, paths: paths, seed: seed, recovering: recovery)
                guard !Task.isCancelled, version == generation else { return }
                watchActiveFiles(result.running)
                onChange?(result)
                scheduleExpiry(result.running)
            } while !pending.isEmpty || needsSeed
            tasks = nil
        }
    }

    private func watchActiveFiles(_ sessions: [RunningSession]) {
        let paths = Set(sessions.map(\.rolloutPath))
        for path in Array(activeFiles.keys) where !paths.contains(path) {
            activeFiles.removeValue(forKey: path)?.cancel()
        }
        for path in paths where activeFiles[path] == nil {
            let descriptor = open(path, O_EVTONLY | O_CLOEXEC)
            guard descriptor >= 0 else { continue }
            let events = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .extend, .rename, .delete, .revoke], queue: .main)
            events.setCancelHandler { close(descriptor) }
            events.setEventHandler { [weak self, weak events] in
                MainActor.assumeIsolated {
                    guard let self, let events, self.activeFiles[path] === events else { return }
                    if !events.data.intersection([.rename, .delete, .revoke]).isEmpty {
                        self.activeFiles.removeValue(forKey: path)?.cancel()
                    }
                    self.refresh(paths: [path], coalesceWrites: true)
                }
            }
            activeFiles[path] = events
            events.activate()
            // Close the gap between reading a new active rollout and attaching its watcher.
            pending.insert(path)
        }
    }

    private func scheduleExpiry(_ sessions: [RunningSession]) {
        expire?.cancel()
        guard let oldest = sessions.map(\.lastActivity).min() else { expire = nil; return }
        let remaining = max(1, LiveSessions.activityTimeout + oldest.timeIntervalSinceNow + 0.1)
        expire = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            self?.refresh(expireOnly: true)
        }
    }
}
