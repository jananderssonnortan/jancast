"""subsync.py: the cue parsers and the cue rewriting, the match on synthetic
speech timelines (known shifts, stretches, noise, another cut, silence), the
loudness measure, and the store."""

import json
import math
import os
import random
import time
import unittest
from array import array
from pathlib import Path
from unittest import mock

from helpers import TempDirMixin, audio_stream, make_media, sub_stream, video_stream
from luftbro import subsync
from luftbro.media import Track


# ---- Synthetic timelines ----------------------------------------------------------

def speech_segments(seed, length=300.0, count=90):
    """[(start, end)] of made-up lines: 0.8-4 s long, 0.2-4 s apart, with a
    few longer pauses (scene changes)."""
    rng = random.Random(seed)
    out = []
    t = rng.uniform(0, 3)
    while len(out) < count and t < length - 5:
        end = t + rng.uniform(0.8, 4.0)
        out.append((t, end))
        t = end + (rng.uniform(4, 12) if rng.random() < 0.1 else rng.uniform(0.2, 4.0))
    return out


def scores_for(segments, length=300.0, noise=0.0, seed=1):
    """A speech score per bin: 1 inside the lines, 0 outside, blurred over
    half a second as the classifier's windows do, plus noise."""
    rng = random.Random(seed)
    n = int(round(length / subsync.BIN_S))
    raw = [0.0] * n
    for a, b in segments:
        for i in range(max(0, int(a / subsync.BIN_S)), min(n, int(b / subsync.BIN_S))):
            raw[i] = 1.0
    half = int(0.25 / subsync.BIN_S)
    out = []
    for i in range(n):
        lo, hi = max(0, i - half), min(n, i + half + 1)
        v = sum(raw[lo:hi]) / (hi - lo)
        out.append(max(0.0, min(1.0, v + rng.gauss(0, noise))))
    return out


def cues_for(segments, shift=0.0, jitter=0.0, seed=2, scale=1.0, offset=0.0):
    """Subtitles for the lines as a subtitler times them: up with the voice,
    staying on twice LINGER_S after it (reading time), with some jitter;
    `shift` moves them (a file made for another release), `scale` stretches
    them (another frame rate) around 0."""
    rng = random.Random(seed)
    out = []
    for a, b in segments:
        start = (a + rng.uniform(-jitter, jitter) + offset) * scale + shift
        end = (b + 2 * subsync.LINGER_S + rng.uniform(-jitter, jitter) + offset) * scale + shift
        out.append((start, end))
    return out


class MatchTest(unittest.TestCase):
    def stretches(self, shift=0.0, noise=0.0, jitter=0.0, scale=1.0, starts=(300.0, 1500.0, 2600.0),
                  shifts=None):
        """Three stretches of a file, each with its own lines; the cues of all.
        `shifts`: one shift per stretch instead (subtitles for another cut)."""
        stretches, cues = [], []
        for k, t0 in enumerate(starts):
            segments = speech_segments(seed=10 + k)
            stretches.append((t0, scores_for(segments, noise=noise, seed=k)))
            cues += cues_for(segments, shift=shifts[k] if shifts else shift, jitter=jitter, seed=20 + k,
                             scale=scale, offset=t0)
        return stretches, sorted(cues)

    def drifted(self, scale, offset, **kw):
        """Stretches whose cues fit the speech once a cue at t is moved to
        t * scale + offset."""
        return self.stretches(scale=1 / scale, shift=-offset / scale, **kw)

    def assertFits(self, r, scale, offset, end=3000.0, within=0.2):
        """The correction found puts every cue of the film within `within`
        seconds of where the true one does, from the start to `end`."""
        self.assertIsNotNone(r["offset"], r)
        for t in (0.0, end / 4, end / 2, 3 * end / 4, end):
            with self.subTest(t=t):
                self.assertLess(abs(t * r["scale"] + r["offset"] - (t * scale + offset)), within)

    def test_in_sync_is_zero(self):
        r = subsync.find_offset(*self.stretches())
        self.assertIsNotNone(r["offset"])
        self.assertAlmostEqual(r["offset"], 0.0, delta=0.1)
        self.assertIsNone(r["note"])
        self.assertGreaterEqual(r["confidence"], subsync.MIN_MARGIN)

    def test_known_shifts_are_recovered(self):
        for shift in (-7.3, 2.5, 31.0, -45.0, 0.4, 59.0):
            with self.subTest(shift=shift):
                r = subsync.find_offset(*self.stretches(shift=shift, noise=0.15, jitter=0.15))
                self.assertIsNotNone(r["offset"], r)
                # Subtitles that are `shift` late need to come `shift` earlier.
                self.assertAlmostEqual(r["offset"], -shift, delta=0.2)
                self.assertEqual(r["scale"], 1.0)
                self.assertIsNone(r["note"])
                self.assertEqual(len(r["windows"]), 3)

    def test_heavy_noise_still_resolves_or_says_unsure(self):
        r = subsync.find_offset(*self.stretches(shift=4.0, noise=0.6, jitter=0.3))
        if r["offset"] is not None:
            self.assertAlmostEqual(r["offset"], -4.0, delta=0.25)
        else:
            self.assertEqual(r["note"], subsync.UNSURE_NOTE)

    def test_no_speech_is_unsure(self):
        stretches, cues = self.stretches()
        silent = [(t0, [0.02 * random.Random(i).random() for _ in s]) for i, (t0, s) in enumerate(stretches)]
        r = subsync.find_offset(silent, cues)
        self.assertIsNone(r["offset"])
        self.assertEqual(r["note"], subsync.UNSURE_NOTE)

    def test_unrelated_subtitles_are_unsure(self):
        # Subtitles for some other episode: lines where there are none.
        stretches, _ = self.stretches()
        other = []
        for seed, t0 in ((99, 300.0), (98, 1500.0), (97, 2600.0)):
            other += cues_for(speech_segments(seed=seed), offset=t0)
        r = subsync.find_offset(stretches, sorted(other))
        self.assertIsNone(r["offset"])
        self.assertIsNone(r["scale"])
        self.assertIn(r["note"], (subsync.UNSURE_NOTE, subsync.DRIFT_NOTE))

    def test_frame_rate_drifts_are_stretched_to_fit(self):
        # (made for, video fps, offset): 25 against 23.976 runs 4 % fast, 13 s
        # across one stretch; 24 against 23.976 a tenth of a percent, 2.3 s
        # between the first and the last stretch.
        for made, video, offset in ((25, 23.976, 3.0), (24, 23.976, 0.0), (25, 24, -12.5),
                                    (23.976, 25, 1.5), (23.976, 24, 40.0)):
            with self.subTest(made=made, video=video):
                ratio = (24000 / 1001 if made == 23.976 else made) / (24000 / 1001 if video == 23.976 else video)
                r = subsync.find_offset(*self.drifted(ratio, offset, noise=0.15, jitter=0.15))
                self.assertAlmostEqual(r["scale"], ratio, delta=1e-6)
                self.assertAlmostEqual(r["offset"], offset, delta=0.1)
                self.assertFits(r, ratio, offset)
                self.assertGreaterEqual(r["confidence"], subsync.MIN_STRETCH_MARGIN)
                self.assertIn(f"(made for {made} fps)", r["note"])
                self.assertRegex(r["note"], r"fast .*; stretched to fit\.$" if made > video
                                 else r"slow .*; shortened to fit\.$")
                for w in r["windows"]:
                    self.assertAlmostEqual(w["offset"], offset, delta=0.3)

    def test_a_drift_no_frame_rate_explains_keeps_its_measured_scale(self):
        for scale, offset in ((1.013, -2.0), (1 / 1.013, 6.0), (1.0004, 0.5)):
            with self.subTest(scale=scale):
                r = subsync.find_offset(*self.drifted(scale, offset, noise=0.15, jitter=0.15))
                self.assertAlmostEqual(r["scale"], scale, delta=5e-5)
                self.assertFits(r, scale, offset)
                self.assertNotIn("made for", r["note"])
        self.assertEqual(r["note"], "The subtitles run 0.04 % fast; stretched to fit.")

    def test_a_long_film_is_stretched_to_its_end(self):
        # Two hours: the last stretch sits 4.4 minutes off without the stretch.
        starts = tuple(subsync.windows(7200)[i][0] for i in range(3))
        r = subsync.find_offset(*self.drifted(25 / (24000 / 1001), -4.0, starts=starts, noise=0.15))
        self.assertAlmostEqual(r["scale"], 25 / (24000 / 1001), delta=1e-6)
        self.assertFits(r, 25 / (24000 / 1001), -4.0, end=7200)

    def test_a_lone_stretch_takes_a_frame_rate_ratio(self):
        # A five-minute file: 25/23.976 and 25/24 differ by 0.3 s over all of
        # it, too little to tell apart, and either fits.
        segments = speech_segments(seed=5)
        stretches = [(0.0, scores_for(segments))]
        ratio = 25 / (24000 / 1001)
        r = subsync.find_offset(stretches, cues_for(segments, scale=1 / ratio, shift=-1.0 / ratio))
        self.assertIn(r["scale"], (round(ratio, 7), round(25 / 24, 7)))
        self.assertFits(r, ratio, 1.0, end=300.0)
        # A free scale needs three stretches: a line runs through any two.
        r = subsync.find_offset(stretches, cues_for(segments, scale=1 / 1.013))
        self.assertIsNone(r["offset"])

    def test_drift_in_heavy_noise_is_fitted_or_unsure(self):
        ratio = 25 / (24000 / 1001)
        for noise in (0.5, 0.7):
            with self.subTest(noise=noise):
                r = subsync.find_offset(*self.drifted(ratio, 2.0, noise=noise, jitter=0.3))
                if r["offset"] is not None:
                    self.assertFits(r, ratio, 2.0, within=0.3)
                else:
                    self.assertIn(r["note"], (subsync.UNSURE_NOTE, subsync.DRIFT_NOTE))

    def test_subtitles_for_another_cut_are_reported_not_stretched(self):
        # A scene added before the second stretch: the offset jumps once, and
        # no line through the stretches holds.
        for shifts in ((0.0, 5.0, 5.0), (0.0, -8.0, 3.0)):
            with self.subTest(shifts=shifts):
                r = subsync.find_offset(*self.stretches(shifts=shifts))
                self.assertIsNone(r["offset"])
                self.assertIsNone(r["scale"])
                self.assertEqual(r["note"], subsync.DRIFT_NOTE)

    def test_a_stretch_needs_every_stretch_to_agree(self):
        # The middle stretch is music only: two stretches could be any line,
        # so no scale is taken from them.
        stretches, cues = self.drifted(25 / (24000 / 1001), 2.0, noise=0.15)
        t0, scores = stretches[1]
        stretches[1] = (t0, [0.3 * random.Random(i).random() for i in range(len(scores))])
        r = subsync.find_offset(stretches, cues)
        self.assertIsNone(r["offset"])
        self.assertIsNone(r["scale"])

    def test_an_implausible_stretch_is_refused(self):
        # 10 % is no frame-rate mix-up: whatever lines up there is a coincidence.
        r = subsync.find_offset(*self.drifted(1.10, 0.0))
        self.assertIsNone(r["offset"])
        self.assertIsNone(r["scale"])

    def test_one_stretch_is_enough_for_a_short_file(self):
        segments = speech_segments(seed=5)
        stretches = [(0.0, scores_for(segments))]
        r = subsync.find_offset(stretches, cues_for(segments, shift=-2.0))
        self.assertAlmostEqual(r["offset"], 2.0, delta=0.15)

    def test_correlate_matches_a_lag_by_lag_sum(self):
        segments = speech_segments(seed=3)
        scores = scores_for(segments, noise=0.2)
        cues = cues_for(segments, shift=4.0, offset=1000.0)
        for lag_list in (subsync.lags(), subsync.lags(80.3, subsync.DRIFT_STEP_S)):
            curve = subsync.correlate(scores, 1000.0, cues, lag_list)
            for i in range(0, len(lag_list), 97):
                total = covered = 0
                for a, b in cues:
                    lo = min(len(scores), max(0, int(round((a + lag_list[i] - 1000.0) / subsync.BIN_S))))
                    hi = min(len(scores), max(0, int(round((b + lag_list[i] - 1000.0) / subsync.BIN_S))))
                    mean = sum(scores) / len(scores)
                    total += sum(v - mean for v in scores[lo:hi])
                    covered += hi - lo
                want = total / covered if covered > len(scores) * 0.02 else 0.0
                self.assertAlmostEqual(curve[i], want, places=9)

    def test_lags_are_whole_steps(self):
        lag_list = subsync.lags(80.33, 0.1)
        self.assertEqual((lag_list[0], lag_list[-1], len(lag_list)), (-80.4, 80.4, 1609))
        self.assertEqual(subsync.lags()[:2], [-60.0, -59.95])

    def test_peak_is_refined_between_steps(self):
        lag_list = subsync.lags()
        curve = [math.exp(-((lag - 1.27) / 0.4) ** 2) for lag in lag_list]
        lag, margin, z = subsync.peak(curve, lag_list)
        self.assertAlmostEqual(lag, 1.27, delta=0.01)
        self.assertGreater(margin, 0.9)
        self.assertGreater(z, 5)

    def test_flat_curve_has_no_confidence(self):
        lag_list = subsync.lags()
        self.assertEqual(subsync.peak([0.0] * len(lag_list), lag_list)[1:], (0.0, 0.0))


class RatioTest(unittest.TestCase):
    NTSC_FILM = 24000 / 1001

    def test_the_frame_rate_ratios(self):
        self.assertEqual(sorted({round(r, 6) for r, _, _ in subsync.RATIOS}),
                         [0.959041, 0.96, 0.999001, 1.001, 1.041667, 1.042708])
        for r, made, video in subsync.RATIOS:
            self.assertLessEqual(abs(r - 1), subsync.MAX_STRETCH)

    def test_a_scale_near_a_ratio_snaps_to_it(self):
        self.assertEqual(subsync.ratio_near(1.0427), 25 / self.NTSC_FILM)
        self.assertEqual(subsync.ratio_near(1.0418), 25 / 24)
        self.assertEqual(subsync.ratio_near(0.9591), self.NTSC_FILM / 25)
        self.assertEqual(subsync.ratio_near(1.00095), 24 / self.NTSC_FILM)
        for scale in (1.013, 1.0, 1.0422, 0.97):
            self.assertIsNone(subsync.ratio_near(scale), scale)

    def test_made_for_names_the_frame_rate(self):
        self.assertEqual(subsync.made_for(25 / self.NTSC_FILM), "25")
        self.assertEqual(subsync.made_for(self.NTSC_FILM / 25), "23.976")
        # 1.001 is 24 on 23.976 and 30 on 29.97: the video's own rate decides.
        self.assertEqual(subsync.made_for(1.001001), "24")
        self.assertEqual(subsync.made_for(1.001001, fps=30000 / 1001), "30")
        self.assertEqual(subsync.made_for(25 / 24, fps=24.0), "25")
        self.assertIsNone(subsync.made_for(1.013))
        self.assertIsNone(subsync.made_for(1.013, fps=self.NTSC_FILM))

    def test_notes(self):
        self.assertEqual(subsync.stretch_note(25 / self.NTSC_FILM, self.NTSC_FILM),
                         "The subtitles run 4.3 % fast (made for 25 fps); stretched to fit.")
        self.assertEqual(subsync.stretch_note(self.NTSC_FILM / 25),
                         "The subtitles run 4.3 % slow (made for 23.976 fps); shortened to fit.")
        self.assertEqual(subsync.stretch_note(1.013), "The subtitles run 1.3 % fast; stretched to fit.")

    def test_frame_rate_of_the_video(self):
        self.assertAlmostEqual(subsync.frame_rate(mock.Mock(video={"avg_frame_rate": "24000/1001"})),
                               self.NTSC_FILM)
        self.assertEqual(subsync.frame_rate(mock.Mock(video={"avg_frame_rate": "0/0", "r_frame_rate": "25/1"})),
                         25.0)
        self.assertIsNone(subsync.frame_rate(mock.Mock(video={})))


# ---- Cues -----------------------------------------------------------------------

class ParseTest(TempDirMixin, unittest.TestCase):
    def test_srt(self):
        text = "1\n00:00:01,500 --> 00:00:03,000\nHello\n\n2\n00:01:00,000 --> 00:01:02,250\nThere\n"
        self.assertEqual(subsync.parse_cues(text), [(1.5, 3.0), (60.0, 62.25)])

    def test_webvtt_without_hours_and_with_settings(self):
        text = "WEBVTT\n\n00:20.437 --> 00:22.898 line:10%\nHi\n\n01:00:00.000 --> 01:00:01.000\nBye\n"
        self.assertEqual(subsync.parse_cues(text), [(20.437, 22.898), (3600.0, 3601.0)])

    def test_ass(self):
        text = ("[Script Info]\nTitle: x\n\n[Events]\nFormat: Layer, Start, End, Style, Text\n"
                "Dialogue: 0,0:00:01.50,0:00:03.00,Default,,0,0,0,,Hello\n"
                "Dialogue: 0,0:01:00.00,0:01:02.25,Default,,0,0,0,,There\n"
                "Comment: 0,0:02:00.00,0:02:02.00,Default,,0,0,0,,not shown\n")
        self.assertEqual(subsync.parse_cues(text), [(1.5, 3.0), (60.0, 62.25)])

    def test_overlapping_cues_merge_and_bad_ones_drop(self):
        text = ("00:00:05,000 --> 00:00:04,000\nbackwards\n\n"
                "00:00:01,000 --> 00:00:03,000\nA\n\n00:00:02,000 --> 00:00:04,000\nB\n\n"
                "00:00:04,000 --> 00:00:05,000\nC\n\n00:00:09,000 --> 00:00:10,000\nD\n")
        self.assertEqual(subsync.parse_cues(text), [(1.0, 5.0), (9.0, 10.0)])

    def test_empty_and_garbage(self):
        self.assertEqual(subsync.parse_cues(""), [])
        self.assertEqual(subsync.parse_cues("not a subtitle file at all"), [])

    def test_encodings(self):
        d = self.make_tempdir()
        body = "1\n00:00:01,000 --> 00:00:02,000\nhéllo\n"
        for name, raw in (("bom.srt", body.encode("utf-8-sig")), ("utf16.srt", body.encode("utf-16")),
                          ("latin.srt", body.encode("latin-1"))):
            p = d / name
            p.write_bytes(raw)
            self.assertEqual(subsync.parse_cues(subsync.read_text(p)), [(1.0, 2.0)], name)

    def test_too_few_cues(self):
        f = self.make_tempdir() / "a.srt"
        f.write_text("1\n00:00:01,000 --> 00:00:02,000\nx\n")
        with self.assertRaises(subsync.SyncError):
            subsync.cue_times(None, Track("sub", 0, "subrip", file=f))

    def test_burned_in_subtitles_cannot_be_synced(self):
        with mock.patch.object(subsync.ocrsubs, "possible", return_value=False):
            with self.assertRaises(subsync.SyncError):
                subsync.cue_times(None, Track("sub", 3, "hdmv_pgs_subtitle"))


# ---- Rewriting the cue times ---------------------------------------------------------

class RetimeTest(TempDirMixin, unittest.TestCase):
    SRT = ("1\n00:00:01,500 --> 00:00:03,000\nHello, 00:00:09,000 is not a time\n\n"
           "2\n00:12:00,000 --> 00:12:02,250\nThere\n\n"
           "3\n00:49:58,707 --> 00:50:01,043\nLate\n")

    def test_srt_times_are_scaled_exactly(self):
        scale = 25 / (24000 / 1001)
        out = subsync.retime_text(self.SRT, scale, 0.25)
        want = [(a * scale + 0.25, b * scale + 0.25) for a, b in subsync.parse_cues(self.SRT)]
        for (a, b), (wa, wb) in zip(subsync.parse_cues(out), want):
            self.assertAlmostEqual(a, wa, delta=0.0005)
            self.assertAlmostEqual(b, wb, delta=0.0005)
        self.assertIn("00:00:01,814 --> 00:00:03,378\nHello, 00:00:09,000 is not a time\n", out)
        self.assertIn("00:12:31,000 --> 00:12:33,346\nThere", out)
        self.assertIn("00:52:07,027 --> 00:52:09,463\nLate", out)
        self.assertEqual(out.split("\n")[::4], self.SRT.split("\n")[::4])     # cue numbers, in order

    def test_webvtt_keeps_its_header_settings_and_gains_hours_past_one(self):
        text = "WEBVTT\nX-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:0\n\n00:20.437 --> 00:22.898 line:10%\nHi\n\n" \
               "59:00.000 --> 59:01.000\nBye\n"
        out = subsync.retime_text(text, 1.05, 0.0)
        self.assertEqual(out, "WEBVTT\nX-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:0\n\n"
                              "00:21.459 --> 00:24.043 line:10%\nHi\n\n01:01:57.000 --> 01:01:58.050\nBye\n")

    def test_ass_events_in_centiseconds(self):
        text = ("[Script Info]\nTitle: x\n\n[Events]\nFormat: Layer, Start, End, Style, Text\n"
                "Dialogue: 0,0:00:01.50,0:00:03.00,Default,,0,0,0,,Hello, 0:00:05.00 there\n"
                "Comment: 0,0:02:00.00,0:02:02.00,Default,,0,0,0,,not shown\n"
                "Dialogue: 0,1:10:00.00,1:10:01.00,Default,,0,0,0,,Late\n")
        out = subsync.retime_text(text, 2.0, -2.0)
        self.assertEqual(out, "[Script Info]\nTitle: x\n\n[Events]\nFormat: Layer, Start, End, Style, Text\n"
                              "Dialogue: 0,0:00:01.00,0:00:04.00,Default,,0,0,0,,Hello, 0:00:05.00 there\n"
                              "Comment: 0,0:03:58.00,0:04:02.00,Default,,0,0,0,,not shown\n"
                              "Dialogue: 0,2:19:58.00,2:20:00.00,Default,,0,0,0,,Late\n")

    def test_times_before_the_start_become_zero_and_the_order_stays(self):
        out = subsync.retime_text(self.SRT, 1.0, -2.0)
        self.assertIn("1\n00:00:00,000 --> 00:00:01,000\nHello", out)
        cues = subsync.parse_cues(out)
        self.assertEqual(cues, sorted(cues))
        self.assertEqual(subsync.retime_text(self.SRT, 1.0, 0.0), self.SRT)

    def test_retimed_file_is_a_cached_copy_in_the_same_format(self):
        d = self.make_tempdir()
        src = Path(d) / "Night.Train.S01E02.en.srt"
        src.write_bytes(self.SRT.replace("Hello", "Héllo").encode("latin-1"))
        out = subsync.retimed_file(src, 1.001, 1.5)
        self.assertTrue(out.name.endswith("-Night.Train.S01E02.en.srt"))
        self.assertIn("00:00:03,002 --> 00:00:04,503\nHéllo", out.read_text(encoding="utf-8"))
        self.assertEqual(subsync.retimed_file(src, 1.001, 1.5), out)
        self.assertNotEqual(subsync.retimed_file(src, 1.001, 2.0), out)
        self.assertEqual(src.read_bytes().decode("latin-1"), self.SRT.replace("Hello", "Héllo"))  # untouched
        fast = Path(d) / "text.fast.vtt"
        fast.write_text("WEBVTT\n\n00:01.000 --> 00:02.000\nx\n")
        self.assertTrue(subsync.retimed_file(fast, 1.001).name.endswith(".fast.vtt"))


# ---- Speech scores ---------------------------------------------------------------

class ScoresTest(unittest.TestCase):
    def test_windows(self):
        self.assertEqual(subsync.windows(0), [(0.0, subsync.WINDOW_S)])
        self.assertEqual(subsync.windows(200), [(0.0, 200)])
        self.assertEqual(subsync.windows(700), [(0.0, 300), (300.0, 300)])
        three = subsync.windows(3000)
        self.assertEqual(len(three), 3)
        self.assertEqual(three[0], (210.0, 300))
        self.assertEqual(three[1], (1350.0, 300))
        self.assertEqual(three[2], (2490.0, 300))
        # Never past the end.
        for start, length in subsync.windows(910):
            self.assertLessEqual(start + length, 910)

    def test_bin_scores_place_windows_at_their_centre(self):
        # One-second windows every half second, speech in the 3rd and 4th.
        scores = subsync.bin_scores([0, 0, 1, 1, 0, 0], window=1.0, hop=0.5, length=4.0)
        self.assertEqual(len(scores), 80)
        self.assertEqual(scores[0], 0)
        self.assertAlmostEqual(scores[int(1.5 / subsync.BIN_S)], 1.0)   # window 2 centred at 1.5
        self.assertAlmostEqual(scores[int(1.25 / subsync.BIN_S)], 0.5)  # halfway in
        self.assertEqual(scores[-1], 0)
        self.assertEqual(subsync.bin_scores([], 1.0, 0.5, 1.0), [0.0] * 20)

    def test_energy_scores(self):
        rate = subsync.AUDIO_RATE
        quiet = [int(50 * math.sin(i / 7)) for i in range(rate * 2)]
        loud = [int(8000 * math.sin(i / 7)) for i in range(rate * 1)]
        pcm = array("h", quiet + loud + quiet).tobytes()
        scores = subsync.energy_scores(pcm, 5.0)
        self.assertEqual(len(scores), 100)
        self.assertEqual(scores[10], 0.0)
        self.assertEqual(scores[50], 1.0)
        self.assertEqual(scores[90], 0.0)

    def test_helper_output_is_parsed(self):
        lines = json.dumps({"file": "/a.pcm", "window": 0.5, "hop": 0.1, "speech": [0, 500, 1000]})
        done = mock.Mock(returncode=0, stdout=lines + "\n", stderr="")
        with mock.patch.object(subsync.subprocess, "run", return_value=done):
            self.assertEqual(subsync.speech_from_helper("/h", [Path("/a.pcm")]),
                             {"/a.pcm": ([0.0, 0.5, 1.0], 0.5, 0.1)})
        failed = mock.Mock(returncode=0, stdout=json.dumps({"file": "/a.pcm", "error": "no classifier"}), stderr="")
        with mock.patch.object(subsync.subprocess, "run", return_value=failed):
            with self.assertRaises(subsync.SyncError):
                subsync.speech_from_helper("/h", [Path("/a.pcm")])


# ---- Store -------------------------------------------------------------------------

def wait_done(store, m, sub, audio, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        s = store.status(m, sub, audio)
        if s["status"] != "working":
            return s
        time.sleep(0.02)
    raise AssertionError("still working")


class StoreTest(TempDirMixin, unittest.TestCase):
    def media(self):
        d = self.make_tempdir()
        return make_media(d, [video_stream(0), audio_stream(1), sub_stream(2)], duration=2700)

    def test_measures_once_and_keeps_the_result(self):
        m = self.media()
        store = subsync.SyncStore(root=self.make_tempdir())
        calls = []

        def analyse(media, sub, audio, helper=None):
            calls.append(sub.index)
            return {"offset": -7.3, "scale": 1.0, "confidence": 0.71, "note": None, "method": "classifier",
                    "windows": [{"start": 207.0, "offset": -7.3, "confidence": 0.7, "z": 8.1}]}

        with mock.patch.object(subsync, "analyse", analyse):
            self.assertEqual(store.status(m, m.subs[0], m.audio[0])["status"], "working")
            done = wait_done(store, m, m.subs[0], m.audio[0])
            self.assertEqual(done["status"], "done")
            self.assertEqual(done["offset"], -7.3)
            self.assertEqual(done["scale"], 1.0)
            self.assertEqual(done["method"], "classifier")
            self.assertEqual(store.status(m, m.subs[0], m.audio[0]), done)
        self.assertEqual(calls, [2])

    def test_failure_is_reported_and_not_retried_every_poll(self):
        m = self.media()
        store = subsync.SyncStore(root=self.make_tempdir())
        with mock.patch.object(subsync, "analyse", side_effect=subsync.SyncError("could not decode the audio")):
            done = wait_done(store, m, m.subs[0], m.audio[0])
        self.assertEqual(done["status"], "failed")
        self.assertEqual(done["note"], "could not decode the audio")
        self.assertEqual(store.status(m, m.subs[0], m.audio[0])["status"], "failed")

    def test_key_tells_tracks_and_sidecar_files_apart(self):
        m = self.media()
        d = self.make_tempdir()
        f = d / "movie.srt"
        f.write_text("x")
        sidecar = Track("sub", 0, "subrip", file=f)
        keys = {subsync.SyncStore.key(m, m.subs[0], m.audio[0]), subsync.SyncStore.key(m, sidecar, m.audio[0]),
                subsync.SyncStore.key(m, m.subs[0], Track("audio", 5, "aac"))}
        self.assertEqual(len(keys), 3)
        same = subsync.SyncStore.key(m, sidecar, m.audio[0])
        f.write_text("another file")
        os.utime(f, (1, 1))
        self.assertNotEqual(same, subsync.SyncStore.key(m, sidecar, m.audio[0]))


if __name__ == "__main__":
    unittest.main()
