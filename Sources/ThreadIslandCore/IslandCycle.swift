public struct IslandCycle {
    private var last: Session.ID?
    private var previousOrder: [Session.ID] = []

    public init() {}

    public mutating func selected(_ id: Session.ID, in leftToRight: [Session.ID]) {
        last = id
        previousOrder = leftToRight
    }

    public func next(in leftToRight: [Session.ID]) -> Session.ID? {
        guard let first = leftToRight.first else { return nil }
        if let index = leftToRight.firstIndex(where: { $0 == last }) {
            return leftToRight[(index + 1) % leftToRight.count]
        }
        // Opening a completed conversation can remove its icon before the next key press.
        if let index = previousOrder.firstIndex(where: { $0 == last }) {
            let candidates = previousOrder.dropFirst(index + 1) + previousOrder.prefix(index)
            let stillVisible = Set(leftToRight)
            return candidates.first(where: stillVisible.contains) ?? first
        }
        return first
    }
}
