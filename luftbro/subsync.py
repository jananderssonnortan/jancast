"""Automatic subtitle sync: how a text subtitle track's times map onto the
speech in the audio, so a subtitle file made for another release of the
film (a longer studio logo, a cut intro, another frame rate) can be fitted.

Three five-minute stretches spread over the file are decoded to 16 kHz mono
(the centre channel of surround sound, where the dialogue sits), and the
sound classifier built into macOS (SoundAnalysis, through the helper in
ocr_helper.swift) says every tenth of a second how sure it is that someone
speaks. Without the helper, loudness in the voice band stands in; that is
less reliable, since music and effects count as speech too. The track's cues
are then slid over that in 50 ms steps, up to a minute either way, and the
shift that puts the most speech inside a subtitle wins; how far the peak
stands above the rest of the curve is the confidence.

Each stretch is also judged alone. When they agree, one delay fits the whole
film. When they disagree the subtitles drift: they run fast or slow, usually
because they were made for a release at another frame rate (25 fps against
23.976). Then the cues are stretched as well, t -> t * scale + offset: by
each frame-rate ratio, and by the scale a line through the stretches' own
offsets gives, each refined until the stretches agree; the best fit wins,
snapped to the frame-rate ratio it is within measuring precision of. A
drift no single scale fits (subtitles for another cut, with scenes added or
removed) is reported, not applied.

Results are kept per file, subtitle track and audio track under the cache
dir, like the intro and credits markers."""

import hashlib
import json
import math
import os
import operator
import re
import subprocess
import tempfile
import threading
from array import array
from pathlib import Path

from . import ocrsubs
from .config import cache_dir
from .media import extract_text_subtitles

WINDOW_S = 300                  # one stretch of audio
WINDOW_AT = (0.12, 0.5, 0.88)   # where the stretches are centred (not the credits)
MAX_OFFSET_S = 60               # the delay the player allows
BIN_S = 0.05                    # the step the cues are slid in
AUDIO_RATE = 16000
# Subtitles stay on a little after the voice stops (reading time), so the
# middle of a cue sits after the middle of its speech: timed by the book
# they measure this much late on the slide, and that is the sync to keep.
LINGER_S = 0.3
MIN_CUES = 10
# How far a peak stands above the runner-up (0-1; 1 is "nothing else comes
# close"). Three stretches that agree to a fraction of a second are strong
# evidence even when each peak alone is modest, so the bar is lower for a
# stretch than for the sum of them.
MIN_MARGIN = 0.35
MIN_STRETCH_MARGIN = 0.3
DRIFT_S = 0.5                   # stretches that disagree by more than this: drift
# A scale further than this from 1 is no frame-rate mix-up (the largest,
# 25 against 23.976 fps, is 4.3 %): such a fit is a coincidence, refused.
MAX_STRETCH = 0.06
# How far from a frame-rate ratio a fitted scale may be and still be taken
# as that ratio: the stretches' offsets are good to a few hundredths of a
# second over thousands of seconds, and the closest two ratios (25/23.976
# and 25/24) are 0.1 % apart.
SNAP = 4e-4
# A scale this close to 1 drifts less than a tenth of a second over two
# hours: no stretch.
MIN_STRETCH = 1e-5
DRIFT_STEP_S = 0.1              # the coarser slide while looking for drift
FRAME_RATES = (("23.976", 24000 / 1001), ("24", 24.0), ("25", 25.0),
               ("29.97", 30000 / 1001), ("30", 30.0))
# (scale, made for, video): subtitles timed for a release at one frame rate
# on a video at another run fast or slow by the ratio of the two.
RATIOS = tuple((made / video, a, b) for a, made in FRAME_RATES for b, video in FRAME_RATES
               if a != b and abs(made / video - 1) <= MAX_STRETCH)

DRIFT_NOTE = ("The subtitles drift in a way no stretch fits: they may be for another cut, "
              "with scenes added or removed.")
UNSURE_NOTE = "Couldn’t tell where the subtitles fit: no clear match with the speech."
ENERGY_NOTE = ("Measured from loudness alone (the sound classifier isn’t available), "
               "so this is less reliable.")


class SyncError(Exception):
    pass


# ---- The cues ----------------------------------------------------------------

_TIME = r"(?:(\d+):)?(\d{1,2}):(\d{2})[.,](\d{1,3})"
_ARROW = re.compile(rf"{_TIME}\s*-->\s*{_TIME}")
_DIALOGUE = re.compile(r"^Dialogue:\s*[^,]*,(\d+):(\d{2}):(\d{2})[.:](\d{1,3}),(\d+):(\d{2}):(\d{2})[.:](\d{1,3}),",
                       re.M)


def _seconds(h, m, s, frac):
    return int(h or 0) * 3600 + int(m) * 60 + int(s) + int(frac) / 10 ** len(frac)


def _is_ass(text):
    return "[Events]" in text or "\nDialogue:" in text or text.startswith("Dialogue:")


def parse_cues(text):
    """[(start_s, end_s)] of an SRT, WebVTT or ASS/SSA file, sorted, with
    overlapping cues merged (two speakers at once are one stretch of speech)."""
    if _is_ass(text):
        found = [(_seconds(*m[0:4]), _seconds(*m[4:8])) for m in _DIALOGUE.findall(text)]
    else:
        found = [(_seconds(*m[0:4]), _seconds(*m[4:8])) for m in _ARROW.findall(text)]
    merged = []
    for start, end in sorted(c for c in found if c[1] > c[0]):
        if merged and start <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))
        else:
            merged.append((start, end))
    return merged


def read_text(path):
    """A subtitle file's text, whatever it is encoded in (UTF-8 with or without
    a BOM, UTF-16, else Latin-1: the times are ASCII either way)."""
    raw = Path(path).read_bytes()
    if raw[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return raw.decode("utf-16", errors="replace")
    try:
        return raw.decode("utf-8-sig")
    except UnicodeDecodeError:
        return raw.decode("latin-1")


_CLOCK = re.compile(r"(?:(\d+):)?(\d{1,2}):(\d{2})([.,])(\d{1,3})")
_T = r"(?:\d+:)?\d{1,2}:\d{2}[.,]\d{1,3}"
_ARROW_TIMES = re.compile(rf"({_T})(\s*-->\s*)({_T})")
_EVENT_TIMES = re.compile(r"^((?:Dialogue|Comment):\s*[^,]*,)(\d+:\d{2}:\d{2}\.\d{1,3}),(\d+:\d{2}:\d{2}\.\d{1,3}),",
                          re.M)


def _moved(clock, scale, offset):
    """One cue time moved to t * scale + offset, written the way it was (hours
    or none, separator, decimals); a time before the start becomes 0."""
    h, m, s, sep, frac = _CLOCK.fullmatch(clock).groups()
    unit = 10 ** len(frac)
    ticks = max(0, round((_seconds(h, m, s, frac) * scale + offset) * unit))
    secs, part = divmod(ticks, unit)
    text = f"{secs // 60 % 60:02d}:{secs % 60:02d}{sep}{part:0{len(frac)}d}"
    if h is not None or secs >= 3600:
        text = f"{secs // 3600:0{len(h or '00')}d}:" + text
    return text


def retime_text(text, scale, offset=0.0):
    """An SRT, WebVTT or ASS/SSA file's text with every cue time t moved to
    t * scale + offset (+ = later): only the times change, in place, so the
    order, the styling and everything else stay as they were."""
    if _is_ass(text):
        return _EVENT_TIMES.sub(lambda m: f"{m[1]}{_moved(m[2], scale, offset)},{_moved(m[3], scale, offset)},",
                                text)
    return _ARROW_TIMES.sub(lambda m: f"{_moved(m[1], scale, offset)}{m[2]}{_moved(m[3], scale, offset)}", text)


def retimed_file(path, scale, offset=0.0):
    """A copy of a subtitle file with its cue times moved (retime_text), kept
    under the cache dir beside the extracted tracks. Its name ends in the
    original's, so it is read as the same format (and an OCR text keeps its
    quality mark, ".fast.vtt")."""
    path = Path(path)
    st = path.stat()
    key = hashlib.sha1(f"{path}|{st.st_size}|{st.st_mtime}|{scale!r}|{offset!r}".encode()).hexdigest()[:16]
    out = cache_dir() / "subs" / f"{key}-{path.name}"
    if out.exists():
        os.utime(out)               # recently used: kept by the cache trim
        return out
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = out.with_name(out.name + ".tmp")
    tmp.write_text(retime_text(read_text(path), scale, offset), encoding="utf-8")
    tmp.replace(out)
    return out


def cue_times(media, sub):
    """The cues of a subtitle track: a sidecar file as it is, an embedded text
    track extracted, picture subtitles as the text read from them."""
    if sub.file is not None:
        path = sub.file
    elif sub.via_ocr:
        path = ocrsubs.cached(media, sub) or ocrsubs.text_subtitles(media, sub)
    elif sub.is_bitmap:
        raise SyncError("picture subtitles can't be synced automatically")
    else:
        path = extract_text_subtitles(media, sub)
    cues = parse_cues(read_text(path))
    if len(cues) < MIN_CUES:
        raise SyncError("too few subtitles to compare with the speech")
    return cues


# ---- The speech ----------------------------------------------------------------

def windows(duration):
    """[(start_s, length_s)]: three stretches spread over the file, fewer for
    a short one, the whole of a very short one."""
    if duration <= 0:
        return [(0.0, WINDOW_S)]
    if duration <= WINDOW_S:
        return [(0.0, duration)]
    count = min(len(WINDOW_AT), int(duration // WINDOW_S))
    if count < len(WINDOW_AT):
        # Side by side from the start: no overlap, so each stretch is new evidence.
        return [(i * WINDOW_S, WINDOW_S) for i in range(count)]
    return [(round(max(0.0, min(duration - WINDOW_S, at * duration - WINDOW_S / 2)), 3), WINDOW_S)
            for at in WINDOW_AT]


def _decode(path, track, start, length, out, voice_band=False):
    """ffmpeg: one stretch of the audio track as 16 kHz mono PCM (float32, or
    16-bit through a voice band-pass for the loudness measure)."""
    # The centre channel carries the dialogue in surround sound; music and
    # effects mostly go left and right.
    pans = ["pan=mono|c0=FC", "pan=mono|c0=0.5*c0+0.5*c1"] if (track.channels or 0) >= 5 else [None]
    err = ""
    for pan in pans:
        graph = ",".join([*([pan] if pan else []), f"aresample={AUDIO_RATE}"]
                         + (["highpass=f=300", "lowpass=f=3000"] if voice_band else []))
        cmd = ["nice", "-n", "10", "ffmpeg", "-v", "error", "-y", "-ss", f"{start:.3f}", "-t", f"{length:.3f}",
               "-i", str(path), "-map", f"0:{track.index}", "-vn", "-sn", "-af", graph]
        cmd += ["-ac", "1"] if pan is None else []
        cmd += ["-f", "s16le" if voice_band else "f32le", str(out)]
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
        if r.returncode == 0 and out.exists() and out.stat().st_size > 0:
            return
        err = r.stderr.strip()[-200:]
    raise SyncError("could not decode the audio: " + err)


def speech_from_helper(helper, pcm_paths):
    """{path: [confidence 0-1 per window]} with the window and hop, from the
    helper's SoundAnalysis mode; all files at once (it runs them in parallel)."""
    r = subprocess.run([str(helper), "--speech"] + [str(p) for p in pcm_paths],
                       capture_output=True, text=True, timeout=600)
    if r.returncode != 0:
        raise SyncError("the speech helper failed: " + r.stderr.strip()[-200:])
    out = {}
    for line in r.stdout.splitlines():
        try:
            item = json.loads(line)
        except ValueError:
            continue
        if item.get("error"):
            raise SyncError(item["error"])
        out[item["file"]] = ([v / 1000 for v in item["speech"]], float(item["window"]), float(item["hop"]))
    missing = [str(p) for p in pcm_paths if str(p) not in out]
    if missing:
        raise SyncError("the speech helper gave no result")
    return out


def bin_scores(confidences, window, hop, length):
    """The classifier's per-window confidences as one value per BIN_S, each
    window's value placed at its centre and interpolated between."""
    n = int(round(length / BIN_S))
    if not confidences:
        return [0.0] * n
    last = len(confidences) - 1
    out = []
    for i in range(n):
        j = (i * BIN_S - window / 2) / hop
        if j <= 0:
            out.append(confidences[0])
        elif j >= last:
            out.append(confidences[last])
        else:
            k = int(j)
            f = j - k
            out.append(confidences[k] + f * (confidences[k + 1] - confidences[k]))
    return out


def energy_scores(pcm_s16, length):
    """Loudness in the voice band as a speech score per BIN_S: decibels above
    the stretch's quiet floor, 0 at the floor + 6 dB, 1 at 20 dB over that."""
    samples = array("h")
    samples.frombytes(pcm_s16[:len(pcm_s16) - len(pcm_s16) % 2])
    frame = int(AUDIO_RATE * BIN_S)
    n = int(round(length / BIN_S))
    db = []
    for i in range(n):
        seg = samples[i * frame:(i + 1) * frame]
        db.append(10 * math.log10(math.sumprod(seg, seg) / frame + 1) if len(seg) == frame else 0.0)
    if not db:
        return []
    floor = sorted(db)[len(db) // 5]
    return [max(0.0, min(1.0, (v - floor - 6) / 20)) for v in db]


# ---- The match -----------------------------------------------------------------

def lags(max_lag=MAX_OFFSET_S, step=BIN_S):
    """Evenly spaced lags from -max_lag to max_lag, max_lag rounded up to a
    whole number of steps (so every lag is a whole number of BIN_S)."""
    count = math.ceil(max_lag / step - 1e-9)
    return [round((i - count) * step, 3) for i in range(2 * count + 1)]


def correlate(scores, t0, cues, lag_list):
    """For each lag (evenly spaced, a whole number of BIN_S apart): the mean
    speech score (above the stretch's own mean) inside the cues moved by
    that lag; 0 where too little of the cues falls inside the stretch to say.
    With prefix sums a cue adds the difference of two prefix values, and
    over all the lags those values are a strided slice of the prefix sums:
    the sums over the cues run slice by slice instead of lag by lag."""
    n, m = len(scores), len(lag_list)
    if n == 0 or m == 0:
        return [0.0] * m
    mean = sum(scores) / n
    prefix = [0.0]
    for v in scores:
        prefix.append(prefix[-1] + (v - mean))
    reach = max(abs(lag_list[0]), abs(lag_list[-1])) + 1
    near = [(a, b) for a, b in cues if b > t0 - reach and a < t0 + n * BIN_S + reach]
    if not near:
        return [0.0] * m
    first = int(round(lag_list[0] / BIN_S))
    stride = int(round((lag_list[1] - lag_list[0]) / BIN_S)) if m > 1 else 1
    width = (m - 1) * stride + 1
    starts = [int(round((a - t0) / BIN_S)) + first for a, _ in near]
    ends = [int(round((b - t0) / BIN_S)) + first for _, b in near]
    lo = min(starts)
    # A cue edge outside the stretch counts as the stretch's own edge: there
    # the bin count and the prefix sum stop changing.
    edge = [0 if x < 0 else n if x > n else x for x in range(lo, max(ends) + width)]
    level = [prefix[i] for i in edge]

    def summed(values, at):
        acc = [0] * m
        for k in range(0, len(at), 64):
            rows = [values[x - lo:x - lo + width:stride] for x in at[k:k + 64]]
            acc = list(map(operator.add, acc, map(sum, zip(*rows))))
        return acc

    total = map(operator.sub, summed(level, ends), summed(level, starts))
    covered = map(operator.sub, summed(edge, ends), summed(edge, starts))
    least = n * 0.02
    return [t / c if c > least else 0.0 for t, c in zip(total, covered)]


def peak(curve, lag_list):
    """(lag, margin, z) of the curve's highest point: the lag refined between
    steps with a parabola through the neighbours, how far the peak stands over
    the best other peak at least 1.5 s away (0-1), and over the mean in
    standard deviations."""
    n = len(curve)
    best = max(range(n), key=curve.__getitem__)
    top = curve[best]
    mean = sum(curve) / n
    sd = math.sqrt(sum((v - mean) ** 2 for v in curve) / n)
    if sd == 0 or top <= mean:
        return lag_list[best], 0.0, 0.0
    step = lag_list[1] - lag_list[0] if n > 1 else BIN_S
    apart = int(round(1.5 / step))
    others = [curve[i] for i in range(n) if abs(i - best) > apart]
    runner = max(others) if others else mean
    margin = max(0.0, (top - runner) / (top - mean))
    lag = lag_list[best]
    if 0 < best < n - 1:
        a, b, c = curve[best - 1], top, curve[best + 1]
        denominator = a - 2 * b + c
        if denominator < 0:
            lag += step * 0.5 * (a - c) / denominator
    return lag, margin, (top - mean) / sd


def _judge(stretches, cues, lag_list):
    """Each stretch's peak ({"start", "offset", "confidence", "z"}), the peak
    of all stretches together (lag, margin, z), and the height of that peak
    per stretch: how much speech the best shift puts inside the subtitles,
    which is what fits with different scales are compared by."""
    curves = [correlate(scores, t0, cues, lag_list) for t0, scores in stretches]
    found = []
    for (t0, _), curve in zip(stretches, curves):
        lag, margin, z = peak(curve, lag_list)
        found.append({"start": round(t0, 3), "offset": round(lag + LINGER_S, 3),
                      "confidence": round(margin, 3), "z": round(z, 2)})
    combined = [sum(c[i] for c in curves) for i in range(len(lag_list))]
    return found, peak(combined, lag_list), max(combined) / len(curves)


def _sure(found):
    return [w for w in found if w["confidence"] >= MIN_STRETCH_MARGIN]


def _spread(found):
    return max(w["offset"] for w in found) - min(w["offset"] for w in found)


def _line(points):
    """(slope, intercept) of the weighted least-squares line through
    [(x, y, weight)]."""
    total = sum(w for _, _, w in points)
    mx = sum(x * w for x, _, w in points) / total
    my = sum(y * w for _, y, w in points) / total
    sxx = sum(w * (x - mx) ** 2 for x, _, w in points)
    if sxx == 0:
        return 0.0, my
    slope = sum(w * (x - mx) * (y - my) for x, y, w in points) / sxx
    return slope, my - slope * mx


def _slope(stretches, found, least=MIN_STRETCH_MARGIN):
    """How the offset grows along the cues' own timeline, from the stretches
    at least `least` sure, weighted by how sure: the cues in the middle of a
    stretch sit at its centre minus the offset measured there."""
    points = [(t0 + len(scores) * BIN_S / 2 - w["offset"], w["offset"], w["confidence"] + 1e-3)
              for (t0, scores), w in zip(stretches, found) if w["confidence"] >= least]
    return _line(points)[0] if len(points) >= 2 else None


def _scaled(cues, scale):
    return [(a * scale, b * scale) for a, b in cues]


def _refine(stretches, cues, scale, end, rounds=3):
    """A scale made exact: the stretches judged with the cues stretched by it,
    a line through their offsets, its slope folded into the scale, until
    the line is flat. None when fewer than two stretches are sure, or the
    scale leaves the plausible range."""
    lag_list = lags(MAX_OFFSET_S + 0.005 * end, DRIFT_STEP_S)
    for _ in range(rounds):
        found, _, _ = _judge(stretches, _scaled(cues, scale), lag_list)
        slope = _slope(stretches, found)
        if slope is None:
            return None
        scale *= 1 + slope
        if abs(scale - 1) > MAX_STRETCH:
            return None
        if abs(slope) < MIN_STRETCH:
            break
    return scale


def _fit(stretches, cues, scale):
    """The cues stretched by `scale` and slid to the best offset, judged:
    {"scale", "offset", "confidence", "windows", "top"}."""
    found, (lag, margin, _), top = _judge(stretches, _scaled(cues, scale), lags())
    return {"scale": scale, "offset": lag + LINGER_S, "confidence": margin, "windows": found, "top": top}


def _holds(fit, stretches, free):
    """A fit to apply: every stretch is sure and they agree once the cues are
    stretched, or a lone stretch is certain of a frame-rate ratio. Trying
    several scales gives a coincidence more chances than one delay has, so
    the bar is all the stretches, not two; and a scale of its own needs
    three, since a line runs through any two."""
    if len(stretches) == 1:
        return not free and fit["confidence"] >= 0.5
    sure = _sure(fit["windows"])
    return (len(sure) == len(stretches) and len(sure) >= (3 if free else 2)
            and _spread(sure) <= DRIFT_S and fit["confidence"] >= MIN_STRETCH_MARGIN)


def ratio_near(scale):
    """The frame-rate ratio `scale` is within measuring precision of, or None."""
    return next((r for r, _, _ in RATIOS if abs(scale / r - 1) <= SNAP), None)


def find_stretch(stretches, cues, plain_top):
    """The best fit with the cues stretched, or None: each frame-rate ratio,
    and the scale a line through the unstretched stretches' offsets gives,
    each refined; a refined scale within SNAP of a ratio is taken as that
    ratio unless the measured one fits clearly better. The fit must hold
    (_holds) and put clearly more speech inside the cues than no stretch."""
    end = max(t0 + len(scores) * BIN_S for t0, scores in stretches)
    starts = sorted({r for r, _, _ in RATIOS})
    if len(stretches) >= 3:
        # A drift no ratio explains: the unstretched offsets, over a slide
        # wide enough for the largest plausible drift at the last stretch.
        # Unstretched cues smear over a stretch (4 s at 1.3 %), so the peaks
        # are right but seldom sure: every stretch counts, by how sure it is.
        # This only proposes a scale; the fit it refines to must hold.
        found, _, _ = _judge(stretches, cues, lags(MAX_OFFSET_S + MAX_STRETCH * end, DRIFT_STEP_S))
        slope = _slope(stretches, found, least=0.0)
        if slope is not None and MIN_STRETCH < abs(slope) <= MAX_STRETCH:
            starts.append(1 + slope)
    seen, fits = set(), []
    for start in starts:
        scale = _refine(stretches, cues, start, end) if len(stretches) >= 2 else start
        if scale is None or abs(scale - 1) < MIN_STRETCH or round(scale, 6) in seen:
            continue
        seen.add(round(scale, 6))
        measured = _fit(stretches, cues, scale)
        ratio = ratio_near(scale)
        if ratio is not None:
            snapped = _fit(stretches, cues, ratio)
            if _holds(snapped, stretches, free=False) and snapped["top"] >= measured["top"] * 0.98:
                fits.append(snapped)
                continue
        if _holds(measured, stretches, free=True):
            fits.append(measured)
    fits = [f for f in fits if f["top"] > plain_top * 1.05]
    return max(fits, key=lambda f: f["top"]) if fits else None


def made_for(scale, fps=None):
    """The frame rate subtitles stretched by `scale` were timed for ("25"),
    or None: from the video's own rate when it is known, else from the
    frame-rate ratio the scale is."""
    if fps:
        return next((name for name, rate in FRAME_RATES if abs(fps * scale / rate - 1) <= SNAP), None)
    return next((made for r, made, _ in RATIOS if abs(scale / r - 1) <= SNAP), None)


def stretch_note(scale, fps=None):
    """"The subtitles run 4.3 % fast (made for 25 fps); stretched to fit." """
    made = made_for(scale, fps)
    fast = scale > 1
    percent = (max(scale, 1 / scale) - 1) * 100
    return (f"The subtitles run {percent:.{1 if percent >= 0.1 else 2}f} % {'fast' if fast else 'slow'}"
            + (f" (made for {made} fps)" if made else "")
            + f"; {'stretched' if fast else 'shortened'} to fit.")


def _clamp(offset):
    return round(max(-MAX_OFFSET_S, min(MAX_OFFSET_S, offset)), 2)


def find_offset(stretches, cues, fps=None):
    """How the cues fit the speech, from [(t0, scores)] per stretch:
    {"offset", "scale", "confidence", "note", "windows"}. A cue at t belongs
    at t * scale + offset (+ = later); scale is 1 when one delay fits the
    whole film. Both are None when nothing fits, and the note says why: a
    drift no stretch fits, or nothing stands out. `fps` (the video's frame
    rate) names the rate stretched subtitles were made for."""
    found, (lag, margin, _), top = _judge(stretches, cues, lags())
    sure = _sure(found)
    result = {"offset": None, "scale": None, "confidence": round(margin, 3), "note": None, "windows": found}
    drift = len(sure) >= 2 and _spread(sure) > DRIFT_S
    if not drift and (margin >= MIN_MARGIN or len(sure) >= 2):
        result.update(offset=_clamp(lag + LINGER_S), scale=1.0)
        return result
    fit = find_stretch(stretches, cues, top)
    if fit is not None:
        result.update(offset=_clamp(fit["offset"]), scale=round(fit["scale"], 7),
                      confidence=round(fit["confidence"], 3), windows=fit["windows"],
                      note=stretch_note(fit["scale"], fps))
    else:
        result["note"] = DRIFT_NOTE if drift else UNSURE_NOTE
    return result


# ---- A whole file -----------------------------------------------------------------

def helper_path():
    """The SoundAnalysis helper, or None (then loudness stands in)."""
    try:
        return ocrsubs.helper_path()
    except ocrsubs.OCRError:
        return None


def frame_rate(media):
    """The video's frame rate, or None when the file doesn't say."""
    for key in ("avg_frame_rate", "r_frame_rate"):
        num, _, den = str((media.video or {}).get(key) or "").partition("/")
        try:
            rate = float(num) / float(den or 1)
        except (ValueError, ZeroDivisionError):
            continue
        if rate > 0:
            return rate
    return None


def analyse(media, sub, audio, helper=None):
    """Measure one file: {"offset", "scale", "confidence", "note", "method",
    "windows"} (find_offset).
    `helper`: the SoundAnalysis helper, None to find it, False for loudness
    alone. Raises SyncError when the track or the audio can't be read."""
    cues = cue_times(media, sub)
    helper = helper_path() if helper is None else (helper or None)
    stretches = []
    with tempfile.TemporaryDirectory(prefix="luftbro-subsync-") as tmp:
        tmp = Path(tmp)
        plan = windows(media.duration)
        pcm = [tmp / f"{i}.pcm" for i in range(len(plan))]
        for (start, length), out in zip(plan, pcm):
            _decode(media.path, audio, start, length, out, voice_band=helper is None)
        if helper is not None:
            heard = speech_from_helper(helper, pcm)
            for (start, length), out in zip(plan, pcm):
                confidences, window, hop = heard[str(out)]
                stretches.append((start, bin_scores(confidences, window, hop, length)))
        else:
            for (start, length), out in zip(plan, pcm):
                stretches.append((start, energy_scores(out.read_bytes(), length)))
    result = find_offset(stretches, cues, frame_rate(media))
    result["method"] = "classifier" if helper is not None else "energy"
    if helper is None and result["offset"] is not None:
        result["note"] = " ".join(filter(None, (result["note"], ENERGY_NOTE)))
    return result


class SyncStore:
    """Results per file, subtitle track and audio track, measured one at a
    time in the background, at low priority."""

    VERSION = 2                 # part of the key: a better detector measures again

    def __init__(self, root=None):
        self._root = root
        self._lock = threading.Lock()
        self._running = {}      # key -> Thread
        self._failed = {}       # key -> message (kept for the run, not on disk)
        self._one_at_a_time = threading.Semaphore(1)

    @property
    def root(self):
        return self._root or cache_dir() / "subsync"

    @classmethod
    def key(cls, media, sub, audio):
        if sub.file is not None:
            try:
                st = sub.file.stat()
                track = f"{sub.file}|{st.st_size}|{st.st_mtime}"
            except OSError:
                track = str(sub.file)
        else:
            track = f"stream {sub.index}"
        return hashlib.sha1(f"{cls.VERSION}|{media.fingerprint}|{track}|{audio.index}".encode()).hexdigest()[:16]

    def status(self, media, sub, audio):
        """{"status": "working" | "done" | "failed", "offset", "scale",
        "confidence", "note"}; starts the measurement the first time."""
        key = self.key(media, sub, audio)
        result = self.root / f"{key}.json"
        try:
            return {"status": "done", **json.loads(result.read_text())}
        except (OSError, ValueError):
            pass
        with self._lock:
            if key in self._failed:
                return {"status": "failed", "offset": None, "scale": None, "confidence": None,
                        "note": self._failed[key]}
            t = self._running.get(key)
            if t is None or not t.is_alive():
                t = threading.Thread(target=self._measure, args=(media, sub, audio, key, result), daemon=True)
                self._running[key] = t
                t.start()
        return {"status": "working", "offset": None, "scale": None, "confidence": None, "note": None}

    def _measure(self, media, sub, audio, key, result):
        with self._one_at_a_time:
            try:
                found = analyse(media, sub, audio)
            except (SyncError, ocrsubs.OCRError, OSError, subprocess.SubprocessError, ValueError) as e:
                with self._lock:
                    self._failed[key] = str(e) or type(e).__name__
                return
            try:
                result.parent.mkdir(parents=True, exist_ok=True)
                tmp = result.with_suffix(".tmp")
                tmp.write_text(json.dumps({"offset": found["offset"], "scale": found["scale"],
                                           "confidence": found["confidence"],
                                           "note": found["note"], "method": found["method"],
                                           "windows": found["windows"]}))
                tmp.replace(result)
            except OSError:
                pass
