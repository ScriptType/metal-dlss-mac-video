// CPU-only checks of the floating-video window rule. They open no window.
@main
struct VideoPlacementChecks {
    static func main() {
        let floating = VideoPlacement.main.after(.float)
        assert(floating == .floating(mainHidden: false))

        // PR #22's failing order: close the main window while floating, then the panel.
        let mainClosed = floating.after(.closeMain)
        assert(mainClosed == .floating(mainHidden: true))
        assert(mainClosed.after(.float) == mainClosed)
        assert(mainClosed.after(.returnToMain) == .main)

        // The other order: the panel returns the video, then closing the main window quits.
        assert(floating.after(.returnToMain) == .main)
        assert(VideoPlacement.main.after(.closeMain) == .quitting)

        // Quitting while floating does not move the video while mpv shuts down.
        assert(floating.after(.quit) == .quitting)
        assert(mainClosed.after(.quit) == .quitting)

        let actions: [VideoPlacement.Action] = [.float, .returnToMain, .closeMain, .quit]
        for action in actions { assert(VideoPlacement.quitting.after(action) == .quitting) }
        for state in [VideoPlacement.main, floating, mainClosed] {
            assert(state.after(.returnToMain) == .main)
        }
        print("10 video-placement checks passed; no window was opened")
    }
}
