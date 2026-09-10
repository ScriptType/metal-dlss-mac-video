/// Request state is separate from AVKit's asynchronous lifecycle callbacks.
/// In particular, a requested stop must survive an in-flight start callback.
struct PiPRequestState {
    private(set) var closing = false
    private(set) var startRequested = false
    private(set) var stopRequested = false
    private(set) var rendererFailure: String?

    var acceptsPlaybackCommands: Bool { !closing && rendererFailure == nil }
    var acceptsFrames: Bool { !closing && rendererFailure == nil }

    mutating func requestStart() -> Bool {
        guard acceptsFrames, !startRequested, !stopRequested else { return false }
        startRequested = true
        return true
    }

    mutating func requestStop() -> Bool {
        guard !stopRequested else { return false }
        stopRequested = true
        return true
    }

    mutating func didStart() -> Bool {
        startRequested = false
        return closing || stopRequested || rendererFailure != nil
    }

    mutating func didFailToStart() {
        startRequested = false
        stopRequested = false
    }

    mutating func didStop() {
        startRequested = false
        stopRequested = false
    }

    mutating func beginShutdown() -> Bool {
        guard !closing else { return false }
        closing = true
        return true
    }

    mutating func failRenderer(_ reason: String) -> Bool {
        guard rendererFailure == nil else { return false }
        rendererFailure = reason
        return true
    }
}
