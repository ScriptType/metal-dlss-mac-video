/// Re-reads the EDR headroom of the screen that shows the video after a screen or
/// display-parameter change, and reconfigures once per real change.
@MainActor
final class DisplayHeadroomMonitor {
    /// macOS ramps headroom in many small steps, each with a parameters notification,
    /// while HDR content appears or brightness changes. A display or preset change moves
    /// it by far more than this.
    static let minimumRelativeChange = 0.1
    private let read: () -> Double
    private let reconfigure: (_ old: Double?, _ new: Double) -> Void
    private(set) var headroom: Double?

    init(read: @escaping () -> Double, reconfigure: @escaping (_ old: Double?, _ new: Double) -> Void) {
        self.read = read
        self.reconfigure = reconfigure
    }

    func screenChanged() {
        let value = read()
        if let headroom, abs(value - headroom) < Self.minimumRelativeChange * headroom { return }
        let old = headroom
        headroom = value
        reconfigure(old, value)
    }
}
