import CoreServices
import Foundation
import ThreadIslandCore

@MainActor
final class CatalogWatcher {
    private var stream: FSEventStreamRef?
    private var onChange: (() -> Void)?

    func start(instances: [Instance], onChange: @escaping () -> Void) {
        stop()
        let paths = instances.map(\.root.path).filter { FileManager.default.fileExists(atPath: $0) }
        guard !paths.isEmpty else { return }
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let paths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            let changes = UnsafeBufferPointer(start: flags, count: count)
            let mustRescan = changes.contains {
                $0 & UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged) != 0
            }
            let replaced = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved |
                                  kFSEventStreamEventFlagItemRenamed)
            let newTranscript = zip(paths, changes).contains { path, flag in
                path.hasSuffix(".jsonl") && (flag & replaced) != 0
            }
            guard mustRescan || newTranscript || paths.contains(where: Catalog.isCatalogEvent) else { return }
            let owner = Unmanaged<CatalogWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { owner.onChange?() }
        }
        let flags = kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagWatchRoot
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                               0.8, FSEventStreamCreateFlags(flags)) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        if !FSEventStreamStart(stream) { stop() }
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        onChange = nil
    }
}
