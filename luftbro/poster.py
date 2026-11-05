"""The now card's poster: the picture that says what a file is, decided once
per file in the background and kept (poster/<key>.jpg and .json under the
cache dir). In order of preference:

1. Cover art: an image inside the file (an MKV attachment, or the picture
   stream an MP4 carries a cover as) or a sidecar next to it (<name>.jpg,
   <name>-thumb.jpg, poster.jpg, fanart.jpg, landscape.jpg, ...; for an
   episode in a season folder also the series folder above). Landscape only:
   the card's tile is 16:9 and fills it, so a portrait poster would show as a
   slice of its middle.
2. The title card: frames around the end of the intro (markers.py) - for a
   film or an episode without one, the opening minutes - read with the
   Vision OCR helper (ocrsubs.py); the frames whose text says the title
   (names.py) are kept and the most colourful, well-lit one wins, so the
   title over the picture beats the title alone on black.
3. The best-looking thumbnail (thumbs.py): well lit, colourful, sharp, not
   near-black, not in the first or last 5 %.

With nothing found the app picks a frame itself. All of it runs at low
priority, after the thumbnails and the markers, never while a stream is
being prepared, and within a time budget (a film's opening minutes are
looked at keyframes only, the thumbnails first).
"""

import difflib
import hashlib
import json
import re
import shutil
import struct
import subprocess
import tempfile
import threading
import time
from pathlib import Path

from . import names, ocrsubs
from . import thumbs as thumbs_module
from .config import cache_dir

WIDTH = thumbs_module.WIDTH
QUALITY = 4
MAX_CACHED = 200            # posters kept, least recently used are removed
KEY_RE = re.compile(r"^[0-9a-f]{16}$")
FILE_NAME = "poster.jpg"        # served as /api/thumbs/<key>/poster.jpg
IMAGE_EXTS = (".jpg", ".jpeg", ".png")
LANDSCAPE_MIN_ASPECT = 1.2
# Sidecars named for the file, then for its folder; the landscape ones first.
FILE_SUFFIXES = ("-thumb", "-landscape", "-fanart", "-backdrop", "", "-poster")
FOLDER_NAMES = ("landscape", "fanart", "backdrop", "thumb", "cover_land", "cover", "poster", "folder")
SEASON_DIR_RE = re.compile(r"(?i)^(?:(?:season|series|s)\s?\d{1,2}|specials?)$")

TITLE_FPS = 2
INTRO_WINDOW_S = (14.0, 1.0)        # before and after the intro's end
OPENING_S = 480                     # a film's opening minutes
OPENING_STEP_S = 2
REFINE_WINDOW_S = (4.0, 6.0)        # around a coarse hit, decoded in full
RUN_GAP_S = 1.5                     # a misread frame this close to read ones is still the card
TITLE_BUDGET_S = 90
WAIT_THUMBS_S = 120
WAIT_MARKERS_S = 150
WAIT_BUSY_S = 60
EDGE_SHARE = 0.05                   # thumbnails in the first/last 5 % are not posters
STATS_SIZE = (64, 36)               # frames are shrunk to this before scoring
SUBPROCESS_TIMEOUT = 120


# ---- Pictures ----------------------------------------------------------------

def image_size(path):
    """(width, height) of a JPEG or PNG from its header, or None."""
    try:
        with open(path, "rb") as f:
            head = f.read(32)
            if head[:8] == b"\x89PNG\r\n\x1a\n" and head[12:16] == b"IHDR":
                return struct.unpack(">II", head[16:24])
            if head[:2] != b"\xff\xd8":
                return None
            f.seek(2)
            while True:
                marker = f.read(2)
                if len(marker) < 2 or marker[0] != 0xFF:
                    return None
                kind = marker[1]
                if kind == 0xFF:                    # padding
                    f.seek(-1, 1)
                    continue
                if kind in (0xD8, 0x01) or 0xD0 <= kind <= 0xD7:
                    continue                        # markers without a length
                (length,) = struct.unpack(">H", f.read(2))
                if 0xC0 <= kind <= 0xCF and kind not in (0xC4, 0xC8, 0xCC):
                    _, h, w = struct.unpack(">BHH", f.read(5))
                    return w, h
                f.seek(length - 2, 1)
    except (OSError, struct.error):
        return None


def is_landscape(size):
    return bool(size) and size[1] > 0 and size[0] / size[1] >= LANDSCAPE_MIN_ASPECT


def frame_scores(pixels, width, height):
    """How much each raw RGB frame (width x height, rgb24) looks like a
    poster: colourful, lit around the middle, with detail; a near-black frame
    (black leader, a title on black) scores -1 and is never chosen."""
    size = width * height * 3
    n = width * height
    out = []
    for i in range(len(pixels) // size):
        frame = pixels[i * size:(i + 1) * size]
        lum = [0.0] * n
        chroma = 0.0
        dark = 0
        for j in range(n):
            r, g, b = frame[3 * j] / 255, frame[3 * j + 1] / 255, frame[3 * j + 2] / 255
            y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            lum[j] = y
            chroma += max(r, g, b) - min(r, g, b)
            if y < 0.08:
                dark += 1
        luma, chroma, dark = sum(lum) / n, chroma / n, dark / n
        grad = 0.0
        for row in range(0, n, width):
            for x in range(width - 1):
                grad += abs(lum[row + x + 1] - lum[row + x])
        for j in range(n - width):
            grad += abs(lum[j + width] - lum[j])
        out.append(score(luma, chroma, grad / (2 * n), dark))
    return out


def score(luma, chroma, sharpness, dark_share):
    if luma < 0.08 or dark_share > 0.85:
        return -1.0
    return chroma + 3 * sharpness - 2 * abs(luma - 0.45) - 0.5 * dark_share


def _scores_of(folder, count=None):
    """frame_scores for the numbered JPEGs (00001.jpg ...) in a folder."""
    w, h = STATS_SIZE
    cmd = ["nice", "-n", "10", "ffmpeg", "-hide_banner", "-loglevel", "error", "-framerate", "1",
           "-i", str(folder / "%05d.jpg")]
    if count:
        cmd += ["-frames:v", str(count)]
    raw = subprocess.run(cmd + ["-vf", f"scale={w}:{h}:flags=area", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                         capture_output=True, check=True, timeout=SUBPROCESS_TIMEOUT).stdout
    return frame_scores(raw, w, h)


# ---- The title in a frame's text ------------------------------------------------

def letters(text):
    return re.sub(r"[^a-z]", "", (text or "").casefold())


def title_keys(info):
    """What the title card should say, letters only: the show for an episode,
    the film's title (without its year) otherwise, also without a leading
    "the" (title cards often drop it)."""
    title = info.get("show") if info.get("kind") == "episode" else info.get("title")
    title = re.sub(r"\s*\((?:19|20)\d{2}\)\s*$", "", title or "")
    keys = [letters(title)]
    if keys[0].startswith("the"):
        keys.append(keys[0][3:])
    return [k for k in dict.fromkeys(keys) if len(k) >= 3]


def text_matches(text, key):
    """Whether recognised text says the title: letters only, case-insensitive,
    and (for titles long enough to be unmistakable) a few letters off - a fast
    OCR pass can read "HARBOUR LIGHTS" as "HARBDUR LIGHIS"."""
    t = letters(text)
    if len(key) < 3 or not t:
        return False
    if key in t:
        return True
    if len(key) <= 5:
        return False
    need = 0.8 if len(key) >= 8 else 0.86
    for span in (len(key) - 1, len(key), len(key) + 1):
        for i in range(max(1, len(t) - span + 1)):
            sm = difflib.SequenceMatcher(None, t[i:i + span], key)
            if sm.quick_ratio() >= need and sm.ratio() >= need:
                return True
    return False


def matches_any(text, keys):
    return any(text_matches(text, k) for k in keys)


# ---- The store ------------------------------------------------------------------

class PosterStore:
    """One poster per file (path, size, mtime), decided one at a time in the
    background. `thumbs()` gives the ThumbnailStore, `markers(media)` answers
    like GET /api/markers, `busy()` says whether a stream is being prepared
    (the heavy steps wait for it)."""

    VERSION = 1             # part of the cache key: a better chooser looks at every file again

    def __init__(self, root=None, thumbs=None, markers=None, busy=None):
        self._root = Path(root) if root else None
        self._thumbs = thumbs or (lambda: None)
        self._markers = markers or (lambda media: {"status": "unavailable", "intro": None})
        self._busy = busy or (lambda: False)
        self._lock = threading.Lock()
        self._running = {}              # key -> Thread
        self._one_at_a_time = threading.Semaphore(1)

    @property
    def root(self):
        return self._root or cache_dir() / "poster"

    @classmethod
    def key(cls, media):
        return hashlib.sha1(f"{cls.VERSION}|{media.fingerprint}".encode()).hexdigest()[:16]

    def status(self, media, start=True):
        """{"status": "done" | "working" | "unavailable", "source": "cover" |
        "title" | "frame" | None, "time": seconds | None, "url": ... | None}.
        `start` begins the choosing the first time; without it (and without a
        result) the answer is "unavailable", as it is for a download in progress."""
        key = self.key(media)
        result = self.root / f"{key}.json"
        try:
            found = json.loads(result.read_text())
            result.touch()                   # most recently used, for pruning
            return {"status": "done", **self._answer(key, found)}
        except (OSError, ValueError):
            pass
        if not start or media.partial:
            return {"status": "unavailable", "source": None, "time": None, "url": None}
        with self._lock:
            t = self._running.get(key)
            if t is None or not t.is_alive():
                t = threading.Thread(target=self._choose, args=(media, key), daemon=True)
                self._running[key] = t
                t.start()
        return {"status": "working", "source": None, "time": None, "url": None}

    def _answer(self, key, found):
        image = self.root / f"{key}.jpg"
        return {"source": found.get("source"), "time": found.get("time"),
                "url": f"/api/thumbs/{key}/{FILE_NAME}" if found.get("source") and image.is_file() else None}

    def file(self, key):
        """The poster image for GET /api/thumbs/<key>/FILE_NAME, or None."""
        if not KEY_RE.match(key):
            return None
        path = self.root / f"{key}.jpg"
        return path if path.is_file() else None

    # ---- choosing ------------------------------------------------------------

    def _choose(self, media, key):
        with self._one_at_a_time:
            try:
                self.root.mkdir(parents=True, exist_ok=True)
                self._prune(exclude={key})
            except OSError:
                return
            found = self._try(self._cover, media, key)
            if found is None:
                self._wait_for_thumbs(media)
                intro_end = self._intro_end(media)
                self._wait_while_busy()
                found = self._try(self._title_card, media, key, intro_end)
            if found is None:
                found = self._try(self._best_thumbnail, media, key)
            try:
                tmp = self.root / f"{key}.json.tmp"
                tmp.write_text(json.dumps(found or {"source": None, "time": None}))
                tmp.replace(self.root / f"{key}.json")
            except OSError:
                pass

    @staticmethod
    def _try(step, *args):
        """A step that fails (ffmpeg, the OCR helper, a file gone) found nothing."""
        try:
            return step(*args)
        except (OSError, subprocess.SubprocessError, ValueError, ocrsubs.OCRError):
            return None

    def _wait(self, settled, timeout):
        deadline = time.monotonic() + timeout
        while not settled() and time.monotonic() < deadline:
            time.sleep(0.5)

    def _wait_for_thumbs(self, media):
        """The thumbnails first: they are the fallback, and the opening-minutes
        search reads them before decoding anything."""
        store = self._thumbs()
        if store is None:
            return
        self._wait(lambda: store.folder(media) is not None or not store.running(media), WAIT_THUMBS_S)

    def _intro_end(self, media):
        """The end of the intro once the markers are known, or None."""
        answer = {}

        def settled():
            answer.update(self._markers(media))
            return answer.get("status") != "working"
        self._wait(settled, WAIT_MARKERS_S)
        intro = answer.get("intro")
        return intro.get("end") if isinstance(intro, dict) else None

    def _wait_while_busy(self):
        self._wait(lambda: not self._busy(), WAIT_BUSY_S)

    # ---- 1. cover art --------------------------------------------------------

    def _cover(self, media, key):
        with tempfile.TemporaryDirectory(prefix="luftbro-poster-") as tmp:
            for n, candidate in enumerate(cover_candidates(media)):
                image = self._materialise(media, candidate, Path(tmp) / f"cover{n}")
                if image is not None and is_landscape(image_size(image)) and self._write(key, image, convert=True):
                    return {"source": "cover", "time": None}
        return None

    def _materialise(self, media, candidate, out):
        kind, what = candidate
        if kind == "file":
            return what
        if kind == "picture":
            out = out.with_suffix(".png")
            subprocess.run(["nice", "-n", "10", "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                            "-i", str(media.path), "-map", f"0:{what}", "-frames:v", "1", "-update", "1", str(out)],
                           capture_output=True, timeout=SUBPROCESS_TIMEOUT)
        else:
            # ffmpeg writes the attachment while opening the input, then
            # complains about the missing output: the file is what counts.
            subprocess.run(["nice", "-n", "10", "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                            f"-dump_attachment:{what}", str(out), "-i", str(media.path)],
                           capture_output=True, timeout=SUBPROCESS_TIMEOUT)
        return out if out.is_file() and out.stat().st_size > 0 else None

    # ---- 2. the title card -----------------------------------------------------

    def _title_card(self, media, key, intro_end):
        keys = title_keys(names.parse(media.path))
        if not keys or not ocrsubs.possible():
            return None
        deadline = time.monotonic() + TITLE_BUDGET_S
        with tempfile.TemporaryDirectory(prefix="luftbro-poster-") as tmp:
            tmp = Path(tmp)
            if intro_end is not None:
                start = max(0.0, intro_end - INTRO_WINDOW_S[0])
                best = self._best_match(media, tmp / "intro", start, sum(INTRO_WINDOW_S), keys, keyframes=False)
                if best:
                    return self._keep(key, best, "title")
            if time.monotonic() > deadline:
                return None
            # The opening minutes, coarse first: the thumbnails cost nothing,
            # keyframes little; only around a hit is the picture decoded in full.
            hit = self._thumbnail_hit(media, keys)
            if hit is None and time.monotonic() < deadline:
                hit = self._keyframe_hit(media, tmp / "opening", keys)
            if hit is None or time.monotonic() > deadline:
                return None
            at, coarse = hit
            start = max(0.0, at - REFINE_WINDOW_S[0])
            best = self._best_match(media, tmp / "refine", start, sum(REFINE_WINDOW_S), keys, keyframes=False)
            return self._keep(key, best or (at, coarse), "title")

    def _keep(self, key, found, source):
        at, image = found
        return {"source": source, "time": round(at, 3)} if self._write(key, image) else None

    def _thumbnail_hit(self, media, keys):
        """(time, file) of the first thumbnail of the opening minutes whose text says the title."""
        folder = self._thumbnail_folder(media)
        if folder is None:
            return None
        interval = thumbs_module.INTERVAL_S
        files = [folder / f"{n:05d}.jpg" for n in range(1, int(OPENING_S / interval) + 1)]
        files = [f for f in files if f.is_file()]
        texts = self._read(files)
        for f in files:
            if matches_any(texts.get(str(f), ""), keys):
                return (int(f.stem) - 1) * interval, f
        return None

    def _keyframe_hit(self, media, outdir, keys):
        length = min(OPENING_S, media.duration) if media.duration > 0 else OPENING_S
        frames = self._sample(media, outdir, 0.0, length, fps=1 / OPENING_STEP_S, keyframes=True)
        texts = self._read([f for _, f in frames])
        for at, f in frames:
            if matches_any(texts.get(str(f), ""), keys):
                return at, f
        return None

    def _best_match(self, media, outdir, start, length, keys, keyframes):
        """(time, file) of the best-looking frame in the window whose text
        says the title. A frame between two that do, less than RUN_GAP_S
        from each, counts too: the card stays on screen while the quick OCR
        pass misreads the odd frame of it (often the sharpest, during a move)."""
        frames = self._sample(media, outdir, start, length, fps=TITLE_FPS, keyframes=keyframes)
        if not frames:
            return None
        texts = self._read([f for _, f in frames])
        scores = _scores_of(outdir)
        said = [at for at, f in frames if matches_any(texts.get(str(f), ""), keys)]
        best = None
        for n, (at, f) in enumerate(frames):
            if n >= len(scores) or scores[n] <= -1 or not in_run(at, said):
                continue
            if best is None or scores[n] > best[0]:
                best = (scores[n], at, f)
        return best[1:] if best else None

    def _read(self, files):
        return ocrsubs.recognize(files, [], fast=True, low_priority=True) if files else {}

    def _sample(self, media, outdir, start, length, fps, keyframes):
        """[(time, file)] of frames `fps` apart from `start` (keyframes only:
        the last keyframe before each point). Tone-mapped when HDR, else as is."""
        attempts = [True, False] if media.hdr else [False]
        for tonemap in attempts:
            shutil.rmtree(outdir, ignore_errors=True)
            outdir.mkdir(parents=True)
            cmd = (["nice", "-n", "10", "ffmpeg", "-hide_banner", "-loglevel", "error", "-nostats", "-y"]
                   + (["-skip_frame", "nokey"] if keyframes else []) + thumbs_module.decode_args(tonemap)
                   + ["-ss", f"{start:.3f}", "-t", f"{length:.3f}", "-i", str(media.path),
                      "-map", f"0:{media.video['index']}", "-an", "-sn", "-dn",
                      "-vf", f"fps={fps:g}," + thumbs_module.scale_filter(WIDTH, thumbs_module.thumb_height(media), tonemap),
                      "-q:v", str(QUALITY), str(outdir / "%05d.jpg")])
            r = subprocess.run(cmd, capture_output=True, timeout=SUBPROCESS_TIMEOUT)
            files = sorted(outdir.glob("*.jpg"))
            if r.returncode == 0 and files:
                return [(start + (int(f.stem) - 1) / fps, f) for f in files]
        return []

    # ---- 3. the best thumbnail ---------------------------------------------------

    def _thumbnail_folder(self, media):
        store = self._thumbs()
        return store.folder(media) if store is not None else None

    def _best_thumbnail(self, media, key):
        folder = self._thumbnail_folder(media)
        if folder is None:
            return None
        count = len(list(folder.glob("[0-9]*.jpg")))
        if count == 0:
            return None
        scores = _scores_of(folder, count)
        n = best_frame(scores)
        if n is None:
            return None
        at = n * thumbs_module.INTERVAL_S
        return {"source": "frame", "time": at} if self._write(key, folder / f"{n + 1:05d}.jpg") else None

    # ---- housekeeping ------------------------------------------------------------

    def _write(self, key, image, convert=False):
        """Keep `image` as this file's poster; a cover is remade at the
        thumbnails' size (any size and format comes in)."""
        target = self.root / f"{key}.jpg"
        tmp = self.root / f"{key}.jpg.tmp"
        try:
            if convert:
                r = subprocess.run(["nice", "-n", "10", "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                                    "-i", str(image), "-frames:v", "1", "-update", "1",
                                    "-vf", f"scale={WIDTH}:-2,format=yuvj420p", "-q:v", str(QUALITY), "-f", "image2", str(tmp)],
                                   capture_output=True, timeout=SUBPROCESS_TIMEOUT)
                if r.returncode != 0 or not tmp.is_file():
                    return False
            else:
                shutil.copyfile(image, tmp)
            tmp.replace(target)
            return True
        except (OSError, subprocess.SubprocessError):
            return False

    def _prune(self, exclude):
        try:
            results = [p for p in self.root.glob("*.json") if p.stem not in exclude]
        except OSError:
            return
        results.sort(key=lambda p: p.stat().st_mtime, reverse=True)
        for p in results[MAX_CACHED - 1:]:
            p.unlink(missing_ok=True)
            p.with_suffix(".jpg").unlink(missing_ok=True)


def in_run(at, said, gap=None):
    """Whether `at` is one of the times in `said`, or lies between two of
    them less than `gap` seconds away on each side."""
    gap = RUN_GAP_S if gap is None else gap
    if at in said:
        return True
    return any(0 < at - t < gap for t in said) and any(0 < t - at < gap for t in said)


def best_frame(scores, edge=EDGE_SHARE):
    """Index of the best-scoring frame outside the first and last `edge`
    share (studio logos, credits), or None when every frame is near-black."""
    if not scores:
        return None
    margin = int(len(scores) * edge)
    inner = range(margin, len(scores) - margin) if len(scores) - 2 * margin > 0 else range(len(scores))
    n = max(inner, key=lambda i: scores[i])
    return n if scores[n] > -1 else None


def cover_candidates(media):
    """Where cover art may be, most likely first: [("attachment" | "picture",
    stream index) | ("file", path)]. Inside the file, the ones named as
    landscape first; next to it, the sidecars named for the file, then the
    folder's, then (an episode in a season folder) the series folder's."""
    out = []
    inside = sorted(media.covers, key=lambda c: "land" not in c[1].lower())
    out += [(kind, index) for index, _, kind in inside]
    path = names.without_partial(media.path)
    stem = path.stem
    folders = [path.parent]
    if names.parse(path)["kind"] == "episode" and SEASON_DIR_RE.match(path.parent.name):
        folders.append(path.parent.parent)
    wanted = [f"{stem}{suffix}" for suffix in FILE_SUFFIXES] + list(FOLDER_NAMES)
    seen = set()            # one entry per file on a case-insensitive disk
    for n, folder in enumerate(folders):
        for name in (wanted if n == 0 else FOLDER_NAMES):
            for ext in IMAGE_EXTS:
                for f in (folder / (name + ext), folder / (name + ext.upper())):
                    try:
                        st = f.stat()
                    except OSError:
                        continue
                    if (st.st_dev, st.st_ino) not in seen and f.is_file():
                        seen.add((st.st_dev, st.st_ino))
                        out.append(("file", f))
    return out
