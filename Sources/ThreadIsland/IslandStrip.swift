import AppKit
import QuartzCore
import ThreadIslandCore

@MainActor
struct IslandGeometry: Equatable {
    private static let padding: CGFloat = 12
    let frame: NSRect
    let physical: ClosedRange<CGFloat>
    let leftCount: Int
    let rightCount: Int
    let hiddenCount: Int
    let overflowOnRight: Bool
    let showsOverflow: Bool
    let slotWidth: CGFloat

    init?(screen: NSScreen, count: Int) {
        guard let leftArea = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea,
              leftArea.maxX < rightArea.minX else { return nil }
        let left = leftArea.maxX
        let right = rightArea.minX
        slotWidth = count > 8 ? 62 : 80
        var leftCapacity = Self.capacity(leftArea, slot: slotWidth)
        var rightCapacity = Self.capacity(rightArea, slot: slotWidth)
        let capacity = leftCapacity + rightCapacity
        hiddenCount = count > capacity ? count - max(0, capacity - 1) : 0
        overflowOnRight = rightCapacity > 0
        showsOverflow = hiddenCount > 0 && capacity > 0
        if showsOverflow {
            if overflowOnRight { rightCapacity -= 1 } else { leftCapacity -= 1 }
        }
        let displayed = count - hiddenCount
        leftCount = min(leftCapacity, max((displayed + 1) / 2, displayed - rightCapacity))
        rightCount = displayed - leftCount

        let leftSlots = leftCount + (showsOverflow && !overflowOnRight ? 1 : 0)
        let rightSlots = rightCount + (showsOverflow && overflowOnRight ? 1 : 0)
        let leftWidth = Self.padding + (count == 0 ? 41 : CGFloat(leftSlots) * slotWidth)
        let rightWidth = Self.padding + CGFloat(rightSlots) * slotWidth
        let depth = max(screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY)
        frame = NSRect(x: left - leftWidth, y: screen.frame.maxY - depth,
                       width: right - left + leftWidth + rightWidth, height: depth)
        physical = leftWidth...(leftWidth + right - left)
    }

    private static func capacity(_ area: CGRect, slot: CGFloat) -> Int {
        max(0, Int((min(area.width * 0.60, 336) - padding) / slot))
    }
}

@MainActor
final class IslandStrip: NSPanel {
    private struct Layout: Equatable {
        let geometry: IslandGeometry
        let ids: [Session.ID]
        let labels: [String]
        let avatars: [SessionAvatar]
    }

    private var layout: Layout?
    private let background = IslandBackground(frame: .zero)
    private let barView = NSView(frame: .zero)
    private var buttons: [Session.ID: SessionIslandButton] = [:]
    private(set) var leftToRight: [SessionIslandButton] = []
    private var centerButton: IslandButton?

    var isBarVisible: Bool { barView.window?.isVisible == true }

    func setExpanded(_ expanded: Bool) {
        let label = expanded ? "收起会话面板" : "展开会话列表"
        centerButton?.toolTip = label
        centerButton?.setAccessibilityLabel(label)
    }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = background
        restoreBar()
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func orderOut(_ sender: Any?) {
        if barView.window === self { stopMotion() }
        super.orderOut(sender)
    }

    func attachBar(to container: NSView, frame: CGRect) {
        if barView.superview !== container {
            barView.removeFromSuperview()
            container.addSubview(barView)
        }
        barView.frame = frame
    }

    func restoreBar() {
        attachBar(to: background, frame: background.bounds)
    }

    func update(geometry: IslandGeometry, sessions: [IslandSession],
                avatars: [Session.ID: SessionAvatar], motionEnabled: Bool,
                owner: AnyObject, expand: Selector, jump: Selector) {
        let visible = Array(sessions.prefix(geometry.leftCount + geometry.rightCount))
        let next = Layout(geometry: geometry, ids: visible.map(\.id), labels: visible.map(\.label),
                          avatars: visible.map { avatars[$0.id] ?? SessionAvatars.automatic(for: $0.id) })
        let animate = motionEnabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let previous = buttons
        if layout != next {
            layout = next
            setFrame(geometry.frame, display: false)
            buttons.removeAll(keepingCapacity: true)
            let strip = barView
            for child in strip.subviews { child.removeFromSuperview() }
            strip.setFrameSize(geometry.frame.size)

            let center = IslandButton(frame: strip.bounds)
            center.target = owner
            center.action = expand
            centerButton = center
            strip.addSubview(center)
            if sessions.isEmpty {
                let resting = RestingCompanion(frame: NSRect(x: 7, y: 4, width: 37, height: strip.bounds.height - 5),
                                               kind: .capybara)
                strip.addSubview(resting)
            }

            var left = 0
            var right = 0
            for (index, item) in visible.enumerated() {
                let goesLeft = left < geometry.leftCount && (right == geometry.rightCount || index.isMultiple(of: 2))
                let slot = goesLeft ? left : right
                let button = SessionIslandButton(item: item, avatar: next.avatars[index],
                                                  frame: slotFrame(slot, onRight: !goesLeft, geometry: geometry))
                button.target = owner
                button.action = jump
                if goesLeft { left += 1 } else { right += 1 }
                buttons[item.id] = button
                strip.addSubview(button)
            }
            leftToRight = buttons.values.sorted { $0.frame.minX < $1.frame.minX }
            for (index, button) in leftToRight.enumerated() {
                button.shortcutNumber = index < 9 ? index + 1 : nil
            }
            if geometry.showsOverflow {
                let slot = geometry.overflowOnRight ? right : left
                let button = IslandButton(frame: slotFrame(slot, onRight: geometry.overflowOnRight, geometry: geometry))
                button.caption = "+\(geometry.hiddenCount)"
                button.target = owner
                button.action = expand
                button.toolTip = "查看其余 \(geometry.hiddenCount) 条会话"
                button.setAccessibilityLabel(button.toolTip)
                strip.addSubview(button)
            }
        }

        for item in visible {
            guard let button = buttons[item.id] else { continue }
            let didFinish = previous[item.id]?.item.running == true && item.ready
            button.update(item, settle: didFinish && animate)
            if item.running, animate {
                button.startSwimming()
            }
        }
        if !animate { stopMotion() }
    }

    func stopMotion() {
        for button in buttons.values { button.stopMotion() }
    }

    private func slotFrame(_ slot: Int, onRight: Bool, geometry: IslandGeometry) -> CGRect {
        let width = geometry.slotWidth
        let x = onRight ? geometry.physical.upperBound + CGFloat(slot) * width
                        : geometry.physical.lowerBound - CGFloat(slot + 1) * width
        return CGRect(x: x, y: 2, width: width, height: geometry.frame.height - 3)
    }
}

private final class IslandBackground: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(NSColor.black.cgColor)
        context.addPath(IslandContour.path(in: bounds, side: IslandContour.closedSide,
                                           bottom: IslandContour.closedBottom))
        context.fillPath()
    }
}

class IslandButton: NSButton {
    var caption: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        setButtonType(.momentaryChange)
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let caption else { return }
        let text = NSAttributedString(string: caption, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor(white: 0.78, alpha: 1)
        ])
        let size = text.size()
        text.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}

final class SessionIslandButton: IslandButton {
    private struct Stroke {
        let duration: CFTimeInterval
        let travel: Double
        let lift: Double
        let tilt: Double

        init(_ duration: CFTimeInterval, _ travel: Double, _ lift: Double, _ tilt: Double) {
            self.duration = duration
            self.travel = travel
            self.lift = lift
            self.tilt = tilt
        }
    }

    private static let labelHeight: CGFloat = 13
    private(set) var item: IslandSession
    private let avatar: SessionAvatar
    private let animal = CALayer()
    private let wakes = [CAShapeLayer(), CAShapeLayer()]
    private let check = CALayer()
    private let shortcutGlow = CALayer()
    var shortcutNumber: Int? { didSet { updateLabel() } }

    init(item: IslandSession, avatar: SessionAvatar, frame: NSRect) {
        self.item = item
        self.avatar = avatar
        super.init(frame: frame)
        wantsLayer = true
        buildLayers()
        update(item, settle: false)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    func update(_ item: IslandSession, settle: Bool) {
        guard item != self.item || toolTip == nil || settle else { return }
        self.item = item
        updateLabel()
        needsDisplay = true
        if !item.running {
            if settle {
                settleSwim()
            }
            animal.removeAnimation(forKey: "swim")
            animal.removeAnimation(forKey: "poses")
            for wake in wakes { wake.removeAnimation(forKey: "wake") }
        } else {
            animal.removeAnimation(forKey: "settle")
            for wake in wakes { wake.removeAnimation(forKey: "settle") }
            check.removeAllAnimations()
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        check.opacity = item.ready ? 1 : 0
        CATransaction.commit()
        guard settle else { return }
        let appear = keyframes("opacity", [0.0, 0.0, 1.0], length: 0.44)
        appear.keyTimes = [0, 0.60, 1]
        check.add(appear, forKey: "finish")
    }

    private func settleSwim() {
        let duration = 0.36
        if let visible = animal.presentation() {
            let glide = CABasicAnimation(keyPath: "transform")
            glide.fromValue = NSValue(caTransform3D: visible.transform)
            glide.toValue = NSValue(caTransform3D: animal.transform)
            glide.duration = duration
            glide.timingFunction = CAMediaTimingFunction(name: .easeOut)
            let settle = CAAnimationGroup()
            var animations: [CAAnimation] = [glide]
            if let current = visible.contents, let resting = animal.contents {
                let pose = CAKeyframeAnimation(keyPath: "contents")
                pose.values = [current, resting]
                pose.calculationMode = .discrete
                pose.keyTimes = [0, 0.2, 1]
                pose.duration = duration
                animations.append(pose)
            }
            settle.animations = animations
            settle.duration = duration
            animal.add(settle, forKey: "settle")
        }
        for wake in wakes {
            guard let visible = wake.presentation(), visible.opacity > 0 else { continue }
            let fade = CAAnimationGroup()
            fade.animations = [
                keyframes("strokeStart", [visible.strokeStart, visible.strokeEnd], length: duration),
                keyframes("strokeEnd", [visible.strokeEnd, visible.strokeEnd], length: duration),
                keyframes("transform.translation.x", [Double(visible.transform.m41),
                                                       Double(visible.transform.m41) - direction], length: duration),
                keyframes("opacity", [Double(visible.opacity), 0], length: duration)
            ]
            fade.duration = duration
            wake.add(fade, forKey: "settle")
        }
    }

    private func updateLabel() {
        let action = item.ready ? "完成待查看" : "运行中"
        let description = "\(item.label) · \(action) · \(item.session.title) · \(item.session.instance.name)"
        let shortcut = shortcutNumber.map { " · ⌃⌘\($0)" } ?? ""
        toolTip = description + shortcut
        setAccessibilityLabel(description + shortcut)
    }

    func startSwimming() {
        guard animal.animation(forKey: "swim") == nil else { return }
        let hovering = avatar == .animal(.bee)
        let stroke: Stroke = switch avatar {
        case .animal(.capybara): Stroke(3.20, 2.50, 0.95, 0.08)
        case .animal(.platypus): Stroke(2.22, 3.45, 1.10, 0.055)
        case .animal(.mallard): Stroke(2.56, 3.35, 1.30, 0.13)
        case .animal(.bee): Stroke(1.82, 2.80, 1.75, 0.14)
        default: Stroke(2.65, 2.90, 0.95, 0.13)
        }
        let duration = stroke.duration
        let phase = Double(item.id.hashValue.magnitude % 10) * duration / 10
        let beats: [NSNumber] = [0, 0.17, 0.36, 0.64, 0.83, 1]
        let travel = direction * stroke.travel
        let tilt = direction * stroke.tilt
        let horizontal: [Double] = hovering
            ? [0, travel * 0.54, travel, -travel * 0.57, -travel * 0.75, 0]
            : [0, -travel * 0.23, travel, travel * 0.73, travel * 0.15, 0]
        let motion = loop([
            keyframes("transform.translation.x", horizontal, length: duration),
            keyframes("transform.translation.y",
                      hovering ? [0, -stroke.lift, -0.65, 1.35, -0.15, 0]
                          : [0, 0.75, 0.1, -stroke.lift, -0.25, 0], length: duration),
            keyframes("transform.rotation.z",
                      hovering ? [0, -tilt, -0.07, 0.12, 0.05, 0]
                          : [0, tilt * 0.70, -tilt, -tilt * 0.20, tilt * 0.35, 0], length: duration),
            keyframes("transform.scale.x",
                      hovering ? [1, 0.95, 1.035, 1, 0.98, 1] : [1, 0.95, 1.075, 1.025, 0.99, 1], length: duration)
        ], beats: beats, duration: duration, phase: phase)
        animal.add(motion, forKey: "swim")
        if let poses = CompanionImages.strokePoses(for: avatar), let resting = animal.contents {
            let frames = CAKeyframeAnimation(keyPath: "contents")
            frames.calculationMode = .discrete
            if hovering {
                frames.values = [poses.gather, resting, poses.push, resting]
                frames.keyTimes = [0, 0.25, 0.50, 0.75, 1]
                frames.duration = 0.22
                frames.repeatCount = .infinity
                frames.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 24, preferred: 24)
                animal.add(frames, forKey: "poses")
            } else {
                frames.values = [resting, poses.gather, resting, poses.push, resting, poses.gather]
                let points: [NSNumber] = [0, 0.12, 0.25, 0.32, 0.49, 0.86, 1]
                frames.duration = duration
                animal.add(loop([frames], beats: points, duration: duration, phase: phase), forKey: "poses")
            }
        }

        guard !hovering else { return }
        let drift: [Double] = [0, 0, 0.10, 0.55, 1.25, 2.25]
        let trailing = zip(horizontal, drift).map { position, distance in position - distance * direction }
        for (index, wake) in wakes.enumerated() {
            let delay = Double(index) * 0.045 * duration
            let ripple = loop([
                keyframes("strokeEnd", [0, 0.08, 0.67, 1, 1, 1], length: duration),
                keyframes("strokeStart", [0, 0, 0.04, 0.21, 0.6, 1], length: duration),
                keyframes("transform.translation.x", trailing, length: duration),
                keyframes("opacity", [0, 0, 0.88, 0.68, 0.37, 0], length: duration)
            ], beats: beats, duration: duration, phase: (phase + duration - delay).truncatingRemainder(dividingBy: duration))
            wake.add(ripple, forKey: "wake")
        }
    }

    private var direction: Double { avatar == .animal(.mallard) ? -1 : 1 }

    private func loop(_ animations: [CAKeyframeAnimation], beats: [NSNumber],
                      duration: CFTimeInterval, phase: CFTimeInterval) -> CAAnimationGroup {
        for animation in animations { animation.keyTimes = beats }
        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = duration
        group.repeatCount = .infinity
        group.timeOffset = phase
        group.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 24, preferred: 24)
        return group
    }

    func stopMotion() {
        animal.removeAllAnimations()
        for wake in wakes { wake.removeAllAnimations() }
        check.removeAllAnimations()
        shortcutGlow.removeAllAnimations()
    }

    func flashShortcut() {
        let fade = keyframes("opacity", [0.92, 0.62, 0.0], length: 0.28)
        shortcutGlow.add(fade, forKey: "shortcut")
    }

    private func buildLayers() {
        let side = max(10, min(25, bounds.height - Self.labelHeight - 3))
        let petRect = CGRect(x: bounds.midX - side / 2, y: bounds.height - Self.labelHeight - side - 1,
                             width: side, height: side)
        let isPlatypus = avatar == .animal(.platypus)
        let sprite = isPlatypus ? petRect.insetBy(dx: -side * 0.19, dy: -side * 0.19) : petRect
        animal.frame = sprite
        animal.contents = CompanionImages.image(for: avatar, size: .notch)?.cgImage(forProposedRect: nil, context: nil,
                                                                                      hints: nil)
        animal.contentsGravity = .resizeAspect

        for (index, wake) in wakes.enumerated() {
            let trail = CGMutablePath()
            let edge = direction > 0 ? petRect.minX : petRect.maxX
            let sign = CGFloat(direction)
            // The platypus is a low, wide sprite with a transparent border around the tail.
            let x = isPlatypus ? sprite.minX + sprite.width * 0.14 - CGFloat(index)
                : edge - sign * (1 + CGFloat(index))
            let y = isPlatypus ? sprite.minY + sprite.height * 0.57 + CGFloat(index) * 2.4
                : petRect.maxY - 5 + CGFloat(index) * 3
            let length: CGFloat = isPlatypus ? 6.5 : 10
            trail.move(to: CGPoint(x: x, y: y))
            trail.addCurve(to: CGPoint(x: x - length * sign, y: y - 1.5),
                           control1: CGPoint(x: x - length * 0.4 * sign, y: y + 1.7),
                           control2: CGPoint(x: x - length * 0.75 * sign, y: y + 0.2))
            wake.frame = bounds
            wake.path = trail
            wake.fillColor = nil
            wake.strokeColor = NSColor(white: 0.91, alpha: index == 0 ? 0.93 : 0.69).cgColor
            wake.lineWidth = 1.05
            wake.lineCap = .round
            wake.opacity = 0
        }

        let checkEdge = isPlatypus ? sprite.maxX - sprite.width * 0.10 : petRect.maxX
        check.frame = CGRect(x: checkEdge - 4, y: petRect.maxY - 9, width: 11, height: 11)
        check.cornerRadius = 5.5
        check.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        let green = NSColor(srgbRed: 0.29, green: 0.84, blue: 0.45, alpha: 1)
        if let symbol = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 7, weight: .bold).applying(.init(paletteColors: [green]))) {
            let glyph = CALayer()
            glyph.frame = check.bounds.insetBy(dx: 2, dy: 2)
            glyph.contents = symbol.cgImage(forProposedRect: nil, context: nil, hints: nil)
            glyph.contentsGravity = .resizeAspect
            check.addSublayer(glyph)
        }
        shortcutGlow.frame = bounds.insetBy(dx: 3, dy: 1)
        shortcutGlow.cornerRadius = 8
        shortcutGlow.backgroundColor = NSColor(white: 1, alpha: 0.20).cgColor
        shortcutGlow.opacity = 0
        layer?.addSublayer(shortcutGlow)
        for wake in wakes { layer?.addSublayer(wake) }
        layer?.addSublayer(animal)
        layer?.addSublayer(check)
    }

    private func keyframes(_ key: String, _ values: [Double], length: CFTimeInterval) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: key)
        animation.values = values
        animation.duration = length
        animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: values.count - 1)
        return animation
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted {
            NSColor.white.withAlphaComponent(0.10).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 1), xRadius: 8, yRadius: 8).fill()
        }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let text = NSAttributedString(string: item.label, attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: NSColor(white: 0.94, alpha: 1),
            .paragraphStyle: style
        ])
        text.draw(in: CGRect(x: 3, y: bounds.height - Self.labelHeight, width: bounds.width - 6,
                             height: Self.labelHeight))
    }
}

private final class RestingCompanion: NSView {
    let kind: CompanionKind

    init(frame: NSRect, kind: CompanionKind) {
        self.kind = kind
        super.init(frame: frame)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let side = min(bounds.height, bounds.width) - 3
        let rect = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        CompanionImages.image(for: kind, size: .notch)?
            .draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
