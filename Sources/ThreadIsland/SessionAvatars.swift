import AppKit
import CryptoKit
import ImageIO
import ThreadIslandCore
import UniformTypeIdentifiers

enum SessionAvatar: Codable, Hashable, Sendable {
    case animal(CompanionKind)
    case image(Data)

    var name: String {
        switch self {
        case .animal(let kind): kind.name
        case .image: "自定义图标"
        }
    }
}

struct SessionAvatars {
    static let didChange = Notification.Name("dev.threadisland.mac.session-avatar-changed")
    private let root: URL

    init(root: URL? = nil) {
        let environment = ProcessInfo.processInfo.environment
        let configured = (environment["ZOOCOVE_AVATAR_DIR"] ?? environment["NOTCHZOO_AVATAR_DIR"])
            .flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
        self.root = root ?? configured ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/NotchZoo/SessionAvatars", directoryHint: .isDirectory)
    }

    func avatar(for id: Session.ID) -> SessionAvatar {
        let fingerprint = Self.fingerprint(for: id)
        guard let data = try? Data(contentsOf: location(for: fingerprint)),
              let choice = try? JSONDecoder().decode(SessionAvatar.self, from: data) else {
            return Self.automatic(from: fingerprint)
        }
        return choice
    }

    static func automatic(for id: Session.ID) -> SessionAvatar {
        automatic(from: fingerprint(for: id))
    }

    func set(_ avatar: SessionAvatar?, for id: Session.ID) throws {
        let file = location(for: Self.fingerprint(for: id))
        if let avatar {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(avatar).write(to: file, options: .atomic)
        } else {
            do { try FileManager.default.removeItem(at: file) }
            catch let error as CocoaError where error.code == .fileNoSuchFile {}
        }
    }

    static func rasterize(_ url: URL) throws -> SessionAvatar {
        let metadata = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard metadata.isRegularFile == true, let bytes = metadata.fileSize, bytes <= 20 * 1_024 * 1_024,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 192
              ] as CFDictionary) else { throw AvatarError.invalidImage }
        let output = NSMutableData()
        guard let png = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { throw AvatarError.invalidImage }
        CGImageDestinationAddImage(png, bitmap, nil)
        guard CGImageDestinationFinalize(png) else { throw AvatarError.invalidImage }
        return .image(output as Data)
    }

    private static func fingerprint(for id: Session.ID) -> SHA256.Digest {
        let scope = Data((id.instanceID + "\u{0}" + id.threadID).utf8)
        return SHA256.hash(data: scope)
    }

    private static func automatic(from fingerprint: SHA256.Digest) -> SessionAvatar {
        let animals = CompanionKind.allCases
        let index = fingerprint.withUnsafeBytes { Int($0[0]) % animals.count }
        return .animal(animals[index])
    }

    private func location(for fingerprint: SHA256.Digest) -> URL {
        let key = fingerprint.map { String(format: "%02x", $0) }.joined()
        return root.appending(path: key + ".json")
    }
}

enum AvatarError: LocalizedError {
    case invalidImage
    case missingThread
    case noMatchingSession
    case usage
    case skillConflict

    var errorDescription: String? {
        switch self {
        case .invalidImage: "请选择可读取的图片，例如 20 MB 以内的 PNG、JPEG 或 WebP。"
        case .missingThread: "没有收到当前会话 ID。请在目标 Codex 对话中执行。"
        case .noMatchingSession: "在当前 CODEX_HOME 中找不到这条会话。"
        case .usage: "用法：--avatar get | set <图片路径> | animal <动物名> | reset | install-skill"
        case .skillConflict: "发现同名的现有技能，保留了原文件。"
        }
    }
}

enum AvatarAgent {
    @MainActor
    static func run(_ arguments: [String]) throws {
        if arguments == ["install-skill"] {
            print(try installSkill().path)
            return
        }
        let environment = ProcessInfo.processInfo.environment
        guard let thread = environment["CODEX_THREAD_ID"], Catalog.isThreadID(thread) else {
            throw AvatarError.missingThread
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root: URL
        if let configured = environment["CODEX_HOME"] {
            guard configured.hasPrefix("/") else { throw AvatarError.noMatchingSession }
            root = URL(fileURLWithPath: configured)
        } else {
            root = home.appending(path: ".codex")
        }
        let instance = Instance(name: "Codex", root: root, kind: .custom)
        guard let session = try Catalog.session(id: thread, in: instance) else { throw AvatarError.noMatchingSession }
        let store = SessionAvatars()
        let choice: SessionAvatar?
        switch arguments.first {
        case "get" where arguments.count == 1:
            print("当前头像：\(store.avatar(for: session.id).name)")
            return
        case "set" where arguments.count == 2:
            choice = try SessionAvatars.rasterize(URL(fileURLWithPath: arguments[1]))
        case "animal" where arguments.count == 2:
            let name = arguments[1]
            guard let kind = CompanionKind.allCases.first(where: { $0.rawValue == name || $0.name == name })
            else { throw AvatarError.usage }
            choice = .animal(kind)
        case "reset" where arguments.count == 1:
            choice = nil
        default:
            throw AvatarError.usage
        }
        try store.set(choice, for: session.id)
        DistributedNotificationCenter.default().postNotificationName(SessionAvatars.didChange, object: nil,
                                                                       userInfo: nil, deliverImmediately: true)
        print("已设置此会话的 ZooCove 头像：\((choice ?? SessionAvatars.automatic(for: session.id)).name)")
    }

    @MainActor
    static func installSkill(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        guard let binary = Bundle.main.executableURL else { throw AvatarError.usage }
        let directory = home.appending(path: ".agents/skills/notchzoo-avatar", directoryHint: .isDirectory)
        let file = directory.appending(path: "SKILL.md")
        let marker = "<!-- managed-by-notchzoo -->"
        if FileManager.default.fileExists(atPath: file.path),
           (try? String(contentsOf: file, encoding: .utf8).contains(marker)) != true {
            throw AvatarError.skillConflict
        }
        let executable = "'" + binary.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let document = """
        ---
        name: notchzoo-avatar
        description: Set or restore the ZooCove icon for the current local Codex conversation when the user asks. 助手、刘海、项目图标、会话头像、麻将图标。
        ---

        \(marker)

        Use this only when the user asks to change or inspect the ZooCove avatar of the current conversation.

        For a project icon, find the existing canonical app icon in the working project. Prefer the asset the user named or the icon referenced by the project. Use a local PNG, JPEG, WebP, or ICNS that can be read by macOS. If only vector source exists, use an existing project export or render a local PNG without changing the project. Ask about the asset when the project has several equally plausible icons.

        Run \(executable) `--avatar set /absolute/path/to/icon.png` with the file path quoted as a separate shell argument. For an animal, use `--avatar animal <name>`, for example `--avatar animal 卡皮巴拉`. Use `--avatar get` to inspect and `--avatar reset` to restore this conversation’s automatic animal.

        The command uses the current shell's CODEX_THREAD_ID and CODEX_HOME to select the exact conversation. Keep those values as supplied by Codex. If it cannot find the thread, report the failure rather than substituting another thread or instance. Report success only after the command succeeds.
        """
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try document.write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}
