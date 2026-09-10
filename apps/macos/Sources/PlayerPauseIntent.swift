/// Keeps user intent separate from the asynchronously polled playback property.
struct PlayerPauseIntent {
    private(set) var requested: Bool?
    private var beforeSleep: Bool?

    mutating func request(_ paused: Bool) { requested = paused }

    mutating func observe(_ paused: Bool) {
        // A pause observed during sleep may be our lifecycle pause, rather than
        // acknowledgement of the user's most recent transport command.
        if beforeSleep == nil && requested == paused { requested = nil }
    }

    func desired(observed: Bool) -> Bool { requested ?? observed }

    mutating func beginSleep(observed: Bool) -> Bool {
        guard beforeSleep == nil else { return false }
        beforeSleep = desired(observed: observed)
        return true
    }

    mutating func endSleep() -> Bool? {
        guard let previous = beforeSleep else { return nil }
        beforeSleep = nil
        let restored = requested ?? previous
        requested = restored
        return restored
    }
}
