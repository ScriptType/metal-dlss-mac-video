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

The lifecycle recorder writes what the player did around a real sleep. `scripts/check-sleep-wake-log.py` then judges it. The recorder only counts a cycle when macOS reports a real kernel sleep followed by power-on, so closing the lid is required.

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

For each control in the table, run the command below in Terminal. Within 8 seconds, click the player window and move the VoiceOver cursor onto the control with Control-Option-Right Arrow. Listen to the announcement, then wait for the probe to print.

```sh
sleep 8; artifacts/human/voiceover-probe --read-current-phrase --player-pid "$(pgrep -x HDRPlayer)"
```

| Control | Expected in `lastPhrase` |
|---|---|
| Play or pause button | "Play" or "Pause" |
| Timeline | "Seek video" |
| Volume slider | "Volume" |
| Settings button | "Picture and subtitle settings" |

Then press Cmd+Q in the player and turn VoiceOver off with Cmd+F5. Paste the four probe outputs into #16. Also note whether you heard each phrase spoken, because the probe shows what VoiceOver reported, not that it was audible.
