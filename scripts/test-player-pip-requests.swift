// CPU-only request/callback ordering. This does not invoke AVKit delegates or
// establish an actual Picture in Picture lifecycle or renderer result.
@main
struct PiPRequestChecks {
    static func main() {
        var state = PiPRequestState()
        assert(state.requestStart())
        assert(!state.requestStart())
        assert(state.requestStop())
        assert(!state.requestStop())
        assert(state.didStart(), "A stop requested during startup must survive didStart")
        state.didStop()
        assert(state.acceptsFrames && state.requestStart())

        assert(state.requestStop())
        state.didFailToStart()
        assert(!state.startRequested && !state.stopRequested)
        assert(state.requestStart(), "A failed start must allow retry")
        assert(!state.didStart())
        assert(state.requestStop(), "A retried start must remain stoppable")
        state.didStop()

        assert(state.requestStart())
        assert(state.beginShutdown())
        assert(!state.beginShutdown())
        assert(!state.acceptsPlaybackCommands, "Late skip/play callbacks must be rejected after shutdown")
        assert(!state.acceptsFrames && !state.requestStart())
        assert(state.didStart(), "Startup completing during shutdown must stop")
        state.didFailToStart()
        assert(!state.acceptsPlaybackCommands && !state.acceptsFrames)
        state.didStop()
        assert(!state.acceptsPlaybackCommands, "Late callbacks must not reopen a closed consumer")

        var failed = PiPRequestState()
        assert(failed.requestStart())
        assert(failed.failRenderer("renderer unavailable"))
        assert(failed.didStart(), "A renderer failure during startup must stop the eventual PiP")
        assert(!failed.acceptsFrames && !failed.acceptsPlaybackCommands)
        failed.didStop()
        failed.didFailToStart()
        assert(!failed.failRenderer("new error") && failed.rendererFailure == "renderer unavailable")
        assert(!failed.acceptsFrames && !failed.requestStart(), "Clock-only updates or lifecycle callbacks cannot recover a discarded paused revision")
        assert(failed.beginShutdown())

        print("6 PiP request-ordering scenarios passed; CPU state only, no AVKit lifecycle qualification")
    }
}
