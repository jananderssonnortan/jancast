"""Picture subtitles (Blu-ray PGS) turned into text with macOS's own OCR.

The Apple TV only draws text subtitles, so picture subtitles used to be burned
into the video - a full re-encode. Instead, like Airflow's "Text (OCR)":

1. ffmpeg copies the PGS track out of the file (`-f sup`, under a second).
2. The display sets are decoded here: each subtitle's bitmap (run-length
   coded, palette with alpha) and when it appears and disappears.
3. Every bitmap is written as a small black-on-white PNG and recognised in one
   batch by a tiny Swift helper using the Vision framework (offline, all
   cores). It is compiled once with `swiftc` into the cache directory.
4. The text becomes a WebVTT file, cached per file and track, used from then
   on like any text subtitle track.

`available()` is False without swiftc (Xcode command line tools); picture
subtitles then keep the burn-in path.
"""

import hashlib
import json
import os
import shutil
import struct
import subprocess
import tempfile
import threading
import zlib
from pathlib import Path

from .config import cache_dir

HELPER_SOURCE = Path(__file__).with_name("ocr_helper.swift")
PCS, WDS, PDS, ODS, END = 0x16, 0x17, 0x14, 0x15, 0x80
MAX_TEXT_FILES = 200       # cached subtitle texts kept (ocr/ and subs/), newest first
MAX_CUE_S = 10.0            # a subtitle with no clear-screen after it ends after this
_locks = {}
_locks_lock = threading.Lock()


class OCRError(Exception):
    pass


# ---- PGS ------------------------------------------------------------------

def read_segments(data):
    """[(pts_seconds, type, payload)] from a .sup stream."""
    out = []
    pos = 0
    while pos + 13 <= len(data):
        if data[pos:pos + 2] != b"PG":
            raise OCRError(f"not a PGS stream at byte {pos}")
        pts = struct.unpack(">I", data[pos + 2:pos + 6])[0] / 90000
        kind = data[pos + 10]
        size = struct.unpack(">H", data[pos + 11:pos + 13])[0]
        out.append((pts, kind, data[pos + 13:pos + 13 + size]))
        pos += 13 + size
    return out


def decode_rle(data, width, height):
    """PGS run-length coded bitmap -> list of rows (bytes of palette indexes)."""
    rows = []
    row = bytearray()
    i = 0
    n = len(data)
    while i < n and len(rows) < height:
        b = data[i]
        i += 1
        if b:
            row.append(b)
            continue
        if i >= n:
            break
        b2 = data[i]
        i += 1
        if b2 == 0:                         # end of line
            rows.append(bytes((row + bytes(width))[:width]))
            row = bytearray()
            continue
        kind = b2 & 0xC0
        if kind == 0x00:
            count, color = b2 & 0x3F, 0
        elif kind == 0x40:
            count, color = ((b2 & 0x3F) << 8) | data[i], 0
            i += 1
        elif kind == 0x80:
            count, color = b2 & 0x3F, data[i]
            i += 1
        else:
            count, color = ((b2 & 0x3F) << 8) | data[i], data[i + 1]
            i += 2
        row += bytes([color]) * count
    while len(rows) < height:
        rows.append(bytes(width))
    return rows


def display_sets(segments):
    """[(start_s, end_s or None, [bitmap rows as gray bytes per object, top to bottom])].

    Text is rendered black on white for OCR: light opaque pixels (the letters)
    become black; outline and transparent pixels white."""
    palettes = {}
    objects = {}                # object id -> (width, height, bytearray of rle)
    shown = []                  # current composition: [(y, object_id)]
    events = []
    composition = None
    for pts, kind, payload in segments:
        if kind == PCS:
            count = payload[10]
            refs = []
            at = 11
            for _ in range(count):
                obj_id = struct.unpack(">H", payload[at:at + 2])[0]
                cropped = payload[at + 3] & 0x80
                y = struct.unpack(">H", payload[at + 6:at + 8])[0]
                refs.append((y, obj_id))
                at += 8 + (8 if cropped else 0)
            composition = {"pts": pts, "palette": payload[9], "refs": refs,
                           "state": payload[7]}
        elif kind == PDS:
            pal = palettes.setdefault(payload[0], {})
            for k in range(2, len(payload) - 4, 5):
                idx, y, cr, cb, alpha = payload[k:k + 5]
                pal[idx] = (y, alpha)
        elif kind == ODS:
            obj_id = struct.unpack(">H", payload[0:2])[0]
            flags = payload[3]
            if flags & 0x80:                # first in sequence
                width, height = struct.unpack(">HH", payload[7:11])
                objects[obj_id] = (width, height, bytearray(payload[11:]))
            elif obj_id in objects:
                objects[obj_id][2].extend(payload[4:])
        elif kind == END and composition is not None:
            if events and events[-1][1] is None:
                events[-1] = (events[-1][0], composition["pts"], events[-1][2])
            refs = composition["refs"]
            if refs:
                pal = palettes.get(composition["palette"], {})
                images = []
                for y, obj_id in sorted(refs):
                    if obj_id not in objects:
                        continue
                    width, height, rle = objects[obj_id]
                    images.append(_gray(decode_rle(bytes(rle), width, height), pal, width))
                if images:
                    events.append((composition["pts"], None, images))
            composition = None
    return [(s, e if e is not None else s + MAX_CUE_S, imgs) for s, e, imgs in events]


def _gray(rows, palette, width):
    # One lookup table per palette: letters (light, opaque) black, the rest white.
    table = bytes(0 if (palette.get(i, (0, 0))[1] > 96 and palette.get(i, (0, 0))[0] > 128) else 255
                  for i in range(256))
    return [bytes(row[:width]).translate(table) for row in rows]


def png(rows):
    """A grayscale PNG (no dependencies), with a white margin and 2x scale -
    Vision reads small subtitle glyphs better that way."""
    width = len(rows[0]) if rows else 1
    margin = 16
    scaled = []
    blank = b"\xff" * ((width + 2 * margin) * 2)
    for _ in range(margin * 2):
        scaled.append(blank)
    for row in rows:
        wide = bytearray(len(row) * 2)
        wide[0::2] = row
        wide[1::2] = row
        wide = bytes(wide)
        line = b"\xff" * (margin * 2) + wide + b"\xff" * (margin * 2)
        scaled += [line, line]
    for _ in range(margin * 2):
        scaled.append(blank)
    w, h = len(scaled[0]), len(scaled)
    raw = b"".join(b"\x00" + line for line in scaled)

    def chunk(kind, body):
        return (struct.pack(">I", len(body)) + kind + body
                + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 0, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


# ---- OCR helper -------------------------------------------------------------

def helper_path():
    """The compiled Vision helper (built on first use), or None without swiftc."""
    if not HELPER_SOURCE.exists() or not shutil.which("swiftc"):
        return None
    digest = hashlib.sha1(HELPER_SOURCE.read_bytes()).hexdigest()[:12]
    target = cache_dir() / "bin" / f"jancast-ocr-{digest}"
    if target.exists():
        return target
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_suffix(".tmp")
    result = subprocess.run(["swiftc", "-O", "-o", str(tmp), str(HELPER_SOURCE)],
                            capture_output=True, text=True)
    if result.returncode != 0:
        raise OCRError("could not build the OCR helper: " + result.stderr.strip()[-300:])
    tmp.replace(target)
    for old in target.parent.glob("jancast-ocr-*"):     # builds of earlier helper versions
        if old != target:
            old.unlink(missing_ok=True)
    return target


def prepare():
    """Backend startup, in the background: build the helper and trim the cache."""
    prune_text_cache()
    available()


def prune_text_cache(keep=MAX_TEXT_FILES):
    """Drop the least recently used cached subtitle texts beyond `keep` per folder
    (a few hundred KB each at most; `cached` refreshes a file's time on use)."""
    for folder in (cache_dir() / "ocr", cache_dir() / "subs"):
        try:
            files = sorted(folder.glob("*.vtt"), key=lambda f: f.stat().st_mtime, reverse=True)
        except OSError:
            continue
        for f in files[keep:]:
            f.unlink(missing_ok=True)


def available():
    try:
        return helper_path() is not None
    except OCRError:
        return False


def recognize(pngs, languages, fast=False, progress=None):
    """{name: text} for PNG files, via the Vision helper. `progress(done, total)`
    is called as results arrive."""
    helper = helper_path()
    if helper is None:
        raise OCRError("text recognition needs Xcode's command line tools (swiftc)")
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as listing:
        listing.write("\n".join(str(p) for p in pngs))
    try:
        cmd = [str(helper), listing.name] + (["--fast"] if fast else []) + list(languages)
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        out = {}
        for line in proc.stdout:
            try:
                item = json.loads(line)
            except ValueError:
                continue
            out[item["file"]] = item["text"]
            if progress:
                progress(len(out), len(pngs))
        err = proc.stderr.read()
        if proc.wait() != 0:
            raise OCRError("OCR failed: " + err.strip()[-300:])
    finally:
        Path(listing.name).unlink(missing_ok=True)
    return out


# ---- the whole track ----------------------------------------------------------

ISO639_TO_VISION = {"eng": "en-US", "swe": "sv-SE", "ger": "de-DE", "deu": "de-DE",
                    "fre": "fr-FR", "fra": "fr-FR", "spa": "es-ES", "ita": "it-IT",
                    "por": "pt-BR", "dan": "da-DK", "nor": "nb-NO", "nob": "nb-NO",
                    "fin": "fi-FI", "dut": "nl-NL", "nld": "nl-NL"}


def cache_path(media, sub, accurate=True):
    st = media.path.stat()
    key = hashlib.sha1(f"{media.path}|{st.st_size}|{st.st_mtime}|{sub.index}".encode()).hexdigest()[:16]
    return cache_dir() / "ocr" / f"{key}{'' if accurate else '.fast'}.vtt"


def cached(media, sub):
    """The best text made so far for this track, or None."""
    for accurate in (True, False):
        path = cache_path(media, sub, accurate)
        if path.exists():
            touch(path)
            return path
    return None


def touch(path):
    """Mark a cached file as used, for prune_text_cache."""
    try:
        os.utime(path)
    except OSError:
        pass


def text_subtitles(media, sub, progress=None, accurate=False):
    """WebVTT file with the recognised text of a picture subtitle track.

    The quick pass (Vision's fast level, ~10 s for a film) is what playback
    waits for; `accurate=True` makes the better version that replaces it in
    the cache (done in the background, see `ensure`)."""
    best = cached(media, sub)
    if best is not None and (not accurate or not best.name.endswith(".fast.vtt")):
        return best
    path = cache_path(media, sub, accurate)
    with _lock_for(path):
        if path.exists():
            return path
        with tempfile.TemporaryDirectory(prefix="jancast-ocr-") as tmp:
            tmp = Path(tmp)
            sup = tmp / "track.sup"
            r = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                                "-i", str(media.path), "-map", f"0:{sub.index}", "-c", "copy",
                                "-f", "sup", str(sup)], capture_output=True, text=True)
            if r.returncode != 0 or not sup.exists():
                raise OCRError("could not read the subtitle track: " + r.stderr.strip()[-200:])
            if progress:
                progress(0.1)
            events = display_sets(read_segments(sup.read_bytes()))
            files = []
            for i, (_, _, images) in enumerate(events):
                for j, rows in enumerate(images):
                    f = tmp / f"{i:05d}_{j}.png"
                    f.write_bytes(png(rows))
                    files.append(f)
            if progress:
                progress(0.2)
            lang = ISO639_TO_VISION.get((sub.lang or "").lower())
            texts = recognize(files, [lang] if lang else [], fast=not accurate,
                              progress=(lambda done, total: progress(0.2 + 0.8 * done / max(1, total)))
                              if progress else None)
            cues = []
            for i, (start, end, images) in enumerate(events):
                lines = [texts.get(str(tmp / f"{i:05d}_{j}.png"), "").strip() for j in range(len(images))]
                text = "\n".join(t for t in lines if t)
                if text:
                    cues.append((start, end, text))
            path.parent.mkdir(parents=True, exist_ok=True)
            tmp_out = path.with_suffix(".tmp")
            tmp_out.write_text(webvtt(cues))
            tmp_out.replace(path)
            if accurate:
                cache_path(media, sub, accurate=False).unlink(missing_ok=True)   # replaced
            if progress:
                progress(1.0)
    return path


class Job:
    """Background OCR of one track: the quick pass, then the accurate one."""

    def __init__(self, media, sub):
        self.progress = 0.0
        self.error = None
        self.done = threading.Event()
        self.thread = threading.Thread(target=self._run, args=(media, sub), daemon=True)
        self.thread.start()

    def _run(self, media, sub):
        try:
            text_subtitles(media, sub, progress=self._set)
            self.done.set()
            text_subtitles(media, sub, accurate=True)     # replaces it for later plays
        except Exception as e:  # noqa: BLE001 - reported through status()
            self.error = str(e) or type(e).__name__
            self.done.set()

    def _set(self, value):
        self.progress = value


_jobs = {}


def ensure(media, sub):
    """Start (or find) the background OCR of a track. None once the accurate
    text exists. A failed job stays failed (no retry loop on every poll)."""
    if cache_path(media, sub, True).exists():
        return None
    key = str(cache_path(media, sub, True))
    with _locks_lock:
        job = _jobs.get(key)
        if job is None:
            job = _jobs[key] = Job(media, sub)
    return job


def status(media, sub):
    """{"status": ready|working|failed|unavailable, "progress", "error"}."""
    if not shutil.which("swiftc"):
        return {"status": "unavailable", "progress": 0.0,
                "error": "text recognition needs Xcode's command line tools"}
    job = ensure(media, sub)            # also upgrades a quick result in the background
    if job is None or cached(media, sub) is not None:
        return {"status": "ready", "progress": 1.0, "error": None}
    if job.error:
        return {"status": "failed", "progress": job.progress, "error": job.error}
    return {"status": "ready" if job.done.is_set() else "working",
            "progress": 1.0 if job.done.is_set() else round(job.progress, 2), "error": None}


def webvtt(cues):
    def t(s):
        ms = round(s * 1000)
        return f"{ms // 3600000:02d}:{ms // 60000 % 60:02d}:{ms // 1000 % 60:02d}.{ms % 1000:03d}"
    out = ["WEBVTT", ""]
    for start, end, text in cues:
        out += [f"{t(start)} --> {t(end)}", text, ""]
    return "\n".join(out) + "\n"


def _lock_for(path):
    with _locks_lock:
        return _locks.setdefault(str(path), threading.Lock())
