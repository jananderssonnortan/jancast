"""Fast start (ondemand.py) and the MKV keyframe index (keyframes.py).

Unit tests for planning, fMP4 timestamp rewriting and WebVTT cutting; the
slow tests run real ffmpeg and check that segments made by restarted runs
(jumps) are byte-identical to an uninterrupted run, with continuous
timestamps and audio/video kept in sync.
"""

import hashlib
import shutil
import subprocess
import unittest
from pathlib import Path
from unittest import mock

from helpers import HAVE_FFMPEG, SLOW, TempDirMixin, audio_stream, make_media, video_stream
from jancast import keyframes, media, ondemand
from test_media_ffmpeg import ffmpeg


def box(kind, payload):
    return (8 + len(payload)).to_bytes(4, "big") + kind.encode() + payload


def fragment(tfdt, version=1, cto=None, seq=7):
    """A moof (mfhd, traf/tfhd/tfdt/trun) + mdat, like ffmpeg's frag_keyframe output."""
    tfdt_box = box("tfdt", bytes([version, 0, 0, 0]) + tfdt.to_bytes(8 if version else 4, "big"))
    flags = 0x000301 | (0x800 if cto is not None else 0)       # data offset, duration, size (+ cto)
    trun = bytes([1]) + flags.to_bytes(3, "big") + (1).to_bytes(4, "big") + (0).to_bytes(4, "big")
    trun += (512).to_bytes(4, "big") + (100).to_bytes(4, "big")
    if cto is not None:
        trun += (cto & 0xFFFFFFFF).to_bytes(4, "big")
    traf = box("traf", box("tfhd", bytes(8)) + tfdt_box + box("trun", trun))
    moof = box("moof", box("mfhd", bytes(4) + seq.to_bytes(4, "big")) + traf)
    return moof, box("mdat", b"x" * 100)


class PlanTest(unittest.TestCase):
    def test_segments_start_on_keyframes_about_six_seconds_apart(self):
        starts = ondemand.plan_segments([0, 2, 4, 6, 8, 10, 12, 14], 16.0)
        self.assertEqual(starts, [0.0, 6, 12])

    def test_sparse_keyframes_make_longer_segments(self):
        self.assertEqual(ondemand.plan_segments([0, 10, 20, 30], 40), [0.0, 10, 20, 30])

    def test_tiny_last_segment_is_merged(self):
        self.assertEqual(ondemand.plan_segments([0, 6, 12], 12.4), [0.0, 6])

    def test_first_keyframe_late_still_starts_at_zero(self):
        self.assertEqual(ondemand.plan_segments([0.042, 6.042], 20)[0], 0.0)


class FragmentTest(unittest.TestCase):
    def test_rewrite_tfdt_and_sequence(self):
        moof, mdat = fragment(1328, cto=-1328)
        f = ondemand.Fragment(moof, mdat)
        self.assertEqual((f.tfdt, f.first_cto), (1328, -1328))
        f.rewrite(160000 + 1328, sequence=42)
        again = ondemand.Fragment(bytes(f.data[:f.moof_size]), bytes(f.data[f.moof_size:]))
        self.assertEqual(again.tfdt, 161328)
        self.assertEqual(int.from_bytes(again.data[again.mfhd_at:again.mfhd_at + 4], "big"), 42)
        self.assertEqual(len(f.data), len(moof) + len(mdat))      # sizes untouched

    def test_32_bit_tfdt_overflow_is_refused(self):
        f = ondemand.Fragment(*fragment(0, version=0))
        with self.assertRaises(ValueError):
            f.rewrite(1 << 33, sequence=1)


class VttTest(unittest.TestCase):
    def test_parse_and_segment(self):
        cues = ondemand.parse_vtt("WEBVTT\n\n00:00:01.000 --> 00:00:03.500 line:90%\nHello\nworld\n\n"
                                  "01:02:03.250 --> 01:02:05.000\nLater\n")
        self.assertEqual(cues, [(1.0, 3.5, "line:90%", "Hello\nworld"), (3723.25, 3725.0, "", "Later")])
        seg = ondemand.vtt_segment(cues[:1])
        # On the media timeline (+10 s), without a mapping header (tvOS ignores it).
        self.assertNotIn("X-TIMESTAMP-MAP", seg)
        self.assertIn("00:00:11.000 --> 00:00:13.500 line:90%\nHello\nworld", seg)


class EligibilityTest(TempDirMixin, unittest.TestCase):
    def test_not_for_reencodes_burn_in_or_when_disabled(self):
        d = self.make_tempdir()
        av1 = make_media(d, [video_stream(0, "av1"), audio_stream(1)], name="a.mkv")
        h264 = make_media(d, [video_stream(0), audio_stream(1)], name="b.mkv")
        with mock.patch.object(ondemand, "mkv_keyframes", return_value=[0.0, 6.0]):
            self.assertIsNone(ondemand.keyframes_for(av1, None))
            self.assertEqual(ondemand.keyframes_for(h264, None), [0.0, 6.0])
            with mock.patch.dict("os.environ", {"JANCAST_FAST_START": "0"}):
                self.assertIsNone(ondemand.keyframes_for(h264, None))

    def test_no_index_for_non_mkv(self):
        d = self.make_tempdir()
        (d / "x.mkv").write_bytes(b"not a matroska file" * 10)
        self.assertIsNone(keyframes.mkv_keyframes(d / "x.mkv"))


class PreparedTest(TempDirMixin, unittest.TestCase):
    """prepared_s follows the player, not only the current ffmpeg run (stub
    runs, no ffmpeg): segments 0-99, 6 s each."""

    def setUp(self):
        d = self.make_tempdir()
        m = make_media(d, [video_stream(0), audio_stream(1)], duration=600.0)
        self.od = ondemand.OnDemand(m, m.audio[0], None, d, [i * 6.0 for i in range(100)])
        self.od._restart = self.restart

    def restart(self, index):
        self.od.run = mock.Mock(start_index=index, next_index={"v": index, "a": index})

    def make(self, indexes):
        for i in indexes:
            self.od.save_segment("v", i, b"x")
            self.od.save_segment("a", i, b"x")

    def ask(self, index):
        self.od.wait_for("/" + ondemand.VIDEO_SEG.format(index), timeout=0)

    def test_follows_the_player_into_segments_an_earlier_run_made(self):
        """Regression: after a jump back the new run stopped 30 segments past
        the jump (nothing requested beyond them was missing), so prepared_s
        froze there while the TV played on into the first run's segments -
        headroom went negative and "barely keeping up" stuck."""
        od = self.od
        self.ask(50)                                  # first run from 50 (a jump there)
        self.make(range(50, 81))
        self.ask(20)                                  # jump back: restarts at 20
        self.assertEqual(od.run.start_index, 20)
        self.make(range(20, 51))                      # the run, paused 30 past 20
        self.assertEqual(od.prepared_s, 81 * 6.0)     # one gapless stretch 20..80
        for i in range(21, 61):
            self.ask(i)
        self.assertEqual(od.prepared_s, 81 * 6.0)
        self.assertEqual(od.requested, 60)            # the run is told to keep going
        self.assertEqual(od.segments_ready, 61)

    def test_from_the_segment_read_last(self):
        od = self.od
        self.assertEqual(od.prepared_s, 0.0)
        self.ask(10)
        self.assertEqual(od.prepared_s, 60.0)         # nothing there yet
        self.make(range(10, 15))
        self.assertEqual(od.prepared_s, 90.0)
        self.make(range(16, 20))                      # a gap at 15
        self.assertEqual(od.prepared_s, 90.0)
        self.ask(16)
        self.assertEqual(od.prepared_s, 120.0)
        self.make(range(20, 100))
        self.assertEqual(od.prepared_s, 600.0)        # to the end

    def test_audio_requests_do_not_move_the_read_point(self):
        self.make(range(0, 5))
        self.ask(0)
        self.od.wait_for("/" + ondemand.AUDIO_SEG.format(40), timeout=0)
        self.assertEqual(self.od.prepared_s, 30.0)


@SLOW
@unittest.skipUnless(HAVE_FFMPEG, "ffmpeg not installed")
class WaitStatsTest(TempDirMixin, unittest.TestCase):
    def test_counts_waits_and_ready_segments(self):
        d = Path(self.make_tempdir())
        m = make_media(d, [video_stream(0), audio_stream(1)], duration=60.0)
        od = ondemand.OnDemand(m, m.audio[0], None, d, [i * 6.0 for i in range(10)])
        self.assertEqual(od.wait_stats()["wait_max_ms"], None)
        (d / ondemand.VIDEO_SEG.format(0)).write_bytes(b"x")
        od.wait_for("/" + ondemand.VIDEO_SEG.format(0))            # ready: no wait
        with mock.patch.object(od, "_wait_until_made"):
            od.wait_for("/" + ondemand.VIDEO_SEG.format(5))        # had to wait
        od.wait_for("/master.m3u8")                                 # not a segment
        stats = od.wait_stats()
        self.assertEqual((stats["segment_requests"], stats["waited"], stats["restarts"]), (2, 1, 0))
        self.assertIsNotNone(stats["wait_max_ms"])


class FfmpegTest(TempDirMixin, unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dir = Path(__import__("tempfile").mkdtemp(prefix="jancast-test-"))
        cls.clip = cls.dir / "clip.mkv"
        # With chapters: they must not turn into an extra track (tvOS refuses that).
        meta = cls.dir / "chapters.txt"
        meta.write_text(";FFMETADATA1\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=30000\ntitle=One\n"
                        "[CHAPTER]\nTIMEBASE=1/1000\nSTART=30000\nEND=62000\ntitle=Two\n")
        ffmpeg("-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24", "-f", "lavfi",
               "-i", "sine=frequency=440:sample_rate=48000", "-i", str(meta), "-t", "62",
               "-map", "0:v", "-map", "1:a", "-map_chapters", "2",
               "-c:v", "libx264", "-g", "48", "-bf", "2", "-c:a", "ac3", "-b:a", "96k",
               "-metadata:s:a:0", "language=swe", str(cls.clip))

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.dir, ignore_errors=True)

    def test_index_matches_real_keyframes(self):
        times = keyframes.mkv_keyframes(self.clip)
        out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-skip_frame", "nokey",
                              "-show_entries", "frame=pts_time", "-of", "csv=p=0", str(self.clip)],
                             capture_output=True, text=True, check=True).stdout
        real = [round(float(x.strip(",")), 3) for x in out.split() if x.strip(",")]
        self.assertEqual([round(t, 3) for t in times], real)

    def segments(self, ahead, jumps, stereo=False):
        m = media.probe(self.clip)
        out = self.make_tempdir()
        self.warnings = []
        with mock.patch.object(ondemand, "AHEAD_SEGMENTS", ahead):
            od = ondemand.OnDemand(m, m.audio[0], None, out, keyframes.mkv_keyframes(self.clip), stereo,
                                   on_warning=self.warnings.append)
            try:
                od.start(0)
                od.wait_ready(0)
                for i in list(jumps) + list(range(od.count)):
                    for track in ("video", "audio"):
                        od.wait_for(f"/seg_{track}_{i:05d}.m4s")
            finally:
                od.stop()
        return out, od

    def test_jumps_give_byte_identical_segments(self):
        one, od = self.segments(1000, [])
        jumped, _ = self.segments(1, [7, 2, 9, 4])
        # Runs stopped for the jumps die on closed pipes; that is not a warning.
        self.assertEqual(self.warnings, [])
        names = sorted(p.name for p in one.glob("seg_*.m4s"))
        self.assertEqual(len(names), 2 * od.count)
        for name in names:
            a = hashlib.md5((one / name).read_bytes()).hexdigest()
            b = hashlib.md5((jumped / name).read_bytes()).hexdigest()
            self.assertEqual(a, b, name)
        for playlist in ("stream_video.m3u8", "stream_audio.m3u8"):
            text = (one / playlist).read_text()
            self.assertIn("#EXT-X-PLAYLIST-TYPE:VOD", text)
            self.assertTrue(text.rstrip().endswith("#EXT-X-ENDLIST"))
        master = (one / "master.m3u8").read_text()
        self.assertIn("CODECS=", master)
        # The audio rendition carries its language, or tvOS shows no subtitles.
        audio_line = next(line for line in master.splitlines() if "TYPE=AUDIO" in line)
        self.assertIn('LANGUAGE="sv"', audio_line)
        for init in ("init_video.mp4", "init_audio.mp4"):
            streams = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "stream=codec_type",
                                      "-of", "csv=p=0", str(one / init)],
                                     capture_output=True, text=True, check=True).stdout.split()
            self.assertEqual(len(streams), 1, f"{init} has tracks {streams}")

    def test_timestamps_continuous_and_in_sync(self):
        out, od = self.segments(1, [6, 3])
        firsts = {}
        for track in ("video", "audio"):
            whole = out / f"all_{track}.mp4"
            whole.write_bytes((out / f"init_{track}.mp4").read_bytes()
                              + b"".join(p.read_bytes() for p in sorted(out.glob(f"seg_{track}_*.m4s"))))
            rows = subprocess.run(["ffprobe", "-v", "error", "-show_entries",
                                   "packet=pts_time,dts_time,duration_time", "-of", "csv=p=0", str(whole)],
                                  capture_output=True, text=True, check=True).stdout.split()
            packets = [tuple(map(float, r.strip(",").split(",")[:3])) for r in rows]
            firsts[track] = min(p[0] for p in packets)
            for a, b in zip(packets, packets[1:]):
                self.assertAlmostEqual(b[1] - a[1], a[2], delta=0.002, msg=f"{track} gap at {a[1]}")
        # Both tracks keep their place relative to the source, shifted by the offset.
        src = {}
        for track, sel in (("video", "v:0"), ("audio", "a:0")):
            first = subprocess.run(["ffprobe", "-v", "error", "-select_streams", sel, "-show_entries",
                                    "packet=pts_time", "-of", "csv=p=0", "-read_intervals", "%+#1",
                                    str(self.clip)], capture_output=True, text=True).stdout.split()[0]
            src[track] = float(first.strip(","))
        for track in firsts:
            self.assertAlmostEqual(firsts[track], src[track] + ondemand.TIMELINE_OFFSET_S, delta=0.002)
