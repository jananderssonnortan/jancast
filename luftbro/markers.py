"""Where an episode's intro and end credits are, for Skip Intro and Next
Episode: from the file's chapters when they are named that way (Blu-ray rips
and anime often have "Intro" / "Opening" / "OP" and "Credits" / "Ending" /
"ED"; generic ones like "Chapter 3" say nothing), else the credits from the
picture, and the intro by matching its sound with a neighbouring episode
(below)."""

import hashlib
import json
import re
import subprocess
import threading
from array import array
from collections import Counter

from . import episodes
from .config import cache_dir
from .media import MediaError
from .media import probe as probe_file

INTRO = re.compile(
    r"(intro|intro (song|theme)|introduction|opening|opening (credits|titles|theme|song|sequence)|op|"
    r"title sequence|main titles?|theme|theme song|titles)")
# "Titles" is both: the intro when early, else the credits.
CREDITS = re.compile(
    r"(credits|end credits|closing credits|end titles?|closing titles|ending|ending (credits|theme|song)|"
    r"end|ed|outro|closing|titles)")

# An intro is near the start and not a whole act; credits are in the second half.
INTRO_MAX_START_S = 600
INTRO_LENGTH_S = (5, 300)


def _name(title):
    """"Opening Credits", "OP1", "02 - Intro", "Chapter 5: Ending",
    "Credits (Part 2)" -> comparable words ("op", "intro", "ending", "credits")."""
    t = title.lower()
    t = re.sub(r"^(chapter\s*)?\d+\s*[-:.)]?\s+", "", t)  # "02 - Intro", "02 Intro", "Chapter 5: Ending"
    t = re.sub(r"[^\w\s]", " ", t)
    t = re.sub(r"(?<=[a-z])(?=\d)", " ", t)                  # "op1" -> "op 1"
    t = re.sub(r"(\s+part)?\s+\d+$", "", " ".join(t.split()))  # "op 1", "credits part 2"
    return t


def from_chapters(chapters, duration):
    """{"intro": {"start", "end"} | None, "credits": {"start"} | None} from
    [(start_s, end_s, title)]."""
    intro = credits = None
    for start, end, title in chapters:
        name = _name(title or "")
        if not name:
            continue
        length = end - start
        # Unknown length (a download in progress): only the 10-minute limit.
        latest = min(INTRO_MAX_START_S, duration / 2) if duration > 0 else INTRO_MAX_START_S
        if (intro is None and INTRO.fullmatch(name) and start < latest
                and INTRO_LENGTH_S[0] <= length <= INTRO_LENGTH_S[1]):
            intro = {"start": round(start, 3), "end": round(end, 3)}
        elif credits is None and CREDITS.fullmatch(name) and duration > 0 and start >= duration / 2:
            credits = {"start": round(start, 3)}
    return {"intro": intro, "credits": credits}


# ---- Found without chapters ---------------------------------------------------
#
# Most files have no (named) chapters. Then the end credits are found in the
# picture: they are black with white text. Keyframes of the last minutes find
# the dark tail roughly; a 2 fps decode around its edge finds the second. Run
# in the background (an episode takes 1-2 s), kept per file; the app asks with
# GET /api/markers while an episode plays. Credits over pictures are not found
# (Up Next falls back to the last 2 1/2 minutes), and epilogue cards or a dark,
# colourless last shot make it 10-30 s early.

CREDITS_WINDOW_S = 360      # how much of the end is looked at
CREDITS_MIN_S = 20          # a dark run shorter than this is a scene, not credits
CREDITS_GAP_S = 8           # brighter moments inside the credits (a logo card)
CREDITS_TAIL_S = 40         # studio logos after the credits, before the end
CREDITS_LAST_SHARE = 0.15   # credits start in the last 15 % of an episode


def _dark(yhigh, satavg):
    """Credits: 90 % of the pixels near black and no colour, or a colourless,
    dark card full of text."""
    return (yhigh < 24 and satavg < 6) or (satavg < 0.5 and yhigh < 60)


def _frame_stats(path, start, length=None, keyframes=False, fps=None):
    """[(time_s, dark)] for the video from `start`, sorted by time."""
    # format=yuv420p: 10-bit video reports luma 0-1023 otherwise.
    vf = (f"fps={fps}," if fps else "") + "scale=160:-2,format=yuv420p,signalstats,metadata=print:file=-"
    cmd = (["nice", "-n", "10", "ffmpeg", "-v", "error"] + (["-skip_frame", "nokey"] if keyframes else [])
           + ["-ss", f"{start:.3f}"] + (["-t", f"{length:.3f}"] if length else [])
           + ["-i", str(path), "-map", "0:v:0", "-an", "-sn", "-vf", vf,
              "-fps_mode", "passthrough", "-f", "null", "-"])
    out = subprocess.run(cmd, capture_output=True, text=True, timeout=180).stdout
    frames = []
    for block in out.split("frame:")[1:]:
        t, y, sat = (re.search(rf"{k}:?=?([\d.]+)", block) for k in ("pts_time", "YHIGH", "SATAVG"))
        if not (t and y and sat):
            continue
        t = float(t.group(1))
        # Times come relative to the seek point or absolute, depending on the file.
        frames.append((t if t >= start - 1 else start + t, _dark(float(y.group(1)), float(sat.group(1)))))
    return sorted(frames)          # decode order: B-frames come out of order


def credits_from_picture(path, duration):
    """Start of the end credits (seconds) from the picture, or None."""
    if duration <= 0:
        return None
    start = max(0.0, duration - CREDITS_WINDOW_S)
    first = last_dark = bright_before = None
    for t, dark in reversed(_frame_stats(path, start, keyframes=True)):
        if dark:
            first = last_dark = t
        elif last_dark is None:
            if duration - t > CREDITS_TAIL_S:
                return None                 # bright up to the end: no dark credits
        elif last_dark - t > CREDITS_GAP_S:
            bright_before = t
            break
    if first is None or duration - first < CREDITS_MIN_S:
        return None
    # The exact second: the last bright frame before the dark run.
    lo = bright_before if bright_before is not None else max(start, first - 30)
    begin = first
    for t, dark in reversed([f for f in _frame_stats(path, lo, length=first - lo + 1, fps=2)
                             if f[0] <= first + 0.5]):
        if not dark:
            break
        begin = t
    if duration - begin > duration * CREDITS_LAST_SHARE:
        return None
    return begin


def detect_credits(media):
    try:
        return credits_from_picture(media.path, media.duration)
    except (OSError, subprocess.SubprocessError, ValueError):
        return None


# ---- The intro by its sound -----------------------------------------------------
#
# A series' intro sounds the same in every episode, wherever the cold open
# makes it start. The first 10 minutes of two episodes become audio
# fingerprints (ffmpeg draws a 300-2000 Hz spectrogram; one 32-bit
# Haitsma-Kalker print per 1/8 s), the time offset most prints agree on is
# found, and along it the longest stretch that matches is the intro. Its end
# is where the shared sound ends: with the title card and the "Written by"
# cards, a better place to land than a chapter's end. Episodes are compared
# nearest first (a series can change its intro halfway through a season). An
# episode whose first minutes share no sound with its neighbours (a pilot or
# finale with its own opening) gets no intro.

INTRO_WINDOW_S = 900        # the first 15 minutes: cold opens can run past 12
INTRO_LENGTH_RANGE_S = (20, 180)
PRINTS_PER_S = 8
BANDS = 33                  # -> 32 bits per print
AUDIO_RATE = 5512


def _spectrum(path, length):
    """[[band energy 0-255] * BANDS] per print, low band first."""
    cols = int(length * PRINTS_PER_S)
    graph = (f"[0:a:0]aresample={AUDIO_RATE},aformat=channel_layouts=mono,"
             f"showspectrumpic=s={cols}x512:legend=0:fscale=log:start=300:stop=2000:"
             f"color=intensity:scale=log:mode=combined,format=gray,scale={cols}:{BANDS}:flags=area[v]")
    raw = subprocess.run(["nice", "-n", "10", "ffmpeg", "-v", "error", "-t", f"{length:.3f}",
                          "-i", str(path), "-filter_complex", graph, "-map", "[v]", "-frames:v", "1",
                          "-f", "rawvideo", "-pix_fmt", "gray", "-"],
                         capture_output=True, check=True, timeout=300).stdout
    if len(raw) != cols * BANDS:
        raise ValueError("unexpected spectrogram size")
    # Rows run from high to low frequency.
    return [[raw[(BANDS - 1 - r) * cols + c] for r in range(BANDS)] for c in range(cols)]


def _prints(spec):
    """One 32-bit print per column: did each band difference grow since the last column."""
    out = [0]
    for n in range(1, len(spec)):
        e, p = spec[n], spec[n - 1]
        v = 0
        for m in range(BANDS - 1):
            if (e[m] - e[m + 1]) - (p[m] - p[m + 1]) > 0:
                v |= 1 << m
        out.append(v)
    return out


def _best_offsets(a, b, count=15):
    """The offsets d (print i in a = print j in b + d) most 16-bit halves agree
    on, strongest first, neighbours (±2 prints) merged into one."""
    index = {}
    for i, v in enumerate(a):
        index.setdefault(v & 0xFFFF, []).append(i)
        index.setdefault((v >> 16) | 1 << 20, []).append(i)
    votes = Counter()
    for j, v in enumerate(b):
        for key in (v & 0xFFFF, (v >> 16) | 1 << 20):
            hits = index.get(key)
            if hits and len(hits) < 50:          # silence-like prints are everywhere
                for i in hits:
                    votes[i - j] += 1
    out = []
    for d, _ in votes.most_common():
        if all(abs(d - o) > 2 for o in out):
            out.append(d)
            if len(out) == count:
                break
    return out


def _shared_span(a, b, d, window=16, max_error=0.35, min_s=10):
    """The longest stretch along offset d whose bit error rate, smoothed over 2 s,
    stays under max_error: (first print in a, last print in a, error rate)."""
    js = [j for j in range(len(b)) if 0 <= j + d < len(a)]
    errors = [bin(a[j + d] ^ b[j]).count("1") / 32 for j in js]
    half = window // 2
    good = []
    for k in range(len(js)):
        lo, hi = max(0, k - half), min(len(js), k + half)
        good.append(sum(errors[lo:hi]) / (hi - lo) < max_error)
    best, k = None, 0
    while k < len(js):
        if good[k]:
            s = k
            while k < len(js) and good[k]:
                k += 1
            if best is None or k - s > best[1] - best[0]:
                best = (s, k)
        else:
            k += 1
    if not best or best[1] - best[0] < min_s * PRINTS_PER_S:
        return None
    s, e = best
    return js[s] + d, js[e - 1] + d, sum(errors[s:e]) / (e - s)


def intro_from_prints(mine, other):
    """{"start", "end"} of the sound shared with another episode's first
    minutes, when it looks like an intro; with its error rate. Or None.

    Several offsets are tried, not just the one most prints agree on: a studio
    logo at the same moment in every episode can win that vote (offset 0) and
    is too short for an intro, while the real one can rank far down the list.
    The longest stretch that fits an intro wins."""
    best = None
    for d in _best_offsets(mine, other):
        span = _shared_span(mine, other, d)
        if not span:
            continue
        first, last, error = span
        start, end = first / PRINTS_PER_S, (last + 1) / PRINTS_PER_S
        if start >= INTRO_WINDOW_S or not INTRO_LENGTH_RANGE_S[0] <= end - start <= INTRO_LENGTH_RANGE_S[1]:
            continue
        if best is None or end - start > best[0]["end"] - best[0]["start"]:
            best = ({"start": round(start, 3), "end": round(end, 3)}, error)
    return best


class MarkerStore:
    """Detected markers per file (path, size, mtime), made one at a time in the
    background, at low priority."""

    # Part of the cache key: a better detector looks at every file again
    # (a cached "no credits" would otherwise stick).
    VERSION = 3                 # the detectors (credits and intro)
    PRINTS_VERSION = 2          # the prints (INTRO_WINDOW_S, the print format)

    def __init__(self, root=None):
        self._root = root
        self._lock = threading.Lock()
        self._running = {}              # key -> Thread
        self._one_at_a_time = threading.Semaphore(1)

    @property
    def root(self):
        return self._root or cache_dir() / "markers"

    @classmethod
    def key(cls, media):
        return hashlib.sha1(f"{cls.VERSION}|{media.fingerprint}".encode()).hexdigest()[:16]

    def status(self, media):
        """{"status": "working" | "done" | "unavailable", "intro", "credits"};
        starts the detection the first time. Only for episodes with a
        neighbour: the intro is compared with one, and the credits are where
        the next one is offered."""
        key = self.key(media)
        result = self.root / f"{key}.json"
        try:
            return {"status": "done", **json.loads(result.read_text())}
        except (OSError, ValueError):
            pass
        if media.partial or not (episodes.next_episode(media.path) or episodes.previous_episode(media.path)):
            return {"status": "unavailable", "intro": None, "credits": None}
        with self._lock:
            t = self._running.get(key)
            if t is None or not t.is_alive():
                t = threading.Thread(target=self._detect, args=(media, result), daemon=True)
                self._running[key] = t
                t.start()
        return {"status": "working", "intro": None, "credits": None}

    def _detect(self, media, result):
        with self._one_at_a_time:
            credits = None
            if episodes.next_episode(media.path):
                start = detect_credits(media)
                if start is not None:
                    credits = {"start": round(start, 3), "source": "picture"}
            intro = self.detect_intro(media)
            try:
                result.parent.mkdir(parents=True, exist_ok=True)
                tmp = result.with_suffix(".tmp")
                tmp.write_text(json.dumps({"intro": intro, "credits": credits}))
                tmp.replace(result)
            except OSError:
                pass

    def detect_intro(self, media):
        """The intro by its sound: compared with the nearest episodes (before,
        after, two before, two after) until one shares it; or None."""
        try:
            mine = self.prints(media)
        except (OSError, subprocess.SubprocessError, ValueError):
            return None
        for other in episodes.nearest_episodes(media.path, 4):
            try:
                found = intro_from_prints(mine, self.prints(probe_file(other)))
            except (MediaError, OSError, subprocess.SubprocessError, ValueError):
                continue
            if found:
                return {**found[0], "source": "audio"}
        return None

    def prints(self, media):
        """The audio prints of a file's first minutes, made once and kept
        (about 20 KB): the neighbour's are usually there already."""
        key = hashlib.sha1(f"{self.PRINTS_VERSION}|{media.fingerprint}".encode()).hexdigest()[:16]
        path = self.root / "prints" / f"{key}.bin"
        try:
            a = array("I")
            a.frombytes(path.read_bytes())
            return a.tolist()
        except (OSError, ValueError):
            pass
        length = min(INTRO_WINDOW_S, media.duration) if media.duration > 0 else INTRO_WINDOW_S
        values = _prints(_spectrum(media.path, length))
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            tmp = path.with_suffix(".tmp")
            tmp.write_bytes(array("I", values).tobytes())
            tmp.replace(path)
        except OSError:
            pass
        return values
