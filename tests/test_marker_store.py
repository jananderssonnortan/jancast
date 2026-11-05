"""markers.MarkerStore / credits_from_picture: credits found without chapters,
in the background, kept per file."""

import subprocess
import time
import unittest
from unittest import mock

from helpers import HAVE_FFMPEG, SLOW, TempDirMixin, audio_stream, make_media, video_stream
from luftbro import markers


def wait_done(store, m, timeout=60):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        s = store.status(m)
        if s["status"] != "working":
            return s
        time.sleep(0.02)
    raise AssertionError("still working")


class MarkerStoreTest(TempDirMixin, unittest.TestCase):
    def setUp(self):
        # The intro detector decodes audio: not in these tests (the files are fake).
        patcher = mock.patch.object(markers.MarkerStore, "detect_intro", lambda self, m: None)
        patcher.start()
        self.addCleanup(patcher.stop)

    def episode(self, d, name):
        return make_media(d, [video_stream(0), audio_stream(1)], name=name, duration=2700)

    def test_detects_once_and_keeps_the_result(self):
        d = self.make_tempdir()
        ep2 = self.episode(d, "Show.S01E02.mkv")
        self.episode(d, "Show.S01E03.mkv")
        store = markers.MarkerStore(root=self.make_tempdir())
        calls = []

        def detect(m):
            calls.append(m.path.name)
            return 2580.25

        with mock.patch.object(markers, "detect_credits", detect):
            self.assertEqual(store.status(ep2)["status"], "working")
            done = wait_done(store, ep2)
            self.assertEqual(done, {"status": "done", "intro": None,
                                    "credits": {"start": 2580.25, "source": "picture"}})
            self.assertEqual(store.status(ep2), done)
        self.assertEqual(calls, ["Show.S01E02.mkv"])         # once

    def test_nothing_found_is_kept_too(self):
        d = self.make_tempdir()
        ep1 = self.episode(d, "Show.S01E01.mkv")
        self.episode(d, "Show.S01E02.mkv")
        store = markers.MarkerStore(root=self.make_tempdir())
        with mock.patch.object(markers, "detect_credits", lambda m: None):
            self.assertEqual(wait_done(store, ep1), {"status": "done", "intro": None, "credits": None})

    def test_films_and_lone_episodes_are_unavailable(self):
        d = self.make_tempdir()
        film = make_media(d, [video_stream(0), audio_stream(1)], name="Film.2020.mkv")
        lone = self.episode(self.make_tempdir(), "Show.S01E05.mkv")
        store = markers.MarkerStore(root=self.make_tempdir())
        self.assertEqual(store.status(film)["status"], "unavailable")
        self.assertEqual(store.status(lone)["status"], "unavailable")

    def test_last_episode_gets_its_intro_but_no_credits(self):
        d = self.make_tempdir()
        self.episode(d, "Show.S01E01.mkv")
        last = self.episode(d, "Show.S01E02.mkv")
        store = markers.MarkerStore(root=self.make_tempdir())
        credits = mock.Mock(return_value=2600)
        with mock.patch.object(markers, "detect_credits", credits), \
                mock.patch.object(markers.MarkerStore, "detect_intro",
                                  lambda self, m: {"start": 30, "end": 80, "source": "audio"}):
            self.assertEqual(wait_done(store, last), {"status": "done", "credits": None,
                                                      "intro": {"start": 30, "end": 80, "source": "audio"}})
        credits.assert_not_called()             # nothing next to offer


class IntroFromPrintsTest(unittest.TestCase):
    def test_finds_the_shared_stretch_at_another_offset(self):
        import random
        rng = random.Random(7)
        theme = [rng.getrandbits(32) for _ in range(40 * markers.PRINTS_PER_S)]
        noise = lambda s: [rng.getrandbits(32) for _ in range(int(s * markers.PRINTS_PER_S))]
        mine = noise(95) + theme + noise(300)          # cold open of 95 s
        other = noise(30) + theme + noise(300)
        (span, error) = markers.intro_from_prints(mine, other)
        self.assertAlmostEqual(span["start"], 95, delta=1)
        self.assertAlmostEqual(span["end"], 135, delta=1)
        self.assertLess(error, 0.1)

    def test_a_shared_logo_at_the_same_moment_does_not_hide_the_intro(self):
        import random
        rng = random.Random(11)
        noise = lambda s: [rng.getrandbits(32) for _ in range(int(s * markers.PRINTS_PER_S))]
        logo = noise(12)                                 # same place in both: wins the vote
        theme = noise(50)
        mine = noise(60) + logo + noise(300) + theme + noise(200)
        other = noise(60) + logo + noise(80) + theme + noise(400)
        span, _ = markers.intro_from_prints(mine, other)
        self.assertAlmostEqual(span["start"], 372, delta=1)
        self.assertAlmostEqual(span["end"], 422, delta=1)

    def test_nothing_shared_or_too_short(self):
        import random
        rng = random.Random(3)
        noise = lambda s: [rng.getrandbits(32) for _ in range(int(s * markers.PRINTS_PER_S))]
        self.assertIsNone(markers.intro_from_prints(noise(300), noise(300)))
        sting = noise(8)                                 # a shared 8 s logo is no intro
        self.assertIsNone(markers.intro_from_prints(noise(20) + sting + noise(200), sting + noise(220)))


@SLOW
@unittest.skipUnless(HAVE_FFMPEG, "ffmpeg not installed")
class IntroFromSoundTest(TempDirMixin, unittest.TestCase):
    def test_two_episodes_with_the_same_intro(self):
        d = self.make_tempdir()

        # The intro: a melody that doesn't repeat (a note every 1/3 s, note n
        # from n*n*0.37 mod 7); a repeating one matches at many offsets.
        note = "floor(mod(floor(t*3)*floor(t*3)*0.37\\,7))"
        theme = f"aevalsrc=0.3*sin(2*PI*(300+150*{note})*t):d=45"

        def episode(name, cold_open_seed, cold_open_s):
            out = d / name
            # Cold open and story: different noise; the intro: the same tune.
            subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                            "-f", "lavfi", "-i", f"anoisesrc=seed={cold_open_seed}:d={cold_open_s}:a=0.3",
                            "-f", "lavfi", "-i", theme,
                            "-f", "lavfi", "-i", f"anoisesrc=seed={cold_open_seed + 100}:d=120:a=0.3",
                            "-filter_complex", "[0:a][1:a][2:a]concat=n=3:v=0:a=1[a]",
                            "-map", "[a]", "-c:a", "aac", str(out)], check=True, capture_output=True)
            return out

        a = markers._prints(markers._spectrum(episode("a.m4a", 1, 70), 235))
        b = markers._prints(markers._spectrum(episode("b.m4a", 2, 25), 190))
        span, _ = markers.intro_from_prints(a, b)
        self.assertAlmostEqual(span["start"], 70, delta=2)
        self.assertAlmostEqual(span["end"], 115, delta=3)


@SLOW
@unittest.skipUnless(HAVE_FFMPEG, "ffmpeg not installed")
class CreditsFromPictureTest(TempDirMixin, unittest.TestCase):
    def clip(self, *, story_s, credits_s, logo_s=0):
        """Colourful story, then black credits with white text, then an optional
        bright studio logo."""
        d = self.make_tempdir()
        out = d / "ep.mkv"
        parts = [f"testsrc2=size=320x180:rate=25:duration={story_s}",
                 # white "text" on black (drawtext needs a font library)
                 f"color=c=black:size=320x180:rate=25:duration={credits_s},"
                 "drawbox=x=110:y=80:w=100:h=6:color=white:t=fill"]
        if logo_s:
            parts.append(f"testsrc=size=320x180:rate=25:duration={logo_s}")
        inputs = sum((["-f", "lavfi", "-i", p] for p in parts), [])
        n = len(parts)
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *inputs,
                        "-filter_complex", "".join(f"[{i}:v]" for i in range(n)) + f"concat=n={n}:v=1[v]",
                        "-map", "[v]", "-c:v", "libx264", "-g", "50", "-pix_fmt", "yuv420p", str(out)],
                       check=True, capture_output=True)
        return VideoOnly(out)

    def test_finds_the_second_the_credits_start(self):
        m = self.clip(story_s=300, credits_s=40)
        self.assertAlmostEqual(markers.credits_from_picture(m.path, m.duration), 300, delta=1)

    def test_studio_logos_after_the_credits(self):
        m = self.clip(story_s=300, credits_s=40, logo_s=10)
        self.assertAlmostEqual(markers.credits_from_picture(m.path, m.duration), 300, delta=1)

    def test_a_short_dark_scene_is_not_credits(self):
        m = self.clip(story_s=300, credits_s=10)
        self.assertIsNone(markers.credits_from_picture(m.path, m.duration))


class VideoOnly:
    """media.probe needs an audio stream; the detector only needs path and length."""

    def __init__(self, path):
        out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                              "-of", "csv=p=0", str(path)], capture_output=True, text=True, check=True)
        self.path, self.duration = path, float(out.stdout)


if __name__ == "__main__":
    unittest.main()
