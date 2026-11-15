import CoreGraphics

enum IslandContour {
    static let closedSide: CGFloat = 11
    static let openSide: CGFloat = 18
    static let closedBottom: CGFloat = 9
    static let openBottom: CGFloat = 22

    static func path(in rect: CGRect, side: CGFloat, bottom: CGFloat) -> CGPath {
        let path = CGMutablePath()
        guard rect.width > 0, rect.height > 0 else { return path }

        let side = min(side, rect.width / 4, rect.height / 2)
        let left = rect.minX + side
        let right = rect.maxX - side
        let top = rect.minY
        let base = rect.maxY
        let bottom = min(bottom, (right - left) / 2, rect.height - side)

        path.move(to: CGPoint(x: rect.minX, y: top))
        path.addLine(to: CGPoint(x: rect.maxX, y: top))
        path.addQuadCurve(to: CGPoint(x: right, y: top + side), control: CGPoint(x: right, y: top))
        path.addLine(to: CGPoint(x: right, y: base - bottom))
        path.addQuadCurve(to: CGPoint(x: right - bottom, y: base), control: CGPoint(x: right, y: base))
        path.addLine(to: CGPoint(x: left + bottom, y: base))
        path.addQuadCurve(to: CGPoint(x: left, y: base - bottom), control: CGPoint(x: left, y: base))
        path.addLine(to: CGPoint(x: left, y: top + side))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: top), control: CGPoint(x: left, y: top))
        path.closeSubpath()
        return path
    }
}
