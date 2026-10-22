# Jancast

Play your own video files — MKV included — on an Apple TV from your Mac, with
the audio track and subtitles you choose. A native macOS app works as the
remote, and opt-in diagnostics explain *why* a stream stutters or fails.

<p align="center">
  <img src="docs/screenshots/player.png" width="260" alt="Playing: the remote with the colour timeline">
  <img src="docs/screenshots/preview.png" width="260" alt="Hovering the timeline previews that moment">
  <img src="docs/screenshots/ready.png" width="260" alt="A file loaded, ready to resume">
</p>
<p align="center">
  <img src="docs/screenshots/diagnostics.png" width="260" alt="Diagnostics: summary">
  <img src="docs/screenshots/charts.png" width="260" alt="Diagnostics: charts">
</p>
<p align="center"><sub>Playing · previewing a moment on the colour timeline · ready to resume ·
Diagnostics summary and charts</sub></p>

## Features

- **Plays what the Apple TV can't open itself.** MKV and other containers are
  turned into a stream the Apple TV understands, on the fly. H.264/HEVC video and
  AAC/AC-3/E-AC-3 (Atmos) audio are copied, not re-encoded — full quality, and
  playback starts in about a second.
- **Your choice of audio and subtitles**, switchable while playing. Text
  subtitles (SRT, ASS, WebVTT, sidecar `.srt` files) and Blu-ray picture
  subtitles (PGS, read as text with macOS's built-in OCR) show without
  re-encoding. Out of sync? Shift them in half-second steps.
- **A remote, not a player**: what's on with its format (1080p · HEVC · E-AC-3 5.1 ·
  CC), the film's colour palette as the timeline with frame previews on hover,
  big transport buttons, Up Next for series, and your recent files to resume.
- **TV volume** from the Mac (↑ / ↓, or optionally the Mac's volume keys), media
  keys and Control Center, and moving playback to another Apple TV mid-film.
- **"This Mac" player** to use it without a TV.
- **Diagnostics on demand**: a verdict with the likely cause (network, encoder,
  Apple TV, source file, server), live charts, every segment request and an
  event log — recorded all the time, so you can look *after* something went wrong.

## How it works

The Apple TV can play HLS streams over AirPlay, but not MKV files. Jancast probes
the file with ffprobe, remuxes it into HLS (fragmented MP4 segments) with ffmpeg,
serves that from your Mac over HTTP, and tells the Apple TV to play the URL using
[pyatv](https://pyatv.dev). With fast start, segments are made as the TV asks for
them, from the file's keyframe index, so nothing waits for a full conversion.
A small Python backend does the work; the SwiftUI app talks to it over localhost.

## Requirements

- macOS 14 or later, with Xcode's command line tools (`xcode-select --install`)
- [Homebrew](https://brew.sh), for ffmpeg
- Python 3 (tested with 3.14)
- An Apple TV on the same network (tested with tvOS 26) — or none, using "This Mac"

## Install

```sh
brew install ffmpeg
git clone https://github.com/jananderssonnortan/jancast.git
cd jancast
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
bash app/build-app.sh          # builds build/Jancast.app
open build/Jancast.app
```

The app runs its backend from the cloned folder, so leave `build/Jancast.app`
where it is (or set `JANCAST_BACKEND_DIR` to the folder). To update, `git pull`
and run `bash app/build-app.sh` again.

**First run:** pick your Apple TV in the menu at the top left. The first time
you play to it, it shows a PIN to type into Jancast. macOS asks whether to
accept incoming network connections — allow them, because the Apple TV fetches
the stream from your Mac.

## Using it

Open a video by dropping it on the window, with ⌘O, or from the library. It
opens ready to play — **Resume** where you left off or **Start Over** — and
nothing starts until you press Play. Double-click a file in the library to start
it straight away.

| Keys | Action |
|---|---|
| Space | Play / pause |
| ← / → | Back / forward 10 s (quick presses add up) |
| ⌘← / ⌘→ | Back / forward 30 s |
| ↑ / ↓ | TV volume |
| ⌘. | Stop |
| ⌘↩ | Play / resume the loaded file |
| ⌘O | Open a video |
| ⌥⌘I | Show / hide Diagnostics |

- **Timeline**: hover to see a frame and its time, click or drag to jump. On the
  ready screen a click starts playback at that point.
- **Audio and subtitles**: change them from the two tiles; playback restarts at
  the same spot. Series remember your choice for the next episode.
- **TV volume** goes through the Apple TV, so it must be set up to control your
  TV's volume (Apple TV Settings → Remotes and Devices → Volume Control).
  *Playback → Mac Volume Keys Control the TV* makes the Mac's volume keys do it
  while Jancast is in front; this needs the Accessibility permission.
- **This Mac**: choose it in the device menu to play in a window on the Mac.
  Double-click for full screen.
- **Diagnostics**: the button at the top right (a coloured dot appears on it when
  something is wrong). The Summary names the likely cause; Charts, Segments and
  Events show the detail.

Want to look around without a TV or video? `open build/Jancast.app --args --mock`
runs the app against a simulated backend.

## Command line

The backend also works on its own:

```sh
bin/jancast movie.mkv                          # asks for tracks and device
bin/jancast movie.mkv -a eng -s swe -d "Living Room"
bin/jancast movie.mkv -s off --from-start
bin/jancast --info movie.mkv                   # list the tracks
bin/jancast --devices                          # Apple TVs on the network
bin/jancast --pair                             # pair once (PIN on the TV)
```

Tracks can be given as numbers, language codes or part of their title.

## What gets re-encoded

| Source | Result |
|---|---|
| H.264 / HEVC video | copied (HEVC tagged `hvc1`, Dolby Vision kept) |
| AV1, VP9, MPEG-2, … video | re-encoded with VideoToolbox (hardware) |
| AAC, AC-3, E-AC-3 (incl. Atmos) audio | copied |
| DTS, TrueHD, FLAC, Opus, … | E-AC-3 640k (surround) or AAC (stereo) |
| Text subtitles (SRT, ASS, WebVTT) | soft subtitles |
| Blu-ray picture subtitles (PGS) | read as text (OCR, ~10 s the first time per file, then cached) → soft subtitles |
| Other picture subtitles (VobSub, DVB) | burned into the picture → video re-encode |

## Troubleshooting

- **The Apple TV isn't listed**: it must be on the same network and awake; use
  *Scan for Apple TVs* in the device menu. AirPlay must be allowed for everyone
  on the network, or for the current user (Apple TV Settings → AirPlay and HomeKit).
- **It connects but never plays**: check that macOS didn't block incoming
  connections (System Settings → Network → Firewall).
- **Something stutters or fails**: open Diagnostics (⌥⌘I). The Summary names the
  likely cause, and *Copy Report* gives a text report to share in an issue.

## Development

```sh
.venv/bin/python -m unittest discover -s tests                     # JANCAST_SKIP_SLOW=1 skips the ffmpeg tests
.venv/bin/python scripts/e2e_sim.py                                # end to end against a simulated Apple TV
.venv/bin/python -m jancast serve --api-port 8722 --simulate slow  # backend with a fake TV
cd app && swift build                                              # just the app
```

The simulated Apple TV fetches the real stream with the profiles `good`, `slow`,
`flaky`, `tv-error` and `stuck`; the end-to-end script checks that the diagnosis
blames the right cause in each. `JANCAST_LOCAL_ONLY=1` keeps a run away from real
Apple TVs.

[`docs/DESIGN.md`](docs/DESIGN.md) describes the app, and [`docs/API.md`](docs/API.md)
the app ↔ backend API. Settings and history live in `~/.config/jancast/`, caches in
`~/Library/Caches/jancast/`.

## Known limitations

- Text subtitles can't be burned in (Homebrew's ffmpeg lacks libass); they are
  always shown as soft subtitles.
- HDR is lost when video has to be re-encoded (AV1/VP9 HDR, or burning in picture
  subtitles on 10-bit HDR).
- Without fast start (e.g. re-encoded video), the stream needs temporary disk
  space about the size of the file.

## Licence and credits

Jancast is MIT-licensed — see [`LICENSE`](LICENSE). It stands on
[pyatv](https://pyatv.dev) for talking to the Apple TV and
[FFmpeg](https://ffmpeg.org) for everything video; both are installed separately,
not bundled. [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) lists every
dependency and its licence, with notes on the icon and the screenshots.

Apple, Apple TV, AirPlay, macOS and tvOS are trademarks of Apple Inc. Jancast is
an independent project, not affiliated with or endorsed by Apple. Use it with
video you have the right to play.
