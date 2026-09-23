/// Re-reads the EDR headroom of the screen that shows the video after a screen or
/// display-parameter change, and reconfigures once per actual change.
@MainActor
final class DisplayHeadroomMonitor {
    private let read: () -> Double
    private let reconfigure: (_ old: Double?, _ new: Double) -> Void
    private(set) var headroom: Double?

    init(read: @escaping () -> Double, reconfigure: @escaping (_ old: Double?, _ new: Double) -> Void) {
        self.read = read
        self.reconfigure = reconfigure
    }

    func screenChanged() {
        let value = read()
        guard value != headroom else { return }
        let old = headroom
        headroom = value
        reconfigure(old, value)
    }
}
