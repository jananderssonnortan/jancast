"""thumbs.py: command shape, serving rules, caching; real ffmpeg run is slow-marked."""

import json
import time
import unittest

from helpers import HAVE_FFMPEG, SLOW, TempDirMixin, audio_stream, make_media, video_stream
from jancast import media, thumbs
from test_media_ffmpeg import make_clip


def wait_done(store, m, timeout=30):
    deadline = time.time() + timeout
    while time.time() < deadline:
        info = store.info(m)
        if info["done"] or info["failed"]:
            return info
        time.sleep(0.1)
    raise AssertionError("thumbnails not done in time")


class PaletteColoursTest(unittest.TestCase):
    def test_colourful_pixels_win_and_neighbours_blend(self):
        grey, red = bytes([128, 128, 128]), bytes([200, 30, 30])
        # Frame 1: mostly grey with a red patch; frame 2: all grey.
        frames = (grey * 3 + red) + grey * 4
        cols = thumbs.palette_colours(frames, 2, 2)
        self.assertEqual(len(cols), 2)
        r, g, b = cols[0]
        self.assertGreater(r, g + 0.1)            # reads red, not a grey average
        # Blended with its neighbour: the grey frame picks up some red too.
        self.assertGreater(cols[1][0], cols[1][1])

    def test_palette_file_is_served_only_when_made(self):
        import tempfile
        store = thumbs.ThumbnailStore(tempfile.mkdtemp())
        key = "0123456789abcdef"
        self.assertIsNone(store.file(key, "palette.png"))
        (store.root / key).mkdir(parents=True)
        (store.root / key / "palette.png").write_bytes(b"x")
        self.assertEqual(store.file(key, "palette.png").name, "palette.png")
        self.assertIsNone(store.file("../etc", "palette.png"))


class CommandTest(TempDirMixin, unittest.TestCase):
    def media(self, **video):
        d = self.make_tempdir()
        return make_media(d, [video_stream(0, **video), audio_stream(1)])

    def test_sdr_is_software_keyframes_only(self):
        m = self.media(width=1920, height=800)
        cmd = thumbs.build_cmd(m, self.make_tempdir(), tonemap=False)
        self.assertEqual(cmd[:3], ["nice", "-n", "10"])
        self.assertIn("nokey", cmd)
        self.assertNotIn("videotoolbox", " ".join(cmd))
        vf = cmd[cmd.index("-vf") + 1]
        self.assertTrue(vf.startswith(f"fps=1/{thumbs.INTERVAL_S}:eof_action=pass,scale=480:200"), vf)

    def test_hdr_tonemaps_with_videotoolbox(self):
        m = self.media(codec="hevc", width=3840, height=2160)
        vf = (cmd := thumbs.build_cmd(m, self.make_tempdir(), tonemap=True))[cmd.index("-vf") + 1]
        self.assertIn("scale_vt=w=480:h=270:color_matrix=bt709", vf)
        self.assertIn("-hwaccel", cmd)


class StoreTest(TempDirMixin, unittest.TestCase):
    def setUp(self):
        self.store = thumbs.ThumbnailStore(self.make_tempdir())

    def test_file_validation(self):
        key = "0123456789abcdef"
        d = self.store.root / key
        d.mkdir(parents=True)
        for n in (1, 2):
            (d / f"{n:05d}.jpg").write_bytes(b"jpg")
        # In progress: 2 may still be being written, 1 is complete.
        self.assertEqual(self.store.file(key, "1.jpg"), d / "00001.jpg")
        self.assertIsNone(self.store.file(key, "2.jpg"))
        (d / thumbs.DONE_FILE).write_text(json.dumps({"count": 2}))
        self.assertEqual(self.store.file(key, "00002.jpg"), d / "00002.jpg")
        for bad in [(key, "3.jpg"), (key, "0.jpg"), (key, "../x.jpg"), ("../../etc", "1.jpg"),
                    (key, "1.png")]:
            self.assertIsNone(self.store.file(*bad), bad)

    def test_key_changes_with_file(self):
        d = self.make_tempdir()
        k1 = self.store.key(make_media(d, [video_stream(0), audio_stream(1)]))
        k2 = self.store.key(make_media(d, [video_stream(0), audio_stream(1)], content=b"different size"))
        self.assertNotEqual(k1, k2)

    def test_key_kept_while_download_completes(self):
        d = self.make_tempdir()
        m = make_media(d, [video_stream(0), audio_stream(1)], name="movie.mkv.part")
        k1 = self.store.key(m)
        m.path.write_bytes(b"more pieces")
        m.path.rename(d / "movie.mkv")
        self.assertEqual(m.path, d / "movie.mkv")
        self.assertEqual(k1, self.store.key(m))

    def test_prune_keeps_recent(self):
        for i in range(thumbs.MAX_CACHED + 5):
            (self.store.root / f"{i:016x}").mkdir(parents=True)
        self.store._prune(exclude=set())
        self.assertEqual(len(list(self.store.root.iterdir())), thumbs.MAX_CACHED - 1)


@SLOW
@unittest.skipUnless(HAVE_FFMPEG, "ffmpeg not installed")
class FfmpegTest(TempDirMixin, unittest.TestCase):
    def test_makes_one_thumbnail_per_interval(self):
        clip = make_clip(self.make_tempdir(), ["-c:v", "libx264"], seconds=35, embed_sub=False)
        m = media.probe(clip)
        store = thumbs.ThumbnailStore(self.make_tempdir())
        info = wait_done(store, m)
        self.assertEqual((info["done"], info["count"], info["total"]), (True, 4, 4))
        self.assertEqual((info["width"], info["height"]), (480, 270))
        f = store.file(store.key(m), "4.jpg")
        self.assertTrue(f.read_bytes().startswith(b"\xff\xd8"))   # JPEG
        # The palette: one pixel per thumbnail, served next to them.
        self.assertEqual(info["palette"], f"/api/thumbs/{store.key(m)}/palette.png")
        png = store.file(store.key(m), "palette.png").read_bytes()
        self.assertTrue(png.startswith(b"\x89PNG"))
        self.assertEqual(int.from_bytes(png[16:20], "big"), 4)    # width = thumbnails
        # Cached: a second store over the same folder does not run ffmpeg again.
        again = thumbs.ThumbnailStore(store.root)
        self.assertTrue(again.info(m)["done"])
        self.assertEqual(again.jobs, {})

    def test_not_a_video_fails_quietly(self):
        d = self.make_tempdir()
        m = make_media(d, [video_stream(0), audio_stream(1)])   # file is just "xxxx…"
        info = wait_done(thumbs.ThumbnailStore(self.make_tempdir()), m)
        self.assertEqual((info["done"], info["failed"]), (False, True))
