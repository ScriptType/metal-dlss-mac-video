# Human checks

These steps cover the issue items marked **Human**: things an agent cannot observe, such as a real lid close, VoiceOver speech or the picture on the XDR display. Each step takes under five minutes. Run them on the MacBook Pro (M3, built-in XDR) with no builds, benchmarks or preparation jobs running.

After each step, paste the printed PASS or FAIL lines and anything you noticed into the named issue, then tick the item there.

## Before you start

Build the app from the current tree once, from the repository root:

```sh
bash scripts/build-harness.sh
mkdir -p artifacts/human
```

The app is `artifacts/HDR Player.app`. The steps start its executable from Terminal so they can pass environment variables. Keep that Terminal window open while the player runs.

## Sleep and wake (#16)

The lifecycle recorder writes what the player did around a real sleep. `scripts/check-sleep-wake-log.py` then judges it. The recorder only counts a cycle when macOS reports a real kernel sleep followed by power-on, so closing the lid is required. Disconnect any external display first; with one attached and power connected, a closed lid keeps the Mac awake. The analyzer also requires a clean Cmd+Q at least 10 seconds after wake, and it checks the displayed frame, not only the clock.

### 1. A paused clip stays paused

```sh
HDRPLAYER_LIFECYCLE_LOG="$PWD/artifacts/human/sleep-paused.jsonl" \
  "artifacts/HDR Player.app/Contents/MacOS/HDRPlayer" "$PWD/assets/test-clips/playback/pq-30-60s.mkv"
```

1. Let the clip play for about 5 seconds, then press Space to pause.
2. Close the lid. Wait 30 seconds. Open the lid and log in.
3. Look at the player. It should still be paused on the same frame, with no sound.
4. Wait 10 seconds, then press Cmd+Q.
5. Run:

   ```sh
   python3 scripts/check-sleep-wake-log.py --expect paused artifacts/human/sleep-paused.jsonl
   ```

   Expected: `SLEEP/WAKE CHECK: PASS`.

### 2. A playing clip resumes

```sh
HDRPLAYER_LIFECYCLE_LOG="$PWD/artifacts/human/sleep-playing.jsonl" \
  "artifacts/HDR Player.app/Contents/MacOS/HDRPlayer" "$PWD/assets/test-clips/playback/pq-30-60s.mkv"
```

1. Let the clip play for about 10 seconds. Do not pause.
2. Close the lid. Wait 30 seconds. Open the lid and log in.
3. The clip should continue playing within a few seconds, with the one-second audio pulses audible again.
4. Wait 10 seconds, then press Cmd+Q.
5. Run:

   ```sh
   python3 scripts/check-sleep-wake-log.py --expect playing artifacts/human/sleep-playing.jsonl
   ```

   Expected: `SLEEP/WAKE CHECK: PASS`.

## VoiceOver (#16)

### 3. VoiceOver announces the main controls

One-time setup, about two minutes:

1. Turn VoiceOver on with Cmd+F5. Open VoiceOver Utility with Control-Option-F8, and under General tick **Allow VoiceOver to be controlled with AppleScript**.
2. Let Terminal read VoiceOver's output. Run the command below and click **OK** when macOS asks whether Terminal may control VoiceOver:

   ```sh
   osascript -e 'tell application "VoiceOver" to get content of last phrase'
   ```

3. Build the read-only probe. It reads the last phrase only while the player is the frontmost app, and it never moves the VoiceOver cursor:

   ```sh
   swiftc scripts/inspect-player-voiceover.swift -o artifacts/human/voiceover-probe
   ```

The check:

```sh
"artifacts/HDR Player.app/Contents/MacOS/HDRPlayer" "$PWD/assets/test-clips/player-controls.mkv" &
```

For each control in the table, run the command below in Terminal. Within 30 seconds, click the video area of the player (not a control, which would trigger it), then press Tab until VoiceOver reaches the control. Listen to the announcement, stop pressing keys, and wait for the probe to print.

```sh
sleep 30; artifacts/human/voiceover-probe --read-current-phrase --player-pid "$(pgrep -x HDRPlayer)"
```

A spoken hint can replace the last phrase before the probe reads it, so a control passes when its name appears in either `lastPhrase` or `cursorText`.

| Control | Expected in `lastPhrase` or `cursorText` |
|---|---|
| Play or pause button | "Play" or "Pause" |
| Timeline | "Seek video" |
| Volume slider | "Volume" |
| Settings button | "Picture and subtitle settings" |

Then press Cmd+Q in the player and turn VoiceOver off with Cmd+F5. Paste the four probe outputs into #16. Also note whether you heard each phrase spoken, because the probe shows what VoiceOver reported, not that it was audible.

## Floating video (#17)

These steps check keys and buttons in the floating panel. An agent cannot check them, because synthetic key events skip the real keyboard routing. Start the player for each step with this command:

```sh
"artifacts/HDR Player.app/Contents/MacOS/HDRPlayer" "$PWD/assets/test-clips/playback/pq-30-60s.mkv"
```

The clip beeps once a second, and the main window's time display shows the position. Keep the main window's controls visible next to the panel. In #17, note PASS or FAIL for each numbered action and anything that behaved differently.

### 4. Keys work in the panel

1. Choose **View > Float Video**. The video moves to a panel at the top right of the screen, and the main window shows "Video is in the floating window."
2. Click the video in the panel.
3. Press Space. The video and the beeps stop. Press Space again. They resume.
4. Press Right. The time in the main window jumps about 5 seconds ahead. Press Left. It jumps about 5 seconds back.
5. Press Escape. The video returns to the main window.
6. Press Cmd+Q.

### 5. The panel buttons work

1. Choose **View > Float Video**.
2. Click **Pause**. The video and the beeps stop, and the button changes to **Play**. Click **Play**. They resume.
3. Click **+5 s**, then **−5 s**. The time jumps about 5 seconds ahead, then back.
4. Click **Return to Player**. The video returns to the main window.
5. Choose **View > Float Video** again, then click the panel's close button. The video returns to the main window, and the main window comes to the front.
6. Only if **Keyboard navigation** is on in System Settings > Keyboard: choose **View > Float Video**, press Tab until a panel button shows a focus ring, then press Escape. The video returns to the main window.
7. Press Cmd+Q.

### 6. Keys and buttons work after you click the panel title bar from another app

1. Choose **View > Float Video**.
2. Click the Terminal window. The menu bar now shows Terminal. Move Terminal so that it does not cover the main window's controls.
3. Click the panel's title bar once. Do not click the video.
4. Press Space. The video and the beeps stop, and Terminal does not receive the key. Press Space again. They resume.
5. Press Right. The time in the main window jumps about 5 seconds ahead. Press Left. It jumps back.
6. Click the Terminal window again, then click the panel's title bar once.
7. Click **Pause**. The video and the beeps stop. Click **Play**. They resume. Click **+5 s**. The time jumps about 5 seconds ahead.
8. Press Escape. The video returns to the main window.
9. Press Cmd+Q.
