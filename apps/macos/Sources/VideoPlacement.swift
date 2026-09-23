/// Which window holds the video. Every way out of the floating panel returns the
/// video to the main window and shows it, pausing if that window is on another Space.
/// Closing the main window while floating only hides it. So no sequence of closes
/// leaves audio playing without a visible window.
enum VideoPlacement: Equatable {
    case main
    case floating(mainHidden: Bool)
    /// mpv is shutting down; the video stays where it is until the process exits.
    case quitting

    enum Action {
        case float
        /// Return button, Escape, the menu toggle and the panel's close button.
        case returnToMain
        case closeMain
        case quit
    }

    func after(_ action: Action) -> VideoPlacement {
        switch (self, action) {
        case (.quitting, _), (_, .quit), (.main, .closeMain): .quitting
        case (.main, .float): .floating(mainHidden: false)
        case (.floating, .float): self
        case (.floating, .closeMain): .floating(mainHidden: true)
        case (_, .returnToMain): .main
        }
    }
}
