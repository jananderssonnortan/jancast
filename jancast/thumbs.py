"""Scrubber preview thumbnails: one small JPEG every INTERVAL_S seconds of video.

Once they are done, a "palette" is made from them too: one colour per
thumbnail, side by side in a PNG one pixel high (PALETTE_FILE), which the app
draws as the timeline - the film as bands of colour, like a movie barcode.

Made in the background with a keyframe-only decode, which is fast (a 45 min
1080p episode takes a few seconds) because only one frame in a few dozen is
decoded. Cached per file (path, size, mtime) under the cache dir, so opening a
file again is instant. File NNNNN.jpg (1-based) shows the video at
(NNNNN - 1) * INTERVAL_S seconds.

HDR is tone-mapped to SDR with VideoToolbox; if that fails the frames are
taken as they are (flat, washed-out colours, but still recognisable).
"""

import colorsys
import hashlib
import json
import math
import re
import shutil
import subprocess
import threading
from pathlib import Path

from .config import cache_dir

INTERVAL_S = 10
WIDTH = 480
QUALITY = 5             # mjpeg -q:v, 2 (best) .. 31
MAX_CACHED = 40         # thumbnail folders kept, least recently used are removed
DONE_FILE = "done.json"
PALETTE_FILE = "palette.png"
PALETTE_SAMPLE = (24, 14)   # each thumbnail is shrunk to this before picking its colour
PALETTE_SMOOTH = 1          # neighbours on each side blended in: scenes become bands
KEY_RE = re.compile(r"^[0-9a-f]{16}$")


def thumb_height(media):
    w, h = media.video.get("width") or 16, media.video.get("height") or 9
    return max(2, round(WIDTH * h / w / 2) * 2)


def build_cmd(media, outdir, tonemap):
    cmd = ["nice", "-n", "10", "ffmpeg", "-hide_banner", "-loglevel", "error", "-nostats", "-y",
           "-skip_frame", "nokey"]
    if tonemap:
        cmd += ["-hwaccel", "videotoolbox", "-hwaccel_output_format", "videotoolbox_vld"]
    cmd += ["-i", str(media.path), "-map", f"0:{media.video['index']}", "-an", "-sn", "-dn"]
    if tonemap:
        vf = (f"fps=1/{INTERVAL_S}:eof_action=pass,scale_vt=w={WIDTH}:h={thumb_height(media)}:color_matrix=bt709:"
              "color_primaries=bt709:color_transfer=bt709,hwdownload,format=p010le,format=yuvj420p")
    else:
        vf = f"fps=1/{INTERVAL_S}:eof_action=pass,scale={WIDTH}:{thumb_height(media)},format=yuvj420p"
    return cmd + ["-vf", vf, "-q:v", str(QUALITY), str(outdir / "%05d.jpg")]


def palette_colours(pixels, width, height):
    """One colour per frame from raw RGB frames (width x height each): the
    colourful pixels count more, so a scene keeps its hue instead of averaging
    to grey; neighbours are blended so scenes read as bands; then a little
    richer and brighter."""
    size = width * height * 3
    raw = []
    for i in range(len(pixels) // size):
        frame = pixels[i * size:(i + 1) * size]
        sr = sg = sb = sw = 0.0
        for j in range(0, size, 3):
            r, g, b = frame[j] / 255, frame[j + 1] / 255, frame[j + 2] / 255
            _, s, v = colorsys.rgb_to_hsv(r, g, b)
            w = 0.15 + s * v
            sr += r * w
            sg += g * w
            sb += b * w
            sw += w
        raw.append((sr / sw, sg / sw, sb / sw))
    out = []
    for i in range(len(raw)):
        win = raw[max(0, i - PALETTE_SMOOTH):i + PALETTE_SMOOTH + 1]
        r, g, b = (sum(c[k] for c in win) / len(win) for k in range(3))
        h, s, v = colorsys.rgb_to_hsv(r, g, b)
        out.append(colorsys.hsv_to_rgb(h, min(1.0, s * 1.6), min(1.0, v ** 0.8)))
    return out


def make_palette(outdir):
    """Write PALETTE_FILE for a finished thumbnail folder. Best effort: the app
    falls back to the thumbnails without it."""
    w, h = PALETTE_SAMPLE
    try:
        frames = subprocess.run(
            ["nice", "-n", "10", "ffmpeg", "-hide_banner", "-loglevel", "error", "-framerate", "1",
             "-i", str(outdir / "%05d.jpg"), "-vf", f"scale={w}:{h}:flags=area",
             "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
            capture_output=True, check=True, timeout=120).stdout
        colours = palette_colours(frames, w, h)
        if not colours:
            return False
        data = bytes(int(round(c * 255)) for rgb in colours for c in rgb)
        tmp = outdir / (PALETTE_FILE + ".tmp.png")
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "rawvideo",
                        "-pix_fmt", "rgb24", "-s", f"{len(colours)}x1", "-i", "-", str(tmp)],
                       input=data, capture_output=True, check=True, timeout=60)
        tmp.replace(outdir / PALETTE_FILE)
        return True
    except (OSError, subprocess.SubprocessError):
        return False


class Job:
    """One ffmpeg run for one file; retries without tone mapping if that fails."""

    def __init__(self, media, outdir):
        self.media = media
        self.outdir = outdir
        self.proc = None
        self.failed = False
        self._stopped = False
        self._lock = threading.Lock()
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def _run(self):
        attempts = [True, False] if self.media.hdr else [False]
        for tonemap in attempts:
            with self._lock:
                if self._stopped:
                    return              # never recreate the folder after stop()
                shutil.rmtree(self.outdir, ignore_errors=True)
                self.outdir.mkdir(parents=True, exist_ok=True)
                try:
                    self.proc = subprocess.Popen(build_cmd(self.media, self.outdir, tonemap),
                                                 stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                                 stderr=subprocess.PIPE, text=True)
                except FileNotFoundError:
                    self.failed = True
                    return
            _, err = self.proc.communicate()
            if self._stopped:
                return
            count = len(list(self.outdir.glob("*.jpg")))
            if self.proc.returncode == 0 and count:
                (self.outdir / DONE_FILE).write_text(json.dumps({"count": count, "tonemapped": tonemap}))
                make_palette(self.outdir)
                return
        self.failed = True

    @property
    def running(self):
        return self.thread.is_alive()

    def stop(self):
        with self._lock:
            self._stopped = True
            if self.proc and self.proc.poll() is None:
                self.proc.terminate()


class ThumbnailStore:
    def __init__(self, root=None):
        self._root = Path(root) if root else None
        self.jobs = {}
        self._lock = threading.Lock()
        self._palettes = set()          # folders whose palette was (being) made here

    @property
    def root(self):
        return self._root or cache_dir() / "thumbs"

    @staticmethod
    def key(media):
        return hashlib.sha1(media.fingerprint.encode()).hexdigest()[:16]

    def ensure(self, media, keep=()):
        """Start making thumbnails for `media` unless they exist or are being made.
        Other running jobs are stopped, except for the files in `keep`."""
        key = self.key(media)
        outdir = self.root / key
        with self._lock:
            if (outdir / DONE_FILE).exists():
                outdir.touch()               # most recently used, for pruning
                return key
            job = self.jobs.get(key)
            if job and (job.running or job.failed):
                return key
            keep_keys = {self.key(m) for m in keep if m is not None}
            for k, j in list(self.jobs.items()):
                if k not in keep_keys and j.running:
                    j.stop()
                    del self.jobs[k]
            self._prune(exclude={key} | keep_keys)
            self.jobs[key] = Job(media, outdir)
        return key

    def info(self, media, keep=()):
        return self._info(media, self.ensure(media, keep))

    def existing(self, media):
        """Like info() but never starts making thumbnails (e.g. for list posters)."""
        try:
            return self._info(media, self.key(media))
        except OSError:
            return None

    def _info(self, media, key):
        outdir = self.root / key
        total = max(1, math.ceil(media.duration / INTERVAL_S)) if media.duration else None
        done_file = outdir / DONE_FILE
        job = self.jobs.get(key)
        if done_file.exists():
            count, done = json.loads(done_file.read_text()).get("count", 0), True
            self._ensure_palette(key, outdir)
        else:
            # The newest file may still be being written.
            count, done = max(0, len(list(outdir.glob("*.jpg"))) - 1), False
        return {
            "url": f"/api/thumbs/{key}/", "interval_s": INTERVAL_S,
            "width": WIDTH, "height": thumb_height(media),
            "count": count, "total": total if not done else count,
            "done": done, "failed": bool(job and job.failed and not done),
            "palette": f"/api/thumbs/{key}/{PALETTE_FILE}" if (outdir / PALETTE_FILE).exists() else None,
        }

    def _ensure_palette(self, key, outdir):
        """Thumbnails made before palettes existed get one, once, in the background."""
        with self._lock:
            if key in self._palettes or (outdir / PALETTE_FILE).exists():
                return
            self._palettes.add(key)
        threading.Thread(target=make_palette, args=(outdir,), daemon=True).start()

    def file(self, key, name):
        """Path of a finished thumbnail (`00001.jpg`) or the palette, or None."""
        if name == PALETTE_FILE and KEY_RE.match(key):
            path = self.root / key / PALETTE_FILE
            return path if path.is_file() else None
        m = re.fullmatch(r"(\d{1,6})\.jpg", name)
        if not KEY_RE.match(key) or not m or int(m.group(1)) < 1:
            return None
        outdir = self.root / key
        path = outdir / f"{int(m.group(1)):05d}.jpg"
        if not path.is_file():
            return None
        if not (outdir / DONE_FILE).exists():
            # Still being made: only serve files that a later one has followed.
            if not (outdir / f"{int(m.group(1)) + 1:05d}.jpg").exists():
                return None
        return path

    def stop_all(self):
        with self._lock:
            for j in self.jobs.values():
                j.stop()

    def _prune(self, exclude):
        try:
            dirs = [d for d in self.root.iterdir() if d.is_dir() and d.name not in exclude]
        except FileNotFoundError:
            return
        dirs.sort(key=lambda d: d.stat().st_mtime, reverse=True)
        for d in dirs[MAX_CACHED - 1:]:
            if not (self.jobs.get(d.name) and self.jobs[d.name].running):
                shutil.rmtree(d, ignore_errors=True)
