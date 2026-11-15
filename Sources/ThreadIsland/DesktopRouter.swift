import AppKit
import Darwin
import ThreadIslandCore

@MainActor
enum DesktopRouter {
    private static let bundleID = "com.openai.codex"

    enum RouteError: LocalizedError {
        case notRunning
        case wrongInstance
        case ambiguous
        case rejected

        var errorDescription: String? {
            switch self {
            case .notRunning: "请先启动目标 Codex 实例，再从这里跳转。"
            case .wrongInstance: "当前 Codex 窗口与这条会话的实例不同，或无法确认实际目录。可先在本应用查看，或复制对应实例的终端命令。"
            case .ambiguous: "检测到多个 Codex 窗口进程，macOS 无法保证链接发给指定实例。"
            case .rejected: "Codex 未接收会话链接。"
            }
        }
    }

    static func destination(for instance: Instance) throws -> NSRunningApplication {
        guard instance.agent.isCodex else { throw RouteError.wrongInstance }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { !$0.isTerminated && $0.bundleURL != nil }
        guard !apps.isEmpty else { throw RouteError.notRunning }
        let matches = apps.filter { effectiveHome(pid: $0.processIdentifier) == instance.id }
        guard !matches.isEmpty else { throw RouteError.wrongInstance }
        guard matches.count == 1, let app = matches.first,
              apps.filter({ $0.bundleURL.map(Instance.canonical) == app.bundleURL.map(Instance.canonical) }).count == 1
        else { throw RouteError.ambiguous }
        return app
    }

    static func open(_ session: Session) async throws {
        guard session.instance.agent.isCodex,
              let url = SessionLink.desktopURL(for: session.threadID) else { throw RouteError.rejected }
        let matched = try destination(for: session.instance)
        guard let applicationURL = matched.bundleURL else { throw RouteError.rejected }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let receiving = try await NSWorkspace.shared.open([url], withApplicationAt: applicationURL,
                                                         configuration: configuration)
        guard receiving.processIdentifier == matched.processIdentifier else { throw RouteError.rejected }
    }

    private static func effectiveHome(pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0,
              length > MemoryLayout<Int32>.size, length < 4_194_304 else { return nil }
        var bytes = [UInt8](repeating: 0, count: length)
        defer {
            _ = bytes.withUnsafeMutableBytes { buffer in
                buffer.initializeMemory(as: UInt8.self, repeating: 0)
            }
        }
        guard sysctl(&mib, UInt32(mib.count), &bytes, &length, nil, 0) == 0,
              length <= bytes.count else { return nil }
        let argc = bytes.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard argc > 0, argc < 10_000 else { return nil }
        var cursor = MemoryLayout<Int32>.size
        func next() -> ArraySlice<UInt8>? {
            guard cursor < length, let end = bytes[cursor..<length].firstIndex(of: 0) else { return nil }
            let value = bytes[cursor..<end]
            cursor = end + 1
            return value
        }
        guard next() != nil else { return nil }  // Executable path precedes argv.
        while cursor < length && bytes[cursor] == 0 { cursor += 1 }
        var customProfileArgument = false
        for _ in 0..<argc {
            guard let argument = next() else { return nil }
            if argument.starts(with: "--user-data-dir".utf8) { customProfileArgument = true }
        }
        let key = "CODEX_HOME="
        var redirectedHome = false
        while let variable = next(), !variable.isEmpty {
            if variable.starts(with: key.utf8) {
                let value = String(decoding: variable.dropFirst(key.utf8.count), as: UTF8.self)
                guard value.hasPrefix("/") else { return nil }
                return Instance.canonical(URL(fileURLWithPath: value)).path
            }
            if variable.starts(with: "HOME=".utf8) && variable.dropFirst(5) !=
                ArraySlice(FileManager.default.homeDirectoryForCurrentUser.path.utf8) {
                redirectedHome = true
            }
        }
        guard !customProfileArgument, !redirectedHome else { return nil }
        return Instance.canonical(FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")).path
    }
}
