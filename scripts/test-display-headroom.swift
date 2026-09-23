// CPU-only checks of the EDR headroom handler. They open no window and read no screen.
@main
struct DisplayHeadroomChecks {
    @MainActor static func main() {
        var readings: [Double] = [1.0, 1.0, 4.5, 4.5, 1.0]
        var reconfigurations: [(old: Double?, new: Double)] = []
        let monitor = DisplayHeadroomMonitor(read: { readings.removeFirst() },
                                             reconfigure: { reconfigurations.append((old: $0, new: $1)) })

        monitor.screenChanged()
        precondition(reconfigurations.count == 1 && reconfigurations[0].old == nil && reconfigurations[0].new == 1.0,
                     "the first reading configures the layer for the current screen")
        monitor.screenChanged()
        precondition(reconfigurations.count == 1, "an unchanged headroom does not reconfigure")
        monitor.screenChanged()
        precondition(reconfigurations.count == 2 && reconfigurations[1].old == 1.0 && reconfigurations[1].new == 4.5,
                     "moving to a screen with 4.5x headroom reconfigures once with the new value")
        monitor.screenChanged()
        precondition(reconfigurations.count == 2, "a repeated 4.5x reading does not reconfigure again")
        monitor.screenChanged()
        precondition(reconfigurations.count == 3 && reconfigurations[2].old == 4.5 && reconfigurations[2].new == 1.0,
                     "returning to SDR headroom reconfigures once more")
        precondition(monitor.headroom == 1.0 && readings.isEmpty)
        print("5 display-headroom checks passed; no screen was read")
    }
}
