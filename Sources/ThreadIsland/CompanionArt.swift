import AppKit
import ImageIO
import SwiftUI
import ThreadIslandCore

@MainActor
enum CompanionImages {
    enum Size: Int { case notch = 48, panel = 192 }

    private static var cached: [String: NSImage] = [:]
    private static let imported: NSCache<NSData, NSImage> = {
        let cache = NSCache<NSData, NSImage>()
        cache.countLimit = 40
        return cache
    }()

    static func image(for avatar: SessionAvatar, size: Size) -> NSImage? {
        switch avatar {
        case .animal(let kind):
            return image(for: kind, size: size)
        case .image(let data):
            let key = data as NSData
            if let image = imported.object(forKey: key) { return image }
            guard let image = NSImage(data: data) else { return self.image(for: .capybara, size: size) }
            imported.setObject(image, forKey: key)
            return image
        }
    }

    static func image(for kind: CompanionKind, size: Size) -> NSImage? {
        image(named: "\(kind.rawValue)-\(size.rawValue)", size: size)
    }

    static func strokePoses(for avatar: SessionAvatar) -> (gather: CGImage, push: CGImage)? {
        guard case .animal(let kind) = avatar,
              [.capybara, .platypus, .mallard, .bee].contains(kind),
              let gather = image(named: "\(kind.rawValue)-gather-48", size: .notch)?
                .cgImage(forProposedRect: nil, context: nil, hints: nil),
              let push = image(named: "\(kind.rawValue)-push-48", size: .notch)?
                .cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return (gather, push)
    }

    private static func image(named key: String, size: Size) -> NSImage? {
        if let image = cached[key] { return image }
        guard let url = Bundle.main.url(forResource: key, withExtension: "png", subdirectory: "Companions"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let bitmap = CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let side = CGFloat(size.rawValue) / 2
        let image = NSImage(cgImage: bitmap, size: NSSize(width: side, height: side))
        cached[key] = image
        return image
    }
}

struct CompanionArt: View {
    let avatar: SessionAvatar
    let size: CompanionImages.Size

    init(kind: CompanionKind, size: CompanionImages.Size = .notch) {
        self.init(avatar: .animal(kind), size: size)
    }

    init(avatar: SessionAvatar, size: CompanionImages.Size = .notch) {
        self.avatar = avatar
        self.size = size
    }

    var body: some View {
        Group {
            if let image = CompanionImages.image(for: avatar, size: size) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "pawprint.fill")
                    .resizable().scaledToFit().padding(6).foregroundStyle(.gray)
            }
        }
        .accessibilityHidden(true)
    }
}
