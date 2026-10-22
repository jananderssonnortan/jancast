# Jancast — UI design

Native SwiftUI macOS app (macOS 14+, SwiftPM, no dependencies) in `app/`.
It talks to the Python backend only through the contract in `docs/API.md`.

## Principles

1. **Calm by default, deep on demand.** The main window is a player, not a
   dashboard. Everything needed to explain a failure exists, but lives in an
   opt-in Diagnostics drawer. Telemetry is *always* recorded (client ring
   buffers are fed by the 1 Hz `/api/state` poll whether or not the drawer
   is open), so opening Diagnostics after a failure shows the whole story.
2. **First-party feel.** Standard controls (Form/Picker/Toggle/Table/Menu,
   sheets, popovers), SF Symbols, system colors and materials, unified
   toolbar, menus with keyboard shortcuts, light and dark mode for free.
3. **Explain consequences in plain words.** "Video is copied, not
   re-encoded — original quality, almost no CPU" instead of "mode: copy".
4. **Answer "why did it fail?"** with a ranked list of causes and evidence
   from the backend, and charts whose reference lines say what "good" is.

## Windows and flow

### Main window (`Window "main"`, 400–560 pt wide, min 640 tall)

The TV is the screen, so the Mac shows a **remote** (`RemoteLayout`): one
440 pt column — now card, filmstrip timeline, big round transport,
audio/subtitle tiles — with the **library** under it. Always one column:
the window can't be made wider than 560 pt, so it stays remote-shaped (a
side-by-side layout for wide windows was tried and dropped). No
`NavigationSplitView`: the library is a first-class panel under the remote.
The episode in Up Next isn't repeated under Recent. The Diagnostics drawer
slides up under everything.

The toolbar carries what was a "TV pill" at the top of the remote, so nothing
is said twice: the TV menu at the left (where it plays: "Play on" while
playing, the picker with a reachability dot when ready), Open and
Diagnostics at the right. The Diagnostics glyph gets a coloured dot when the
stream has a problem (none while healthy) and bounces once when it worsens.
The window title isn't drawn (macOS 15+): the now card says what is on.

**Remote, playing** (`PlayingRemote`): the now card: poster tile, show name, "Season 1 · Episode 3" and the episode
title (from the backend's `name_info`; `Fmt` parses the file name only as a
fallback, e.g. in mock mode), **format badges** (1080p/4K, HDR, codec, "Re-encode" in orange, audio codec +
channels, CC). The **filmstrip** is the timeline: frames from the preview
thumbnails across the episode, played part dimmed, a white playhead, prepared
(grey) and TV-buffered (accent) on a 2 pt line under it; hovering or dragging
lifts an enlarged frame + time above the pointer (on demand only), `seek` on
release (the model holds the target until the TV gets there). Times and the
phase in plain words (only when not simply playing) under it. Transport: big
round −10 / play-pause (filled) / +30, small stop. Audio and subtitle tiles
re-POST `/api/play` at the current position. **Up Next** (last 2½ min of an
episode) is an inline row: Play (same TV, tracks matched by language/title)
or Not Now; never autoplays. The next episode — from Play or loaded at the
end — gets the audio/subtitle languages and stereo the session actually
played (a forced subtitle track only stands in for a forced one), unless it
was left part-way with tracks of its own. "Up next after …" on its ready
screen goes once something plays. **Media keys / Control Center / AirPods**
(`NowPlaying`) as before.

**Remote, ready** (`ReadyRemote`, a file loaded, nothing plays until Play):
the same layout (the TV picker is in the toolbar), the filmstrip is static with the playhead at the resume point ("Stopped at 27:10 ·
yesterday"), one primary **Resume 27:10** (or **Play** / **Pair & Play**) with
**Start Over** beside it, the same tiles, and one quiet cost line ("Video will
be re-encoded", "Audio is converted") with details in a popover.

Frames show everywhere (posters, film roll, scrub preview). A "no spoilers"
rule that hid frames from unwatched parts was tried and dropped: it hid
most of the timeline after a few jumps. Posters fall back to a neutral tile
("S1 · E4" or the title's initials) only while thumbnails don't exist yet.

**Library** (`LibraryPanel`): *Now Playing* (live progress), *Up Next*
(next episode of the playing or loaded file) and *Recent* (≤ 10 from
`GET /api/recent`: played and merely opened files). Rows: poster frame (only
if thumbnails already exist — `thumbs?make=0` — and from a watched part), show + "S1 · E2" or cleaned
title, "Watched" / progress + time left / "Not started". Click loads the file
into the ready view; **double-click plays it** at its resume point on the TV
it last used; context menu: Resume/Play, Start Over, Show in Finder.

While another file plays, the ready remote shows a "Now playing ›" pill back
to it. Reachability is re-probed every 5 s while visible; a user's explicit TV
choice is never overridden. *Launch restore*: the newest resumable history
entry is loaded (never auto-played). When an episode is watched to the end,
the next one is loaded ready to play. Pairing uses a PIN sheet; after success
the pending Play continues. Empty state: dashed drop target ("Drop a video or
press ⌘O") above the library.

**This Mac** (`Store/LocalPlayer`, backend `local_player.py`): a device that is
always listed (after the real TVs). The session runs unchanged; instead of an
Apple TV, an `AVPlayerView` window ("This Mac", 16:9, frame remembered) plays
`state.local_player.url`, applies the queued commands (pause / resume / seek /
stop; acked by id) and POSTs what AVPlayer sees about once a second to
`/api/local/report` (timer in the common run-loop modes: an open menu or
⌘O panel must not silence it — the backend fails the session after 10 s
without a report), which the backend turns into the same playback-info an
Apple TV sends. "Waiting for data" and the rate come from `timeControlStatus`
(`isPlaybackBufferEmpty` goes stale after seeks). The session's subtitle
rendition is selected explicitly. The window is ordered front without
becoming key, so Space and the arrows stay with the main window until the
user clicks it. Closing the window = Stop. A failure refreshes Recents. Resume history is
saved (unlike the simulator). Not in mock mode.

### Diagnostics drawer (opt-in)

Toggled with View ▸ Show Diagnostics (⌥⌘I; ⌥⌘D
is taken by macOS for Dock hiding), the toolbar button, or the
indicator popover; resizable from its top edge (height remembered). Optional
Settings toggle "Open Diagnostics automatically when playback fails"
(default off). While it is open the app POSTs `/api/telemetry
{"level":"detailed"}` (1 Hz latency probe), and `basic` when it closes.

Header: tabs **Summary · Charts · Segments · Events** (problem counts in the
titles), the one-line verdict (status glyph + headline) on every tab, Copy
Report, close.

- **Diagnosis banner**: status color + symbol (phase appended only when it
  adds information — never "FAILED · FAILED"), headline, the raw
  `session.error` in a selectable monospaced box with a Copy button (the
  duplicate "Error: …" details line is hidden), details, Apple TV
  `playback.error` / `prep.error` in red, and *Likely causes* ranked by
  confidence with a confidence bar, percentage ("ruled out" < 5 %) and
  evidence. Collapsed to a one-line summary when status is ok.
- **Summary**: the diagnosis banner, then **KPI tiles** (6 across, 3×2 when narrow): Throughput (avg10, now, needed,
  recent segment speed), TV buffer, Prep headroom / Done, Round trip (avg,
  loss), Stalls (count, total), HTTP (errors, client aborts). Each has a
  status glyph and a colored edge when warning or worse. Throughput health
  is judged by *segment delivery speed* (realtime ratio of recent segments),
  because a full TV buffer idles the link on purpose: low average throughput
  with a full buffer is not a problem.
  A collapsed *Stream details* row holds video mode, bitrate, prepared
  segments, stream URL, telemetry level and the TV's last report.
- **Charts**: timeline charts (Swift Charts; range picker 1 / 5 / 15 min / Session;
  long ranges are bucketed to ≤ 600 points — mean for rates, min for
  buffers, max for RTT). All charts share the x-domain and one hover
  crosshair; each card's header reads out its value at the hovered second.
  1. *Throughput to Apple TV*: per-second area (bursts clipped at 3× the
     bitrate so the reference stays readable) + 10 s average line + dashed
     "needed" rule at `stream_bitrate_bps`.
  2. *TV buffer ahead* (s) with stall intervals (`tv_buffer_empty`) as red
     bands.
  3. *Round trip* (ms): line through measured samples (works at 1 Hz and at
     the 5 s "basic" rate), red × for timeouts. A missing RTT is a gap, not a
     timeout — see contract note below.
  4. *Prep headroom* (s) with a 2-segment danger rule; caption says when the
     whole file is prepared (encoder ruled out).
  5. *ffmpeg speed* (× realtime) with a 1× rule. (Separate charts instead of
     a dual axis.)
- **Segments**: summary (sent / fast / marginal / too slow-failed / median
  ratio), a bar per segment of *time to send* vs. the dashed segment
  duration (6 s = realtime; green ≥ 1.5×, yellow 1–1.5×, red < 1× or
  failed), and a `Table` of requests (time, segment, kind, status, size,
  send time, Mbit/s, realtime ×, error); filters "Segments only" /
  "Slow or failed only"; ⌘C copies selected rows, Copy copies all visible.
- **Events**: newest first, level filter (All / Warnings & Errors / Errors),
  source menu, "This session only", search, ⌘C / Copy.
- **Copy Report** (⇧⌘C): plain-text summary for sharing (session, diagnosis
  + suspects, playback/prep/network numbers, recent warnings/errors).

## Visual language

- Status colors are reserved for state and always paired with a symbol:
  good = green `checkmark`, warning = yellow `exclamationmark.triangle`,
  serious = orange `exclamationmark.octagon`, critical = red `xmark.octagon`.
- Series colors are identity only, one per measure, consistent between tiles
  and charts: throughput blue, buffer teal, headroom indigo, ffmpeg purple,
  RTT cyan; references are secondary-ink dashed rules; incidents (stalls,
  timeouts) are red.
- Text stays in primary/secondary ink; axes carry units (Mbit/s, s, ms,
  × realtime); grids are faint; every multi-mark chart has a small legend.

## Keyboard

⌘O open · ⌘↩ play/resume · Space pause/resume · ← / → skip −10 / +10 s ·
⌘← / ⌘→ skip −30 / +30 s · ⌘. stop · ⌘R scan for Apple TVs · ⌥⌘I
Diagnostics · ⇧⌘C copy report.

Space and plain arrows are handled by a local key monitor, only in the main
window while the player is shown and never when a text field has focus
(Diagnostics tables and search keep their arrows). Skips use
`/api/control {"action":"skip","seconds":±N}` (in place on the TV): clicks
and key presses within 300 ms of each other are merged into one request
(3 quick → presses = one +30 s); a held arrow key accumulates its repeats
and sends once, 300 ms after it is released,
the scrubber jumps optimistically at once and `/api/state` corrects it, and
a small "+30 s" bubble above the playhead fades after 0.8 s. The transport
buttons (−10 / +30) use the same path. The Playback menu lists all skips.

## Engineering notes

- `Backend` protocol with `LiveBackend` (spawns
  `.venv/bin/python -m jancast serve --api-port 0` in `JANCAST_BACKEND_DIR`,
  parses `JANCAST_READY`, keeps stdin open, shows stderr tail on failure,
  closes stdin + SIGTERM on quit; `JANCAST_API_PORT` attaches to a running
  backend) and `MockBackend` (`--mock` / `JANCAST_MOCK=1`).
- Activity Monitor: the backend runs as "Jancast Backend" — a copy of the
  venv's Python launcher in `~/Library/Caches/jancast/bin`, refreshed when
  Python changes, pointed at the venv with `__PYVENV_LAUNCHER__` (plain
  `.venv/bin/python` if it won't start). ffmpeg and `jancast-ocr-*` run under it.
- `JANCAST_LOCAL_ONLY=1` (automated test runs): the backend never scans for
  Apple TVs and refuses to play to anything but This Mac or a simulated device.
- Housekeeping: work dirs go when a session ends (and stale ones at startup);
  thumbnails keep 40 files' worth; cached subtitle texts keep the 200 most
  recently used; only the current OCR helper build is kept.
- Decoding is lenient: optionals everywhere, enum-like fields as strings
  mapped with fallbacks, lossy arrays for samples/requests/events.
- Ring buffers: samples (4 h), requests (8000), events (3000); samples and
  requests reset when `session.id` changes (a track switch is a new session);
  events persist across sessions.
- Mock: 4 Apple TVs (online paired + last used, online needs pairing — any
  4-digit PIN works, not responding, offline), probe with 4 audio / 5
  subtitle tracks (one PGS), 3 recents (mid-way with resume — restored on
  launch, watched, 10 % in). Playback runs preparing → connecting →
  buffering → playing; ~60 s in the Wi-Fi degrades (segments < 1×
  realtime, RTT spikes and timeouts, a client abort, buffer drains, one
  stall; diagnosis warning → failing with network as top suspect) and
  recovers at ~105 s. Picking the PGS subtitle switches to a ~1.4× re-encode.
  `JANCAST_MOCK_SPEED=N` runs the simulation faster,
  `JANCAST_MOCK_AUTOPLAY=1` starts playing the sample file at launch,
  `JANCAST_MOCK_FAIL=N` makes the session fail N sim-seconds in (with a
  `session.error` message) to exercise the failure UI.
- Thumbnails (`Store/Thumbnails`): one `Thumbnails` object follows the
  file on screen (the playing file in the player, else the loaded one),
  polls `/api/thumbs` until `done`, and loads JPEGs on demand into a ≤ 240
  image cache; `image(at:)` returns the nearest loaded frame while the exact
  one loads, so hovering never flickers. No live SwiftUI blur, materials or
  repeating symbol effects over large areas: any animation redraws the whole
  layer every frame (a pulsing glyph over a live blur kept the main thread
  ~65 % busy and stalled the UI). Mock mode draws its thumbnails.
- `JANCAST_SNAPSHOT_DIR` / `_PLAN` / `_FULL` / `_SIZE` / `_QUIT` /
  `_HOVER`: in-app window capture to PNG (diagnostics tab names open the
  drawer on that tab; `_HOVER=0.3` pretends the pointer hovers the filmstrip
  at 30 %), plus `do-arrowright…` / `do-pause` steps; `JANCAST_MOCK_START=2600`
  makes mock autoplay start near the end (Up Next) (development aid; known
  limits: Form/List content and some materials render blank).

## Contract notes

- RTT timeouts: the Sample spec says `rtt_ms` is null on timeout, but with
  the 5 s "basic" probe rate most seconds are simply not probed. The app
  treats a second as a timeout only if `rtt_timeout: true` is present
  (proposed optional field), or — as a fallback — if `rtt_ms` is an explicit
  `null` *and* a `network` warning/error event is within ±1 s. Proposal:
  omit `rtt_ms` (or send null) for unprobed seconds and add
  `"rtt_timeout": true` on timeouts.
