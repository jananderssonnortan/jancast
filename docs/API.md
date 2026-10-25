# jancast local API (app <-> backend contract)

The macOS app (SwiftUI, `app/`) is the UI. It launches the Python backend as a
child process and talks to it over HTTP on `127.0.0.1` (localhost only). All
endpoints are JSON. Times are Unix epoch seconds (float). Bitrates are bits/s.
Any field documented as `|null` may be null when unknown / not yet measured.

The HLS stream for the Apple TV is served by a *separate* server bound to the
LAN; the app never talks to it directly.

## Launching the backend

```
<backend_dir>/.venv/bin/python -m jancast serve --api-port 0
```
run with working directory `<backend_dir>`. `<backend_dir>` is the env var
`JANCAST_BACKEND_DIR`, defaulting to the project folder two levels above the app bundle (`<project>/build/Jancast.app`), else `~/development/jancast`.
Once listening, the backend prints exactly one line to stdout:
```
JANCAST_READY {"port": 51234}
```
The backend exits when its stdin is closed (i.e. when the app quits), so the
app should keep a pipe to the child's stdin open. Backend logs go to stderr.
`GET /api/health` → `{"ok": true, "version": "0.1", "missing_tools": []}`.
`missing_tools` lists `ffmpeg`/`ffprobe` if they can't be found (the backend
also looks in /opt/homebrew/bin, /usr/local/bin and /opt/local/bin, since apps
started from Finder get a minimal PATH).

## Setup endpoints

Files are chosen natively (open panel / drag & drop); the app sends the path.

### `GET /api/probe?path=<file>`
```json
{
  "path": "...", "name": "night.train.s06e01.mkv", "size_bytes": 3859110437,
  "downloading": false, "duration_s": 3011.4,
  "name_info": {"title": "Night Train S6 · E1", "show": "Night Train", "season": 6,
                "episode": 1, "episode_end": null, "episode_title": null, "year": null,
                "kind": "episode"},
  "video": {"codec": "h264", "width": 1920, "height": 960, "hdr": false,
            "mode": "copy", "reason": null},
  "audio": [
    {"id": 1, "label": "eng (eac3, 6ch)", "lang": "eng", "title": "", "codec": "eac3",
     "channels": 6, "default": true, "forced": false, "mode": "copy"}
  ],
  "subtitles": [
    {"id": 1, "label": "eng  English (subrip)", "lang": "eng", "title": "English",
     "codec": "subrip", "default": false, "forced": false, "external": false,
     "mode": "soft"}
  ],
  "default_audio": 1,
  "default_subtitle": 0,
  "resume": null,
  "next": {"path": "...", "name": "night.train.s06e02.mkv", "season": 6, "episode": 2,
           "name_info": {"title": "Night Train S6 · E2", "show": "Night Train", "season": 6,
                         "episode": 2, "episode_end": null, "episode_title": null,
                         "year": null, "kind": "episode"}}
}
```
- `video.mode`: `"copy"` (remux, fast) or `"reencode"` (with `reason`, e.g. `"AV1 not supported by Apple TV"`).
- `external` subtitles are files: `movie.srt` / `movie.en.srt` next to the video
  or in a subfolder (a 2–3 letter folder name gives the language), any file in
  `Subs/movie/`, and, when the video is alone in its folder, every file in a
  `Subs` / `Subtitles` folder named by language only (`English.srt`,
  `SDH.eng.srt`, `Forced.eng.srt`). Language (2-letter where one exists),
  title ("SDH", "Canadian") and forced come from the name; exact copies are
  listed once.
- audio `mode`: `"copy"` or `"transcode"`.
- subtitle `mode`: `"soft"` (text, toggleable), `"ocr"` (picture subtitles, PGS, shown as text:
  recognised with macOS Vision on first use, ~10 s per film, then cached — no re-encode) or
  `"burn"` (other picture subtitles, or no Xcode command line tools: forces a video re-encode).
- ids are 1-based; subtitle id `0` = off.
- `next`: the next episode in the same folder (same show name, see `name_info`;
  the next season's first episode if this was the last), or `null`. Its
  `season` is null for absolute numbering ("Show - 12"). Probing a file also starts making its preview thumbnails and lists it
  in Recents (as opened, position 0, at the top; a file already listed keeps
  its place);
  `&remember=0` skips the Recents part.
- `downloading`: the file is a download in progress (`movie.mkv.part`, also
  `.!qB`, `.!ut`, `.crdownload`). It plays anyway; missing pieces show as a
  short glitch. Once the download client renames it to `movie.mkv`, everything
  follows the new name: the running session (`session.file`, ffmpeg restarts),
  the history entry, and a probe of the new path, which keeps the old probe's
  thumbnails and subtitles. A file moved to another folder is not followed.

### What a file is (`name_info`)
Wherever the API names a file (probe, `next`, history entries, `session.file`)
it carries `name_info`, the backend's reading of the file name (and its
folders when the name lacks something: `Show (2019)/Season 01/S01E02.mkv`).
The app shows this instead of parsing names itself.
- `kind`: `"episode"` or `"movie"` (anything that is not recognisably an episode).
- `title`: one-line display title, never empty: `"Night Train S6 · E3"`,
  `"Show S1 · E2–3"` (multi-episode), `"Lantern E12"` (no season),
  `"The Daily Show 2024-03-15"` (air date), `"Quiet Hours (2025)"`; for a name it
  can't make sense of, the file name without extension and dots.
- `show`: series name without year or tags (null for movies, or when neither
  the name nor the folders say).
- `season` / `episode`: numbers, or null (`season` null for absolute
  numbering; both null for a daily show). `episode_end`: last episode of a
  multi-episode file (`S01E02E03` → 3), else null.
- `episode_title`: what follows the episode tag, minus scene noise
  (`"'90 - Autumn"`), or the air date of a daily show; else null.
- `year`: release year from the name or folder, else null. For movies `title`
  ends with it in parentheses.
- Scene noise (resolution, source, codecs, audio, HDR/DV, `REPACK`, `PROPER`,
  `Directors Cut`, `[site.to]`, `-GROUP`) is left out; all-lowercase names are
  title-cased. Bare 3–4 digit numbers ("Show - 102") are not taken as episodes.

### Fast start (`prep.on_demand: true`)
For MKV files with copied video the backend plans every segment from the
file's keyframe index and serves complete VOD playlists at once; segments are
made when the TV requests them (a jump restarts ffmpeg there). `prep` then
describes only the window being prepared ahead of the TV: `prepared_s` is
the end of the segments made without a gap from the one the TV asked for last
(by any ffmpeg run, about 3 minutes past the playhead), `progress` is not a
progress bar, `speed` is null while it waits for the TV to catch up, and `done`
means it reached the end of the file. The app hides "Preparing the rest" for
such sessions. Little prepared ahead only counts against preparation in the
diagnosis while the TV also plays on a short buffer (right after a jump nothing
is made there yet).

### `GET /api/thumbs?path=<file>`
Scrubber preview thumbnails, made in the background (a keyframe-only decode,
a few seconds for an episode; HDR is tone-mapped to SDR) and cached in
`~/Library/Caches/jancast/thumbs/`. Poll until `done`.
```json
{"url": "/api/thumbs/3f1c0d9a2b7e4c51/", "interval_s": 10, "width": 480, "height": 270,
 "count": 120, "total": 302, "done": false, "failed": false, "palette": null}
```
- Thumbnail `n` (1-based) is `GET <url><n>.jpg` (`image/jpeg`) and shows the
  video at `(n - 1) * interval_s` seconds. `1 … count` are ready; others are 404.
- `total` is the expected count (exact once `done`). `failed`: ffmpeg could not
  make them; the app simply shows no previews.
- `palette`: once done, `<url>palette.png` — one colour per thumbnail side by
  side, one pixel high (the film as bands of colour; the app's timeline), else
  `null` while it is being made.
- `&make=0` only reports what already exists and never starts ffmpeg (for
  posters in lists).

### Resume / history
The backend remembers, per file, where playback stopped and which tracks and
device were used (saved every 10 s while playing and on stop/finish/quit).
A history entry:
```json
{"path": "...", "name": "night.train.s06e01.mkv", "size_bytes": 3859110437, "mtime": 1760975760.0,
 "position": 2530.4, "duration": 3011.4, "watched": false, "resume_position": 2530.4,
 "audio": 1, "subtitle": 3, "device_id": "AA:BB:CC:DD:EE:FF", "stereo": false,
 "subtitle_delay": 0.0, "updated_at": 1760977000.0,
 "name_info": {"title": "Night Train S6 · E1", "show": "Night Train", "season": 6, "episode": 1,
               "episode_end": null, "episode_title": null, "year": null, "kind": "episode"}}
```
- `resume_position`: where to resume, or `null` when there is nothing worth
  resuming (under 30 s in, or `watched` = played past 95 % / to the end).
- Entries vanish when the file is gone or changed (size/mtime differ). A
  download in progress only has to exist; its entry moves to the finished file.

`GET /api/recent?limit=20` → `{"items": [<history entry>, ...]}` newest first:
played files and files that were only opened (`position` 0, `audio`/`subtitle`/`device_id` null).

`GET /api/probe` additionally returns `"resume": <history entry> | null` for that file.

To resume: `POST /api/play` with the entry's `audio`, `subtitle`, `device_id`,
`stereo`, `subtitle_delay` and `"start_position": resume_position`.

### `GET /api/devices?refresh=1` / `GET /api/devices?probe=1`
- `refresh=1`: full Bonjour scan (≈4 s) plus a reachability probe.
- `probe=1`: only re-probe reachability of known devices (≤ 1.5 s, no scan). The
  app can call this every ~5 s while the device picker is visible to keep the
  indicators live.
- neither: return the cache (a scan is done first if there is none).

Only video-capable AirPlay receivers are listed (speakers and this Mac are
filtered out). Devices seen in earlier scans stay listed (persisted) with
`status: "offline"` so a TV that is switched off doesn't just vanish.
```json
{
  "scanning": false,
  "devices": [
    {"id": "AA:BB:CC:DD:EE:FF", "name": "Living Room", "address": "192.168.1.20",
     "model": "Apple TV 4K (gen 3)", "paired": true, "pairing_required": true,
     "last_used": true,
     "status": "online", "reachable": true, "rtt_ms": 3.2,
     "last_seen": 1760977000.1, "probed_at": 1760977000.1}
  ]
}
```
- `status`: `online` (answers on its AirPlay port; `rtt_ms` = TCP connect time) |
  `not_responding` (advertised but doesn't answer — usually asleep, may wake on
  Play; or blocked by the network) | `offline` (seen before, not on the network now).
- Order: online first (lowest rtt first), then not_responding, then offline.
- `POST /api/play` to an `offline` device returns `{"ok": false, "error": "... is offline"}`.

### `POST /api/pair` `{"device_id": "..."}`
Starts pairing; the TV shows a PIN. Afterwards `state.pairing` is
`{"device_id": "...", "awaiting_pin": true, "error": null}`.

### `POST /api/pair/pin` `{"pin": "1234"}`
Completes pairing. Response `{"ok": true}` or `{"ok": false, "error": "..."}`.

### `POST /api/play`
```json
{"path": "...", "audio": 1, "subtitle": 0, "device_id": "...", "stereo": false,
 "start_position": 0, "subtitle_delay": 0.0}
```
`start_position` (optional, seconds) starts playback there — used to switch
audio/subtitle track mid-playback: the app re-POSTs `/api/play` with the new
track ids and the current `playback.position`. `subtitle_delay` (optional,
seconds, −60…60; + shows subtitles later) shifts the subtitles; changing it
mid-playback is a re-POST like a track switch. Picture subtitles (`mode`
`"ocr"`) are recognised as text before playback starts if that has not
happened yet (~10 s the first time).

### `GET /api/ocr?path=<file>&subtitle=<id>`
Starts (or reports) the text recognition of a picture subtitle track, so the
app can do it as soon as the track is chosen:
`{"status": "working", "progress": 0.4, "error": null}` — `status` is
`ready`, `working`, `failed`, `unavailable` (no Xcode command line tools) or
`not_needed` (a text track). After the quick pass is `ready`, a more accurate
pass runs in the background and replaces it for later plays.
Starts a session (stops any running one). Response `{"ok": true}` or
`{"ok": false, "error": "..."}`. Progress is then followed through `/api/state`.

### `POST /api/control`
`{"action": "pause" | "resume" | "stop" | "seek" | "skip" | "volume", "position": 1234.5, "seconds": -10, "step": "up"}`
(`position` only for seek, absolute seconds; `seconds` only for skip, relative,
negative = back; `step` "up" / "down" or `level` 0–100 for volume — the TV's
volume through the Apple TV, which works it over HDMI-CEC or IR as set up in
its Remotes and Devices settings; an error for This Mac and simulated devices). On a real Apple TV seek and skip move the playhead in place
(~50 ms, via MediaRemote); if that is unavailable the backend falls back to
restarting playback at the target (~2 s rebuffer).
Response `{"ok": true}` / `{"ok": false, "error": "..."}`.

### `POST /api/telemetry` `{"level": "basic" | "detailed"}`
Telemetry is always collected — it is passive and measured at ~0.01 % of a CPU
core — so history exists when something fails. The level only controls the
one *active* measurement, the latency probe to the Apple TV:
`basic` (default) probes every 5 s, `detailed` every 1 s. The app sets
`detailed` while the Diagnostics window is open and `basic` when it closes.
Response `{"ok": true}`; current level is `state.telemetry_level`.

## Live state

### `GET /api/state?since=<seq>`
Polled by the UI about once per second. `since` is the `seq` from the previous
response (omit or `0` on first load). Collections (`samples`, `requests`,
`events`) only contain items with `seq > since`; with `since=0` they contain the
most recent history (≤ 900 samples, ≤ 400 requests, ≤ 300 events).
A new session resets nothing in seq numbering; the UI detects a new session
via `session.id` changing and should clear its charts.

```json
{
  "seq": 18234,
  "now": 1760977000.2,
  "phase": "playing",
  "telemetry_level": "basic",
  "pairing": null,
  "session": {
    "id": "a1b2c3",
    "started_at": 1760976000.0,
    "file": {"path": "...", "name": "...", "size_bytes": 3859110437, "duration_s": 3011.4,
             "name_info": {"title": "Night Train S6 · E1", "show": "Night Train", "season": 6,
                           "episode": 1, "episode_end": null, "episode_title": null,
                           "year": null, "kind": "episode"}},
    "video": {"codec": "h264", "width": 1920, "height": 960, "mode": "copy", "reason": null,
              "out_codec": "h264"},
    "audio": {"id": 1, "label": "eng (eac3, 6ch)", "codec": "eac3", "channels": 6,
              "mode": "copy", "out_codec": "eac3"},
    "subtitle": {"id": 3, "label": "swe  Svenska (subrip)", "codec": "subrip", "mode": "soft",
                 "delay": 0.0,               // seconds, + = later
                 "in_stream": true,          // false: preparing them failed, playing without
                 "text": null},              // mode "ocr": "fast" | "accurate" recognition
    "stereo": false,
    "device": {"id": "...", "name": "Living Room", "address": "192.168.1.20",
               "model": "Apple TV 4K (gen 3)"},
    "stream_url": "http://192.168.1.10:53211/master.m3u8",
    "stream_bitrate_bps": 10250000,
    "segment_duration_s": 6,
    "segments_ready": 480,
    "segments_total": 502,
    "start_position": 0.0,         // where this session started (resume / track switch)
    "last_seek_at": null,          // epoch of the latest seek, null if none
    "volume": {"supported": true,  // the TV's volume can be changed (control "volume")
               "level": null},     // 0-100 when the device reports it (rarely for a TV)
    "timing": {"start_s": 1.3,     // Play → the TV playing (null until then)
               "seek_s": null},    // the latest jump → playing again
    "error": null                  // the raw failure message when phase is "failed"
  },
  "prep": {
    "progress": 1.0, "speed": 412.0, "prepared_s": 3011.4, "done": true,
    "on_demand": false,            // fast start: segments made on request (see below)
    "fast_start": null,            // fast start only: {"segment_requests", "waited",
                                   //  "restarts", "wait_last_ms", "wait_median_ms",
                                   //  "wait_max_ms"} - how often and how long the TV
                                   //  waited for a segment to be made
    "stage": "video",              // "subtitles": reading picture subtitles as text (progress)
    "error": null
  },
  "playback": {
    "position": 812.3, "duration": 3011.4, "rate": 1.0,
    "buffered_ahead_s": 54.0, "buffer_empty": false, "buffer_full": false,
    "likely_to_keep_up": true, "ready_to_play": true,
    "stall_count": 1, "stalled_s_total": 4.0,
    "last_report_at": 1760976999.6,
    "error": null                 // string when the Apple TV reported a player error
  },
  "network": {
    "tx_bps_now": 21500000, "tx_bps_avg10": 12800000,
    "rtt_ms": 4.1, "rtt_ms_avg": 5.0, "rtt_loss": 0.0,
    "http_errors": 0, "client_aborts": 0
  },
  "diagnosis": {
    "status": "warning",
    "headline": "Network throughput is close to the stream bitrate",
    "details": ["Average delivery 11.2 Mbit/s vs. 10.3 Mbit/s needed", "TV buffer dropped to 3 s at 13:42"],
    "suspects": [
      {"cause": "network", "confidence": 0.7, "evidence": "Segment downloads averaging 0.9x realtime"},
      {"cause": "encoder", "confidence": 0.0, "evidence": "Stream fully prepared"}
    ]
  },
  "local_player": null,           // see "This Mac" below; null unless playing to it
  "samples": [ /* Sample, 1 per second */ ],
  "requests": [ /* Request */ ],
  "events": [ /* Event */ ]
}
```

- `phase`: `idle | preparing | connecting | buffering | playing | paused | stalled | finished | failed | stopped`
- `diagnosis.status`: `ok | warning | failing | failed | unknown`
- `suspects[].cause`: `network | encoder | device | source | server`
- With no session (`phase: "idle"`), `session`, `prep`, `playback` and `network`
  are all `null`. `pairing` is `null` unless a pairing is in progress or failed.
  `playback` fields are null before the TV reports.

### "This Mac" (local player window)
`GET /api/devices` always lists a device `"id": "LOCAL:this-mac"`, `"name": "This
Mac"` (online, no pairing, after the real TVs). Playing to it runs the same
session (preparation, HLS server, telemetry, resume history), but the app plays
the stream in its own window with AVPlayer instead of an Apple TV doing it.
While a session plays to it, `/api/state` carries:
```json
{"url": "http://127.0.0.1:53211/master.m3u8", "start_position": 812.0, "active": true,
 "commands": [{"id": 3, "action": "seek", "position": 900.0}]}
```
- The app opens its player window for `url` (seeking to `start_position`
  first) while `active`, and closes it when `active` turns false.
- `commands`: `pause | resume | seek (position) | stop`, oldest first, from
  `/api/control` (skips arrive as seeks). Apply each once, then acknowledge the
  highest applied `id` with `ack` in the next report; acknowledged commands are
  dropped. A report that doesn't acknowledge a queued seek yet is taken as
  showing the spot before the jump and ignored. `stop` (also queued when the
  session ends) means close the window.

`POST /api/local/report`, about once a second and on changes:
`{"position": 812.4, "duration": 3011.4, "rate": 1.0, "ready_to_play": true,
"buffer_empty": false, "buffer_full": false, "likely_to_keep_up": true,
"loaded_ranges": [{"start": 800.0, "duration": 64.0}], "ack": 3,
"ended": false, "closed": false, "error": null}` → `{"ok": true}`, or 409 when
nothing plays to This Mac. Omit `duration` until the media is loaded (like an
Apple TV). `ended`: the media played to the end (session finishes); `closed`:
the user closed the window (counts as Stop: position saved, not "watched");
`error`: a player error message (session fails with it). If no report arrives
within 30 s of starting, or none for 10 s while playing, the session fails.

## Errors
Failed requests return a non-200 status (`400` for bad input / refused actions,
`404` unknown route, `500` unexpected) with body `{"ok": false, "error": "..."}`.
`/api/pair/pin` and `/api/control` may also return `200` with `{"ok": false, ...}`
when the request was valid but the device refused it. Clients should read the
body for any status.

### Sample (1 Hz time series)
```json
{
  "seq": 18230, "t": 1760976999.0,
  "tx_bps": 18000000,          // bits/s sent to the Apple TV during this second
  "requests": 2,               // HLS requests completed in this second
  "ff_speed": 410.0,           // ffmpeg speed (x realtime), null when not running
  "ff_prepared_s": 3011.4,     // seconds of media prepared so far
  "tv_position": 812.3,        // null until the TV reports
  "tv_buffered_ahead_s": 54.0, // loaded range end minus position
  "tv_rate": 1.0,
  "tv_buffer_empty": false,
  "headroom_s": 2199.1,        // ff_prepared_s - tv_position
  "rtt_ms": 4.1,               // latency probe (TCP connect) result measured in this
                               // second; null when not probed this second or timed out
  "rtt_timeout": false         // true only when a probe ran this second and timed out
}
```

### Request (one per HTTP request from the Apple TV)
```json
{
  "seq": 18229, "t": 1760976998.4,      // t = when the request started
  "path": "/seg_0_00135.m4s",
  "kind": "segment",                     // master | playlist | init | segment (video) | audio | subtitle | other
  "segment": 135,                        // null unless segment/subtitle
  "status": 200,
  "bytes": 7840211,
  "duration_ms": 290.0,                  // time to send the full response
  "mbps": 216.3,                         // bytes*8/duration, megabits/s
  "realtime_ratio": 20.7,                // media seconds delivered per wall second (segments only)
  "client": "192.168.1.20",
  "error": null                          // e.g. "client aborted", "not ready (404)"
}
```

### Event
```json
{"seq": 18231, "t": 1760976999.2, "level": "info|warn|error",
 "source": "app|ffmpeg|http|airplay|network", "message": "Apple TV buffer empty - playback stalled"}
```
