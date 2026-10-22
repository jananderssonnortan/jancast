"""Fast start: a complete HLS playlist at once, segments made when requested.

The classic pipeline (media.py) remuxes the whole file before the TV gets a
playlist - about 7 s for a 3 GB episode - because tvOS treats a growing
playlist as a live stream. Here, as in Airflow:

1. The keyframe times come from the file's own index (keyframes.py), so every
   segment can be planned before anything is remuxed: a segment starts at the
   first keyframe at least SEGMENT_TARGET_S after the previous one.
2. Complete VOD playlists (with #EXT-X-ENDLIST) are written immediately.
3. One ffmpeg run copies video and audio as fragmented MP4 into two pipes,
   starting at the requested position. Each fragment is assigned to its
   planned segment by its presentation time and written as seg_*_NNNNN.m4s.
4. A request for a segment the current run will not reach soon (a jump)
   restarts ffmpeg there. Runs stay AHEAD_SEGMENTS past the furthest request
   by simply not reading the pipes, which pauses ffmpeg.

ffmpeg's MP4 muxer starts every run's timestamps at zero (per track), so the
real decode time of each run's first packet is read from ffmpeg's -debug_ts
output and added to every fragment's tfdt (plus TIMELINE_OFFSET_S, which keeps
video decode times - slightly negative at the start because of B-frames - above
zero). All runs then share one timeline and one init segment per track.

Text subtitles are extracted once in the background and cut into WebVTT
segments along the same plan. Only for copied video; everything else
(re-encodes, burned-in subtitles, files without an index) keeps the classic
pipeline. JANCAST_FAST_START=0 turns this off.
"""

import bisect
import collections
import math
import os
import re
import shutil
import subprocess
import threading
import time
from pathlib import Path

from .keyframes import mkv_keyframes
from .media import (AUDIO_INIT, AUDIO_PLAYLIST, SUBTITLE_PLAYLIST, VIDEO_INIT, VIDEO_PLAYLIST,
                    audio_plan, bcp47, write_master)

SEGMENT_TARGET_S = 6.0
AHEAD_SEGMENTS = 30         # produce at most this many segments past the furthest request
RESTART_GAP = 4             # a request this far past what the run is making = a jump
TIMELINE_OFFSET_S = 10.0    # added to every timestamp (tfdt must not be negative)
WAIT_TIMEOUT_S = 25.0       # a request waits at most this long for its segment
SUBTITLE_FILE = "stream_video{}.vtt"     # name pattern hls_server.classify knows
VIDEO_SEG = "seg_video_{:05d}.m4s"
AUDIO_SEG = "seg_audio_{:05d}.m4s"
SEG_RE = re.compile(r"^/?seg_(video|audio)_(\d+)\.m4s$")
SUB_RE = re.compile(r"^/?stream_video(\d+)\.vtt$")
DEBUG_TS_RE = re.compile(r"\[(v|a)ost#\d+:\d+/\S+ @ \S+\] muxer <- pts:(-?\d+) pts_time:\S+ "
                         r"dts:(-?\d+) dts_time:(-?[\d.e+-]+)")


def enabled():
    return os.environ.get("JANCAST_FAST_START", "1") != "0"


def keyframes_for(media, sub):
    """The keyframe index if this playback can use fast start, else None."""
    if not enabled():
        return None
    vmode, _ = media.video_plan(sub)
    if vmode != "copy" or (sub is not None and sub.burns_in):
        return None
    return mkv_keyframes(media.path)


def plan_segments(keyframes, duration, target=SEGMENT_TARGET_S):
    """Segment start times: the first keyframe, then the first keyframe at
    least `target` after the previous start. The last segment ends at
    `duration`; a sliver under a second is merged into the one before."""
    starts = [0.0]
    for k in keyframes:
        if k - starts[-1] >= target - 0.25:
            starts.append(k)
    if duration - starts[-1] < 1.0 and len(starts) > 1:
        starts.pop()
    return starts


# ---- fragmented MP4 -------------------------------------------------------

def read_box(f):
    """(type, whole box bytes) from a stream, or (None, b"") at EOF."""
    head = _read_exact(f, 8)
    if len(head) < 8:
        return None, b""
    size = int.from_bytes(head[:4], "big")
    kind = head[4:8].decode("latin-1")
    if size == 1:
        ext = _read_exact(f, 8)
        size = int.from_bytes(ext, "big")
        head += ext
    body = _read_exact(f, size - len(head)) if size else f.read()
    return kind, head + body


def _read_exact(f, n):
    out = b""
    while len(out) < n:
        chunk = f.read(n - len(out))
        if not chunk:
            break
        out += chunk
    return out


def _child_boxes(data, start, end):
    pos = start
    while pos + 8 <= end:
        size = int.from_bytes(data[pos:pos + 4], "big")
        kind = bytes(data[pos + 4:pos + 8]).decode("latin-1")
        header = 8
        if size == 1:
            size = int.from_bytes(data[pos + 8:pos + 16], "big")
            header = 16
        if size < header or pos + size > end:
            break
        yield kind, pos, size, header
        pos += size


def init_timescale(init):
    """Media timescale (mdhd) of the single track in an init segment."""
    def walk(start, end, path):
        for kind, pos, size, header in _child_boxes(init, start, end):
            if kind == path[0]:
                if len(path) == 1:
                    body = pos + header
                    version = init[body]
                    at = body + (20 if version == 1 else 12)
                    return int.from_bytes(init[at:at + 4], "big")
                found = walk(pos + header, pos + size, path[1:])
                if found:
                    return found
        return None
    return walk(0, len(init), ["moov", "trak", "mdia", "mdhd"])


class Fragment:
    """A moof+mdat pair whose decode time (tfdt) and sequence number can be
    rewritten in place."""

    def __init__(self, moof, mdat):
        self.data = bytearray(moof + mdat)
        self.moof_size = len(moof)
        self.tfdt_at = None
        self.tfdt_version = 0
        self.mfhd_at = None
        self.first_cto = 0
        for kind, pos, size, header in _child_boxes(self.data, 8, self.moof_size):
            if kind == "mfhd":
                self.mfhd_at = pos + header + 4
            elif kind == "traf":
                self._traf(pos + header, pos + size)

    def _traf(self, start, end):
        for kind, pos, size, header in _child_boxes(self.data, start, end):
            body = pos + header
            if kind == "tfdt":
                self.tfdt_version = self.data[body]
                self.tfdt_at = body + 4
            elif kind == "trun":
                flags = int.from_bytes(self.data[body + 1:body + 4], "big")
                version = self.data[body]
                at = body + 8 + (4 if flags & 0x1 else 0) + (4 if flags & 0x4 else 0)
                at += (4 if flags & 0x100 else 0) + (4 if flags & 0x200 else 0) + (4 if flags & 0x400 else 0)
                if flags & 0x800:
                    raw = int.from_bytes(self.data[at:at + 4], "big")
                    self.first_cto = raw - (1 << 32) if version == 1 and raw >= 1 << 31 else raw

    @property
    def tfdt(self):
        n = 8 if self.tfdt_version == 1 else 4
        return int.from_bytes(self.data[self.tfdt_at:self.tfdt_at + n], "big")

    def rewrite(self, tfdt, sequence):
        n = 8 if self.tfdt_version == 1 else 4
        if tfdt < 0 or tfdt >= 1 << (8 * n):
            raise ValueError(f"tfdt {tfdt} does not fit")
        self.data[self.tfdt_at:self.tfdt_at + n] = tfdt.to_bytes(n, "big")
        if self.mfhd_at is not None:
            self.data[self.mfhd_at:self.mfhd_at + 4] = (sequence & 0xFFFFFFFF).to_bytes(4, "big")


# ---- one ffmpeg run -------------------------------------------------------

class Run:
    """ffmpeg copying video (and audio) from `seek_s` into two fMP4 pipes."""

    def __init__(self, owner, start_index):
        self.owner = owner
        self.start_index = start_index
        self.cancelled = False
        self.first_dts = {}                 # "v"/"a" -> first packet's decode time (track ticks)
        self.first_dts_s = {}
        self.ready = {"v": threading.Event(), "a": threading.Event()}
        self.first_pts = {}                 # track -> presentation time of the run's first fragment
        self.next_index = {"v": start_index, "a": start_index}
        self.eof = {"v": False, "a": False}
        self.started_at = time.monotonic()
        self.produced_s = 0.0
        self.throttled = False              # waiting for the player to catch up
        self.stderr_tail = []
        media = owner.media
        start_s = owner.starts[start_index]
        # Seek a little before the segment so both tracks cover its start.
        self.seek_s = max(0.0, start_s - 1.0)
        audio_r, audio_w = os.pipe()
        cmd = ["ffmpeg", "-hide_banner", "-nostats", "-debug_ts", "-y"]
        if self.seek_s > 0:
            cmd += ["-ss", f"{self.seek_s:.3f}"]
        cmd += ["-copyts", "-i", str(media.path)]
        vidx = media.video["index"]
        cmd += ["-map", f"0:{vidx}", "-c:v", "copy"]
        if media.video_codec == "hevc":
            cmd += ["-tag:v", "hvc1", "-strict", "unofficial"]
        # -map_chapters -1: MKV chapters would become a second (text) track in
        # the init segment, which tvOS refuses (it never requests a segment).
        cmd += ["-map_chapters", "-1", "-use_editlist", "0",
                "-movflags", "+empty_moov+default_base_moof+frag_keyframe", "-f", "mp4", "pipe:1"]
        cmd += ["-map", f"0:{owner.audio.index}"] + audio_plan(owner.audio, owner.stereo)[2]
        cmd += ["-map_chapters", "-1", "-use_editlist", "0",
                "-movflags", "+empty_moov+default_base_moof+frag_every_frame+delay_moov",
                "-f", "mp4", f"pipe:{audio_w}"]
        self.cmd = cmd
        self.proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, pass_fds=(audio_w,))
        os.close(audio_w)
        self.audio_out = os.fdopen(audio_r, "rb")
        self.threads = [threading.Thread(target=self._stderr, daemon=True),
                        threading.Thread(target=self._track, args=("v", self.proc.stdout), daemon=True),
                        threading.Thread(target=self._track, args=("a", self.audio_out), daemon=True)]
        for t in self.threads:
            t.start()

    def _stderr(self):
        for raw in self.proc.stderr:
            line = raw.decode("utf-8", "replace").rstrip()
            m = DEBUG_TS_RE.search(line)
            if m:
                track = m.group(1)
                if track not in self.first_dts:
                    self.first_dts[track] = int(m.group(3))
                    self.first_dts_s[track] = float(m.group(4))
                    self.ready[track].set()
                continue
            if line and "muxer <-" not in line and "demuxer" not in line and "decoder" not in line:
                self.stderr_tail = (self.stderr_tail + [line])[-20:]
                # A run stopped for a jump (or at the end) dies on its closed
                # pipes: "Broken pipe", "Error muxing a packet"... - expected,
                # and must not look like damaged source data in Diagnostics.
                if self.cancelled or "Broken pipe" in line or "Task finished with error code: -32" in line:
                    continue
                if any(w in line.lower() for w in ("error", "invalid", "failed")):
                    self.owner.warn(line)
        for event in self.ready.values():
            event.set()                     # EOF: nobody waits forever
        self.proc.stderr.close()

    def _track(self, track, stream):
        owner = self.owner
        init = b""
        timescale = None
        seg_index = None
        buf = []
        moof = None
        try:
            while not self.cancelled:
                kind, box = read_box(stream)
                if kind is None:
                    break
                if kind in ("ftyp", "moov"):
                    init += box
                    if kind == "moov":
                        timescale = init_timescale(init)
                        owner.save_init(track, init)
                    continue
                if kind == "moof":
                    moof = box
                    continue
                if kind != "mdat" or moof is None:
                    continue
                frag = Fragment(moof, box)
                moof = None
                if not self.ready[track].wait(10) or track not in self.first_dts or not timescale:
                    raise RuntimeError(f"no timestamps from ffmpeg for the {track} track")
                dts = frag.tfdt + self.first_dts[track]
                pts_s = (dts + frag.first_cto) / timescale
                index = owner.segment_of(pts_s)
                if track not in self.first_pts:
                    self.first_pts[track] = pts_s
                frag.rewrite(dts + round(TIMELINE_OFFSET_S * timescale), sequence=int(pts_s * 1000) + 1)
                if seg_index is None:
                    seg_index = index
                if index != seg_index:
                    self._finish(track, seg_index, buf)
                    buf = []
                    seg_index = index
                    # Throttle: stop reading (ffmpeg then blocks) once far enough ahead.
                    if not owner.wait_for_demand(self, track, index):
                        return
                buf.append(bytes(frag.data))
                if track == "v":
                    self.produced_s = max(self.produced_s, pts_s - self.seek_s)
            if seg_index is not None and not self.cancelled:
                self._finish(track, seg_index, buf, last=True)
        except (OSError, ValueError, RuntimeError) as e:
            if not self.cancelled:
                owner.warn(f"fast start {track}: {e}")
        finally:
            self.eof[track] = True
            try:
                stream.close()
            except OSError:
                pass
            owner.run_progress(self)

    def _finish(self, track, index, buf, last=False):
        """Write a segment if this run covered it from its start."""
        tolerance = 0.005 if track == "v" else 0.1
        start_s = self.owner.starts[index]
        covered = self.seek_s <= 0 or self.first_pts.get(track, math.inf) <= start_s + tolerance
        if covered and buf:
            self.owner.save_segment(track, index, b"".join(buf))
        self.next_index[track] = index + 1
        self.owner.run_progress(self)

    def stop(self):
        self.cancelled = True
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(3)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        for f in (self.proc.stdout, self.audio_out):
            try:
                f.close()
            except OSError:
                pass

    @property
    def done(self):
        return all(self.eof.values())


# ---- the whole stream ------------------------------------------------------

class OnDemand:
    """Plans the stream, writes the playlists and makes segments on request.

    Quacks like media.Transcoder for Session and its sampling (progress,
    prepared_s, speed, done, failed, stderr_tail, stop(), wait())."""

    def __init__(self, media, audio, sub, outdir, keyframes, stereo=False, on_warning=None,
                 subtitle_delay=0.0):
        self.media = media
        self.audio = audio
        self.sub = sub
        self.stereo = stereo
        self.subtitle_delay = float(subtitle_delay or 0)    # seconds, + = later
        self.outdir = Path(outdir)
        self.duration = media.duration
        self.starts = plan_segments(keyframes, media.duration)
        self.count = len(self.starts)
        self.on_warning = on_warning or (lambda line: None)
        self.cond = threading.Condition()
        self.run = None
        self.requested = 0                  # furthest segment index the player asked for
        self.reading = 0                    # the video segment the player asked for last
        self.made = set()                   # video segment indexes written (by any run)
        # For Diagnostics: how often the player had to wait for a segment, and how long.
        self.segment_requests = 0
        self.waited = 0
        self._wait_ms = collections.deque(maxlen=200)
        self.restarts = 0                   # ffmpeg restarted for a jump
        self.inits = {}
        self.subs_ready = threading.Event()
        self._stopped = False
        self.failed_reason = None
        self._speed = None
        self.on_demand = True               # Session.prep_json: preparation is not a progress bar

    # Transcoder-like surface ---------------------------------------------

    @property
    def prepared_s(self):
        """End of the segments made without a gap from the one the player
        read last: what it can play from there without waiting for ffmpeg.
        Not the current run's end - after a jump back the player plays on
        into segments an earlier run made, past where the new run is."""
        i = self.reading
        while i < self.count and i in self.made:
            i += 1
        return self.duration if i >= self.count else self.starts[i]

    @property
    def progress(self):
        return min(1.0, self.prepared_s / self.duration) if self.duration else 0.0

    @property
    def done(self):
        run = self.run
        return self._stopped or (run is not None and run.done and run.next_index["v"] >= self.count)

    @property
    def speed(self):
        """Remux speed (x realtime) while catching up; None while paused on
        purpose far enough ahead - a falling average would look like a slow encoder."""
        run = self.run
        return None if run is None or run.throttled else self._speed

    @property
    def failed(self):
        return self.failed_reason is not None

    @property
    def stderr_tail(self):
        tail = self.run.stderr_tail if self.run else []
        return tail + ([self.failed_reason] if self.failed_reason else [])

    @property
    def bitrate(self):
        """Stream bitrate: the file's average (the video is copied)."""
        return int(self.media.size_bytes * 8 / self.duration) if self.duration else None

    @property
    def segments_ready(self):
        return len(self.made)

    def wait(self):
        pass

    def stop(self):
        with self.cond:
            self._stopped = True
            run, self.run = self.run, None
            self.cond.notify_all()
        if run:
            run.stop()

    def warn(self, line):
        try:
            self.on_warning(line)
        except Exception:  # noqa: BLE001
            pass

    # Planning and playlists ---------------------------------------------

    def segment_of(self, t):
        return max(0, min(self.count - 1, bisect.bisect_right(self.starts, t + 0.002) - 1))

    def segment_duration(self, i):
        end = self.starts[i + 1] if i + 1 < self.count else self.duration
        return max(0.001, end - self.starts[i])

    def _media_playlist(self, init, pattern):
        target = math.ceil(max(self.segment_duration(i) for i in range(self.count)))
        lines = ["#EXTM3U", "#EXT-X-VERSION:7", f"#EXT-X-TARGETDURATION:{target}",
                 "#EXT-X-MEDIA-SEQUENCE:0", "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-INDEPENDENT-SEGMENTS",
                 f'#EXT-X-MAP:URI="{init}"']
        for i in range(self.count):
            lines += [f"#EXTINF:{self.segment_duration(i):.6f},", pattern.format(i)]
        return "\n".join(lines + ["#EXT-X-ENDLIST"]) + "\n"

    def _subtitle_playlist(self):
        target = math.ceil(max(self.segment_duration(i) for i in range(self.count)))
        lines = ["#EXTM3U", "#EXT-X-VERSION:7", f"#EXT-X-TARGETDURATION:{target}",
                 "#EXT-X-MEDIA-SEQUENCE:0", "#EXT-X-PLAYLIST-TYPE:VOD"]
        for i in range(self.count):
            lines += [f"#EXTINF:{self.segment_duration(i):.6f},", SUBTITLE_FILE.format(i)]
        return "\n".join(lines + ["#EXT-X-ENDLIST"]) + "\n"

    def _write(self, name, text):
        tmp = self.outdir / (name + ".tmp")
        tmp.write_text(text)
        tmp.replace(self.outdir / name)

    def start(self, position=0.0):
        """Write the media playlists and start producing at `position`."""
        self.outdir.mkdir(parents=True, exist_ok=True)
        self._write(VIDEO_PLAYLIST, self._media_playlist(VIDEO_INIT, VIDEO_SEG))
        self._write(AUDIO_PLAYLIST, self._media_playlist(AUDIO_INIT, AUDIO_SEG))
        if self.sub is not None:
            self._write(SUBTITLE_PLAYLIST, self._subtitle_playlist())
            threading.Thread(target=self._make_subtitles, daemon=True).start()
        with self.cond:
            self.requested = self.reading = self.segment_of(position)
            self._restart(self.requested)

    def wait_ready(self, position=0.0, timeout=30.0):
        """Block until both init segments and the first segments exist, then
        write the master playlist (its CODECS come from the init segments)."""
        i = self.segment_of(position)
        deadline = time.monotonic() + timeout
        names = [VIDEO_INIT, AUDIO_INIT, VIDEO_SEG.format(i), AUDIO_SEG.format(i)]
        with self.cond:
            while not all((self.outdir / n).exists() for n in names):
                if self.failed_reason or self._stopped:
                    raise RuntimeError(self.failed_reason or "stopped")
                if self.run and self.run.done and not all((self.outdir / n).exists() for n in names):
                    raise RuntimeError("ffmpeg ended before the first segment: "
                                       + " | ".join(self.run.stderr_tail[-3:]))
                left = deadline - time.monotonic()
                if left <= 0:
                    raise RuntimeError("timed out waiting for the first segment")
                self.cond.wait(min(left, 0.5))
        self._write_master()

    def _write_master(self):
        mode, codec, _ = audio_plan(self.audio, self.stereo)
        if mode == "copy":
            channels = self.audio.channels
        else:
            channels = 2 if codec == "aac" else min(self.audio.channels or 6, 6)
        avg = int(self.media.size_bytes * 8 / self.duration) if self.duration else 10_000_000
        lines = ["#EXTM3U", "#EXT-X-VERSION:7",
                 # LANGUAGE matters: tvOS only auto-selects the FORCED subtitle
                 # rendition when it knows the audio's language (see build_ffmpeg_cmd).
                 f'#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="group_aud",NAME="audio_0",DEFAULT=YES,'
                 f'LANGUAGE="{bcp47(self.audio.lang)}",CHANNELS="{channels or 2}",URI="{AUDIO_PLAYLIST}"']
        inf = f"#EXT-X-STREAM-INF:BANDWIDTH={int(avg * 1.5)},AVERAGE-BANDWIDTH={avg}"
        if self.media.video.get("width") and self.media.video.get("height"):
            inf += f",RESOLUTION={self.media.video['width']}x{self.media.video['height']}"
        inf += ',AUDIO="group_aud"'
        if self.sub is not None:
            lines.append(f'#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="subtitle_1",DEFAULT=NO,'
                         f'URI="{SUBTITLE_PLAYLIST}"')
            inf += ',SUBTITLES="subs"'
        (self.outdir / "ffmaster.m3u8").write_text("\n".join(lines + [inf, VIDEO_PLAYLIST]) + "\n")
        write_master(self.outdir, self.audio, self.sub, path=self.media.path)

    # Segments ------------------------------------------------------------

    def save_init(self, track, data):
        name = VIDEO_INIT if track == "v" else AUDIO_INIT
        with self.cond:
            if track not in self.inits:
                self.inits[track] = data
                self._write_bytes(name, data)
                self.cond.notify_all()

    def save_segment(self, track, index, data):
        name = (VIDEO_SEG if track == "v" else AUDIO_SEG).format(index)
        with self.cond:
            if not (self.outdir / name).exists():
                self._write_bytes(name, data)
            if track == "v":
                self.made.add(index)
            self.cond.notify_all()

    def _write_bytes(self, name, data):
        tmp = self.outdir / (name + ".tmp")
        tmp.write_bytes(data)
        tmp.replace(self.outdir / name)

    def run_progress(self, run):
        with self.cond:
            if run is self.run and run.done and run.next_index["v"] < self.count and not run.cancelled:
                # ffmpeg stopped early without being asked to.
                if run.proc.poll() not in (None, 0):
                    self.failed_reason = "ffmpeg failed: " + " | ".join(run.stderr_tail[-3:])
            elapsed = time.monotonic() - run.started_at
            if run is self.run and elapsed > 0.5 and not run.throttled:
                self._speed = round(run.produced_s / elapsed, 1)
            self.cond.notify_all()

    def wait_for_demand(self, run, track, index):
        """Called by a run's reader before a new segment: block while it is
        far enough ahead. False when the run was replaced or stopped."""
        with self.cond:
            while not run.cancelled and run is self.run and index > self.requested + AHEAD_SEGMENTS:
                run.throttled = True
                self.cond.wait(1.0)
            run.throttled = False
            return not run.cancelled and run is self.run

    def _restart(self, index):
        old, self.run = self.run, None
        if old:
            self.restarts += 1
            threading.Thread(target=old.stop, daemon=True).start()
        if not self._stopped:
            self.run = Run(self, index)

    def wait_for(self, path, timeout=WAIT_TIMEOUT_S):
        """Hook for the HLS server: make sure `path` exists before it is
        served (restarting ffmpeg for a jump). Returns quickly for files that
        are not segments."""
        name = path.lstrip("/")
        if (m := SUB_RE.match(name)):
            self.subs_ready.wait(timeout)
            return
        m = SEG_RE.match(name)
        if not m:
            return
        index = int(m.group(2))
        file = self.outdir / name
        if index >= self.count:
            return
        self.segment_requests += 1
        if m.group(1) == "video":
            self.reading = index
        if file.exists():
            self._served_made(index)
            return
        began = time.monotonic()
        try:
            self._wait_until_made(file, index, m.group(1), began + timeout)
        finally:
            self.waited += 1
            self._wait_ms.append((time.monotonic() - began) * 1000)

    def _served_made(self, index):
        """A request for a segment that exists still moves the player along:
        the run must keep AHEAD_SEGMENTS past it, or after a jump back - the
        player then plays on into segments an earlier run made - it stays
        paused behind and the player runs out of made segments later."""
        with self.cond:
            run = self.run
            if run is not None and index >= run.start_index and index > self.requested:
                self.requested = index
                self.cond.notify_all()

    def wait_stats(self):
        """Segment waits for Diagnostics (ms; None before any wait)."""
        waits = sorted(self._wait_ms)
        return {"segment_requests": self.segment_requests, "waited": self.waited,
                "restarts": self.restarts,
                "wait_last_ms": round(self._wait_ms[-1]) if waits else None,
                "wait_median_ms": round(waits[len(waits) // 2]) if waits else None,
                "wait_max_ms": round(waits[-1]) if waits else None}

    def _wait_until_made(self, file, index, kind, deadline):
        with self.cond:
            run = self.run
            jump_back = run is None or index < run.start_index
            self.requested = index if jump_back else max(index, self.requested)
            track = "v" if kind == "video" else "a"
            if run is None or index < run.start_index or index > run.next_index[track] + RESTART_GAP:
                self._restart(index)
            self.cond.notify_all()
            while not file.exists() and not self._stopped:
                left = deadline - time.monotonic()
                if left <= 0:
                    return
                self.cond.wait(min(left, 0.5))

    # Subtitles -----------------------------------------------------------

    def _make_subtitles(self):
        try:
            sub = self.sub
            src = ["-i", str(sub.file)] if sub.file else ["-i", str(self.media.path)]
            stream = "0:0" if sub.file else f"0:{sub.index}"
            out = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", *src, "-map", stream,
                                  "-c:s", "webvtt", "-f", "webvtt", "-"],
                                 stdin=subprocess.DEVNULL, capture_output=True, timeout=600)
            cues = parse_vtt(out.stdout.decode("utf-8", "replace"))
            if self.subtitle_delay:
                d = self.subtitle_delay
                cues = [(s + d, e + d, settings, text) for s, e, settings, text in cues if e + d > 0]
            for i in range(self.count):
                start = self.starts[i]
                end = start + self.segment_duration(i)
                body = [c for c in cues if c[0] < end and c[1] > start]
                (self.outdir / SUBTITLE_FILE.format(i)).write_text(vtt_segment(body))
        except Exception as e:  # noqa: BLE001 - subtitles missing is not fatal
            self.warn(f"fast start subtitles: {e}")
        finally:
            self.subs_ready.set()


# ---- WebVTT ----------------------------------------------------------------

VTT_TIME = re.compile(r"(?:(\d+):)?(\d{2}):(\d{2})\.(\d{3})")


def _vtt_seconds(text):
    m = VTT_TIME.fullmatch(text.strip())
    if not m:
        raise ValueError(f"bad WebVTT time {text!r}")
    h, mi, s, ms = m.groups()
    return int(h or 0) * 3600 + int(mi) * 60 + int(s) + int(ms) / 1000


def _vtt_time(t):
    ms = round(t * 1000)
    return f"{ms // 3600000:02d}:{ms // 60000 % 60:02d}:{ms // 1000 % 60:02d}.{ms % 1000:03d}"


def parse_vtt(text):
    """[(start_s, end_s, settings, text)] from a WebVTT document."""
    cues = []
    for block in re.split(r"\n\s*\n", text.replace("\r\n", "\n")):
        lines = block.strip("\n").split("\n")
        for i, line in enumerate(lines):
            if "-->" in line:
                left, right = line.split("-->", 1)
                parts = right.strip().split(None, 1)
                cues.append((_vtt_seconds(left), _vtt_seconds(parts[0]),
                             parts[1] if len(parts) > 1 else "", "\n".join(lines[i + 1:])))
                break
    return cues


def vtt_segment(cues):
    """A WebVTT segment with cue times on the media timeline (source time +
    TIMELINE_OFFSET_S) and no X-TIMESTAMP-MAP - as ffmpeg's own HLS output
    does. The Mac honors a mapping header; tvOS showed no subtitles with one."""
    out = ["WEBVTT", ""]
    for start, end, settings, text in cues:
        start, end = start + TIMELINE_OFFSET_S, end + TIMELINE_OFFSET_S
        out.append(f"{_vtt_time(start)} --> {_vtt_time(end)}" + (f" {settings}" if settings else ""))
        out.append(text)
        out.append("")
    return "\n".join(out) + "\n"
