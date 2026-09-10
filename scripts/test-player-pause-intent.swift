// CPU-only transport-intent regression checks. These do not simulate or qualify
// physical sleep, VoiceOver, a renderer, or an operating-system notification.
@main
struct PauseIntentChecks {
    static func main() {
        var playing = PlayerPauseIntent()
        assert(playing.beginSleep(observed: false))
        playing.observe(true)
        assert(playing.endSleep() == false)

        var paused = PlayerPauseIntent()
        assert(paused.beginSleep(observed: true))
        assert(paused.endSleep() == true)

        var pendingPause = PlayerPauseIntent()
        pendingPause.request(true)
        assert(pendingPause.beginSleep(observed: false))
        assert(pendingPause.endSleep() == true)

        var pendingPlay = PlayerPauseIntent()
        pendingPlay.request(false)
        assert(pendingPlay.beginSleep(observed: true))
        assert(pendingPlay.endSleep() == false)

        var duplicate = PlayerPauseIntent()
        assert(duplicate.beginSleep(observed: false))
        assert(!duplicate.beginSleep(observed: true))
        assert(duplicate.endSleep() == false)
        assert(duplicate.endSleep() == nil)

        var changedWhileSleeping = PlayerPauseIntent()
        assert(changedWhileSleeping.beginSleep(observed: false))
        changedWhileSleeping.request(true)
        changedWhileSleeping.observe(true)
        assert(changedWhileSleeping.endSleep() == true)

        var acknowledgement = PlayerPauseIntent()
        acknowledgement.request(true)
        acknowledgement.observe(false)
        assert(acknowledgement.requested == true)
        acknowledgement.observe(true)
        assert(acknowledgement.requested == nil)

        var pendingRestore = PlayerPauseIntent()
        assert(pendingRestore.beginSleep(observed: false))
        assert(pendingRestore.endSleep() == false)
        // A second sleep can arrive before the queued wake command is polled.
        assert(pendingRestore.beginSleep(observed: true))
        assert(pendingRestore.endSleep() == false)
        print("8 pause-intent logic checks passed; no physical sleep was tested")
    }
}
