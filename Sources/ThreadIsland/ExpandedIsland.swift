import AppKit
import SwiftUI

@MainActor
struct ExpandedIslandLayout: Equatable {
    nonisolated static let bodyWidth: CGFloat = 560
    nonisolated static let maxBodyHeight: CGFloat = 426
    private static let shadowPadding: CGFloat = 24

    let frame: CGRect
    let bar: CGRect?
    let body: CGRect

    init(screen: NSScreen, geometry: IslandGeometry?, bodyHeight: CGFloat) {
        let menu = geometry?.frame
        let center = geometry.map {
            $0.frame.minX + ($0.physical.lowerBound + $0.physical.upperBound) / 2
        } ?? screen.frame.midX
        let top = menu?.minY ?? screen.visibleFrame.maxY - 8
        let library = CGRect(x: center - Self.bodyWidth / 2,
                             y: top - bodyHeight, width: Self.bodyWidth, height: bodyHeight)
        let outline = menu.map { $0.union(library.insetBy(dx: -IslandContour.openSide, dy: 0)) } ?? library
        let padding = Self.shadowPadding
        let window = CGRect(x: outline.minX - padding, y: outline.minY - padding,
                            width: outline.width + 2 * padding, height: outline.height + padding)
        frame = window
        bar = menu.map { CGRect(x: $0.minX - window.minX, y: 0, width: $0.width, height: $0.height) }
        body = CGRect(x: library.minX - window.minX, y: window.maxY - library.maxY,
                      width: library.width, height: library.height)
    }
}

@MainActor @Observable
final class IslandPresentation {
    var progress: CGFloat = 0
    var layout: ExpandedIslandLayout?
}

struct ExpandedIsland: View {
    var model: LibraryModel
    var presentation: IslandPresentation
    var close: () -> Void
    var resize: () -> Void

    var body: some View {
        if let layout = presentation.layout {
            let outline = IslandOutline(progress: presentation.progress, bar: layout.bar, body: layout.body)
            LibraryView(model: model, close: close, height: layout.body.height, fusedToNotch: layout.bar != nil)
                .offset(x: layout.body.minX, y: layout.body.minY)
                .frame(width: layout.frame.width, height: layout.frame.height, alignment: .topLeading)
                .background(.black)
                .clipShape(outline)
                .background {
                    // Use the same animated contour as the panel so the shadow shrinks with it.
                    outline
                        .fill(.black.shadow(.drop(color: .black.opacity(0.28), radius: 9, y: 4)))
                        .opacity(Double(presentation.progress))
                        .allowsHitTesting(false)
                }
                .onChange(of: model.panelHeight) { _, _ in resize() }
        }
    }
}

/// The expanded window contains the actual AppKit session buttons above the library.
@MainActor
final class IslandPanelContent: NSView {
    private let host: NSHostingView<ExpandedIsland>

    init(view: ExpandedIsland) {
        host = NSHostingView(rootView: view)
        super.init(frame: .zero)
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        host.frame = bounds
    }
}

private struct IslandOutline: Shape {
    var progress: CGFloat
    var bar: CGRect?
    var body: CGRect

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let fraction = max(0, min(1, progress))
        guard let bar else {
            let height = fraction * body.height
            return Path(roundedRect: CGRect(x: body.minX, y: body.minY, width: body.width, height: height),
                        cornerRadius: min(20, height / 2))
        }

        let left = bar.minX + (min(body.minX - IslandContour.openSide, bar.minX) - bar.minX) * fraction
        let right = bar.maxX + (max(body.maxX + IslandContour.openSide, bar.maxX) - bar.maxX) * fraction
        let bottom = bar.maxY + (body.maxY - bar.maxY) * fraction
        let sideRadius = IslandContour.closedSide + (IslandContour.openSide - IslandContour.closedSide) * fraction
        let bottomRadius = IslandContour.closedBottom + (IslandContour.openBottom - IslandContour.closedBottom) * fraction
        let outline = CGRect(x: left, y: bar.minY, width: right - left, height: bottom - bar.minY)
        return Path(IslandContour.path(in: outline, side: sideRadius, bottom: bottomRadius))
    }
}
