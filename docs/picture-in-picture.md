# Picture-in-picture

The player has no system picture-in-picture. An earlier diagnostic consumer fed completed RGBA16F frames to `AVPictureInPictureController` through an `AVSampleBufferDisplayLayer` content source. It entered PiP, followed pause and seek, and tore down cleanly on the M3, but it never shipped in ordinary playback.

It was removed for two reasons:

- Apple Developer Technical Support [stated in June 2026](https://developer.apple.com/forums/thread/830764) that sample-buffer PiP is supported only on iOS. The macOS availability annotations on that initializer are inaccurate.
- ScreenCaptureKit captures of the PiP window showed a cropped, brighter image than the source window. The exported and displayed buffers were identical, so the difference arose after the app handed the frame to the system.

The floating video window (#17) is the planned replacement. The optional `hdr_frame.h` frame exporter stays in the mpv fork because the native-colour and source-transition probes still read frames through it. The removed controller, probe and scripts remain in git history before the change that closed #38.
