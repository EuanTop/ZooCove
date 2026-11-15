import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let animals = [
    "capybara", "bee", "platypus", "mallard",
    "red-panda", "otter", "axolotl", "barn-owl",
    "chinchilla", "frog", "arctic-fox", "octopus",
    "hedgehog", "koi", "penguin", "leaf-sheep"
]

struct ArtError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

func bitmap(width: Int, height: Int) throws -> CGContext {
    let format = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: colorSpace, bitmapInfo: format) else {
        throw ArtError("Could not create a bitmap for companion artwork")
    }
    return context
}

func visibleArtwork(in cell: CGImage) throws -> CGImage {
    let context = try bitmap(width: cell.width, height: cell.height)
    context.draw(cell, in: CGRect(x: 0, y: 0, width: cell.width, height: cell.height))
    guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else {
        throw ArtError("Could not read the companion artwork alpha channel")
    }
    var rows = [Int](repeating: 0, count: cell.height)
    var columns = [Int](repeating: 0, count: cell.width)
    for y in rows.indices {
        for x in columns.indices where bytes[y * context.bytesPerRow + x * 4 + 3] >= 96 {
            rows[y] += 1
            columns[x] += 1
        }
    }
    // Ignore sparse speckles when finding bounds, while retaining the original artwork inside them.
    guard let left = columns.firstIndex(where: { $0 >= 6 }),
          let right = columns.lastIndex(where: { $0 >= 6 }),
          let top = rows.firstIndex(where: { $0 >= 6 }),
          let bottom = rows.lastIndex(where: { $0 >= 6 }) else {
        throw ArtError("A companion cell has no visible artwork")
    }
    let bounds = CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
        .insetBy(dx: -3, dy: -3)
        .intersection(CGRect(x: 0, y: 0, width: cell.width, height: cell.height))
    guard let image = cell.cropping(to: bounds) else { throw ArtError("Could not trim a companion cell") }
    return image
}

func draw(_ image: CGImage, into bounds: CGRect, on context: CGContext) {
    let scale = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
    let width = CGFloat(image.width) * scale
    let height = CGFloat(image.height) * scale
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2,
                                   width: width, height: height))
}

func writePNG(_ context: CGContext, to url: URL) throws {
    guard let image = context.makeImage(),
          let writer = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw ArtError("Could not create \(url.lastPathComponent)")
    }
    CGImageDestinationAddImage(writer, image, nil)
    guard CGImageDestinationFinalize(writer) else { throw ArtError("Could not write \(url.lastPathComponent)") }
}

struct Stroke {
    // Coordinates are normalized in the finished square, with the origin at its top left.
    let center: SIMD2<Double>
    let radius: SIMD2<Double>
    let displacement: SIMD2<Double>

    init(_ x: Double, _ y: Double, _ rx: Double, _ ry: Double, _ dx: Double, _ dy: Double) {
        center = SIMD2(x, y)
        radius = SIMD2(rx, ry)
        displacement = SIMD2(dx, dy)
    }
}

let strokes: [String: [Stroke]] = [
    "capybara": [
        Stroke(0.76, 0.56, 0.44, 0.33, 0.055, 0.060), // Dip the broad snout.
        Stroke(0.29, 0.70, 0.36, 0.22, -0.06, 0.018)
    ],
    "platypus": [
        Stroke(0.15, 0.39, 0.31, 0.33, 0.055, -0.085), // Lift the paddle-shaped tail.
        Stroke(0.43, 0.68, 0.24, 0.19, -0.095, 0.045), // Sweep the near forefoot back.
        Stroke(0.83, 0.56, 0.30, 0.23, 0.022, 0.055)
    ],
    "mallard": [
        Stroke(0.34, 0.33, 0.51, 0.42, -0.065, 0.10), // Nod the head over the collar.
        Stroke(0.69, 0.82, 0.31, 0.22, 0.045, -0.025)
    ],
    "bee": [
        Stroke(0.40, 0.21, 0.37, 0.23, 0.11, 0.16), // Fold both wings toward the thorax.
        Stroke(0.22, 0.35, 0.26, 0.20, 0.085, 0.14)
    ]
]

func writePoses(from base: CGContext, strokes: [Stroke], animal: String, to output: URL) throws {
    let size = base.width
    guard let pixels = base.data?.assumingMemoryBound(to: UInt8.self) else {
        throw ArtError("Could not read the base pose for \(animal)")
    }
    let width = Double(size - 1)
    func sample(x: Int, y: Int, channel: Int) -> Double {
        guard (0..<size).contains(x), (0..<size).contains(y) else { return 0 }
        return Double(pixels[y * base.bytesPerRow + x * 4 + channel])
    }

    for (name, amount) in [("gather", -0.35), ("push", 1.0)] {
        let pose = try bitmap(width: size, height: size)
        guard let target = pose.data?.assumingMemoryBound(to: UInt8.self) else {
            throw ArtError("Could not create the \(name) pose for \(animal)")
        }
        for y in 0..<size {
            for x in 0..<size {
                let point = SIMD2(Double(x) / width, Double(y) / width)
                var offset = SIMD2<Double>.zero
                for stroke in strokes {
                    let delta = (point - stroke.center) / stroke.radius
                    let influence = max(0, 1 - delta.x * delta.x - delta.y * delta.y)
                    offset += stroke.displacement * (influence * influence * amount)
                }
                let source = (point - offset) * width
                let left = Int(floor(source.x))
                let top = Int(floor(source.y))
                let fx = source.x - Double(left)
                let fy = source.y - Double(top)
                for channel in 0..<4 {
                    let upper = sample(x: left, y: top, channel: channel) * (1 - fx)
                        + sample(x: left + 1, y: top, channel: channel) * fx
                    let lower = sample(x: left, y: top + 1, channel: channel) * (1 - fx)
                        + sample(x: left + 1, y: top + 1, channel: channel) * fx
                    target[y * pose.bytesPerRow + x * 4 + channel] = UInt8((upper * (1 - fy) + lower * fy).rounded())
                }
            }
        }
        try writePNG(pose, to: output.appending(path: "\(animal)-\(name)-\(size).png"))
    }
}

func run() throws {
    guard CommandLine.arguments.count == 4 else {
        throw ArtError("Usage: PrepareCompanions.swift SHEET COMPANION_DIRECTORY APP_ICON_PNG")
    }
    let input = URL(fileURLWithPath: CommandLine.arguments[1])
    let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    let icon = URL(fileURLWithPath: CommandLine.arguments[3])
    guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
          let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil),
          sheet.width == sheet.height, sheet.width >= 400,
          sheet.alphaInfo != .none && sheet.alphaInfo != .noneSkipFirst && sheet.alphaInfo != .noneSkipLast
    else { throw ArtError("Expected the square, transparent 4 × 4 companion sheet") }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

    for (index, animal) in animals.enumerated() {
        let row = index / 4
        let column = index % 4
        let x = sheet.width * column / 4
        let y = sheet.height * row / 4
        let cellBounds = CGRect(x: x, y: y, width: sheet.width * (column + 1) / 4 - x,
                                height: sheet.height * (row + 1) / 4 - y)
        guard let cell = sheet.cropping(to: cellBounds) else { throw ArtError("Missing cell for \(animal)") }
        let artwork = try visibleArtwork(in: cell)

        for size in [48, 192] {
            let context = try bitmap(width: size, height: size)
            let rect = CGRect(x: 0, y: 0, width: size, height: size)
            let margin = CGFloat(size) * (size == 48 && strokes[animal] != nil ? 0.085 : 0.035)
            draw(artwork, into: rect.insetBy(dx: margin, dy: margin), on: context)
            try writePNG(context, to: output.appending(path: "\(animal)-\(size).png"))
            if size == 48, let stroke = strokes[animal] {
                try writePoses(from: context, strokes: stroke, animal: animal, to: output)
            }
        }

        if index == 0 {
            let context = try bitmap(width: 1024, height: 1024)
            let tile = CGRect(x: 48, y: 48, width: 928, height: 928)
            context.addPath(CGPath(roundedRect: tile, cornerWidth: 220, cornerHeight: 220, transform: nil))
            context.setFillColor(red: 0.13, green: 0.13, blue: 0.13, alpha: 1)
            context.fillPath()
            draw(artwork, into: CGRect(x: 149, y: 177, width: 726, height: 726), on: context)
            try writePNG(context, to: icon)
        }
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
