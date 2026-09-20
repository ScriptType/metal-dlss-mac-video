# CoreAudio channel layout property

mpv's CoreAudio backend builds an `AudioChannelLayout` with `ca_get_acl`. The
backend previously passed those bytes to `kAudioOutputUnitProperty_ChannelMap`
on global scope. The macOS SDK defines ChannelMap as an `SInt32` array. The
fork now passes the same layout to `kAudioUnitProperty_AudioChannelLayout` on
input scope.

The change is in mpv commit `8d24633c530228ac4d3ea30fd9e263ad601763cc`, based
on `f9213292afed1caa77827e66fe9c9216ee5ec513`. The parent repository pins that
commit through the `vendor/mpv` gitlink.

The first local property probe returned `-50` for the former call. The
corrected call returned `0` and read back the requested mono layout. A second
probe used fresh DefaultOutput units. Both left/right and right/left layouts
returned `0`, read back their requested labels, and left ChannelMap at `[0,1]`.

The isolated library build produced `libmpv.2.dylib` with SHA-256
`3313d16e728e294360366f7000fb027ceebb4e4b26c3b7e9f26f60d005c7abcb`.
Its muted libmpv smoke check loaded that exact path, selected CoreAudio with
48 kHz mono signed 16-bit output, progressed from 58.0 to 59.397581292 seconds,
reached natural EOF without an event error, and destroyed the instance cleanly.

The probes and smoke check do not show audio audibility, physical channel
order, full application behavior, macOS 26 compatibility, or the LG UltraFine
Audio MIDI Setup reversal in [upstream issue #15584](https://github.com/mpv-player/mpv/issues/15584).
The stereo probe did not change an audio device or system setting.

The [recorded evidence](evidence/m3-coreaudio-channel-layout.json) identifies
the retained result, log, and source files by path, byte count, and SHA-256.
