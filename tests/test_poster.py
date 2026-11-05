"""poster.py: the title in recognised text, frame scoring, cover art inside
and next to a file, and the store's order of preference and cache."""

import json
import struct
import subprocess
import time
import unittest
from pathlib import Path
from unittest import mock

from helpers import HAVE_FFMPEG, SLOW, TempDirMixin, audio_stream, make_media, video_stream
from luftbro import media as media_module
from luftbro import poster, thumbs


def wait_done(store, m, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        s = store.status(m)
        if s["status"] != "working":
            return s
        time.sleep(0.02)
    raise AssertionError("still working")


def episode(d, name="Harbour.Lights.2026.S01E01.1080p.mkv", **kw):
    return make_media(d, [video_stream(0), audio_stream(1)], name=name, duration=2880, **kw)


class TitleTextTest(unittest.TestCase):
    def test_keys_come_from_the_show_or_the_film_title(self):
        self.assertEqual(poster.title_keys({"kind": "episode", "show": "Night Train", "title": "Night Train S1 · E2"}),
                         ["nighttrain"])
        self.assertEqual(poster.title_keys({"kind": "movie", "title": "Blade Runner 2049 (2017)", "show": None}),
                         ["bladerunner"])
        self.assertEqual(poster.title_keys({"kind": "movie", "title": "The Matrix (1999)", "show": None}),
                         ["thematrix", "matrix"])
        self.assertEqual(poster.title_keys({"kind": "movie", "title": "Up", "show": None}), [])
        self.assertEqual(poster.title_keys({"kind": "episode", "show": None, "title": "E5"}), [])

    def test_matches_letters_only_whatever_the_case(self):
        self.assertTrue(poster.text_matches("HARBOUR LIGHTS", "harbourlights"))
        self.assertTrue(poster.text_matches("Night\nTrain", "nighttrain"))
        self.assertTrue(poster.text_matches("A NIGHT TRAIN PRODUCTION", "nighttrain"))
        self.assertFalse(poster.text_matches("", "nighttrain"))
        self.assertFalse(poster.text_matches("NORTHERN FILMS", "nighttrain"))

    def test_a_few_letters_off_still_match_long_titles(self):
        self.assertTrue(poster.text_matches("HARBDUR LIGHIS", "harbourlights"))
        self.assertTrue(poster.text_matches("N1GHT TRAlN", "nighttrain"))
        self.assertFalse(poster.text_matches("ANNA LIND | ERIK HOLM", "harbourlights"))
        self.assertFalse(poster.text_matches("MAJA BERG | OLLE STRAND", "nighttrain"))

    def test_frames_between_read_ones_belong_to_the_card(self):
        said = [206.875, 207.375, 208.875, 210.375]
        self.assertTrue(poster.in_run(207.375, said))
        self.assertTrue(poster.in_run(209.875, said))           # read 1 s before and 0.5 s after
        self.assertFalse(poster.in_run(205.375, said))          # before the first
        self.assertFalse(poster.in_run(211.375, said))          # after the last
        self.assertFalse(poster.in_run(209.0, [207.0, 211.0]))  # too far from both

    def test_short_titles_must_match_exactly(self):
        self.assertTrue(poster.text_matches("D A R K", "dark"))
        self.assertFalse(poster.text_matches("DARN", "dark"))
        self.assertFalse(poster.text_matches("MARK HAMILL", "dark"))


def rgb_frame(width, height, pixel):
    return bytes(pixel) * (width * height)


def checker_frame(width, height, a, b):
    out = bytearray()
    for y in range(height):
        for x in range(width):
            out += bytes(a if (x + y) % 2 else b)
    return bytes(out)


class FrameScoreTest(unittest.TestCase):
    def test_near_black_frames_are_never_chosen(self):
        w, h = 8, 4
        black = rgb_frame(w, h, (0, 0, 0))
        # A title on black: a few white pixels on black.
        title = bytearray(black)
        title[0:3 * 3] = bytes((255, 255, 255)) * 3
        scores = poster.frame_scores(black + bytes(title), w, h)
        self.assertEqual(scores, [-1.0, -1.0])
        self.assertIsNone(poster.best_frame(scores))

    def test_colourful_detailed_frames_beat_flat_grey(self):
        w, h = 8, 4
        grey = rgb_frame(w, h, (115, 115, 115))
        colour = checker_frame(w, h, (200, 60, 40), (40, 90, 200))
        bright = rgb_frame(w, h, (250, 250, 250))
        scores = poster.frame_scores(grey + colour + bright, w, h)
        self.assertEqual(scores.index(max(scores)), 1)
        self.assertGreater(scores[0], scores[2])        # mid-grey over blown-out white

    def test_best_frame_skips_the_edges(self):
        scores = [5.0] + [0.1] * 18 + [5.0]
        self.assertEqual(poster.best_frame(scores), 1)
        self.assertEqual(poster.best_frame([0.5, 0.9, 0.2]), 1)          # too few to cut
        self.assertEqual(poster.best_frame([-1.0, -1.0, -1.0]), None)


class ImageSizeTest(TempDirMixin, unittest.TestCase):
    def test_png_and_jpeg_headers(self):
        d = self.make_tempdir()
        png = d / "a.png"
        png.write_bytes(b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + b"IHDR" + struct.pack(">II", 640, 360) + b"\x08\x02\x00\x00\x00")
        self.assertEqual(poster.image_size(png), (640, 360))
        jpg = d / "a.jpg"
        app0 = b"\xff\xe0" + struct.pack(">H", 16) + b"JFIF\x00" + b"\x00" * 9
        sof = b"\xff\xc0" + struct.pack(">H", 17) + b"\x08" + struct.pack(">HH", 300, 200) + b"\x03" + b"\x00" * 9
        jpg.write_bytes(b"\xff\xd8" + app0 + b"\xff\xff" + sof + b"\xff\xd9")
        self.assertEqual(poster.image_size(jpg), (200, 300))
        (d / "x.jpg").write_bytes(b"not an image")
        self.assertIsNone(poster.image_size(d / "x.jpg"))
        self.assertIsNone(poster.image_size(d / "missing.jpg"))
        self.assertTrue(poster.is_landscape((640, 360)))
        self.assertFalse(poster.is_landscape((200, 300)))
        self.assertFalse(poster.is_landscape(None))


class CoverCandidatesTest(TempDirMixin, unittest.TestCase):
    def test_covers_inside_the_file_are_found_by_type_name_or_disposition(self):
        d = self.make_tempdir()
        streams = [video_stream(0), audio_stream(1),
                   {"index": 2, "codec_type": "attachment", "tags": {"filename": "cover.jpg", "mimetype": "image/jpeg"}},
                   {"index": 3, "codec_type": "attachment", "tags": {"filename": "cover_land.jpg", "mimetype": "application/octet-stream"}},
                   {"index": 4, "codec_type": "attachment", "tags": {"filename": "font.ttf", "mimetype": "application/x-truetype-font"}},
                   {"index": 5, "codec_type": "video", "codec_name": "mjpeg", "disposition": {"attached_pic": 1}}]
        m = make_media(d, streams, name="Film.2020.mkv")
        self.assertEqual(m.covers, [(2, "cover.jpg", "attachment"), (3, "cover_land.jpg", "attachment"),
                                    (5, "", "picture")])
        self.assertEqual(m.video["index"], 0)
        # The landscape one first, then the rest in file order.
        self.assertEqual(poster.cover_candidates(m),
                         [("attachment", 3), ("attachment", 2), ("picture", 5)])

    def test_sidecars_named_for_the_file_then_the_folder_then_the_series(self):
        series = self.make_tempdir() / "Show"
        season = series / "Season 1"
        season.mkdir(parents=True)
        m = episode(season, "Show.S01E02.mkv")
        for name in ("Show.S01E02-thumb.jpg", "Show.S01E02.png", "poster.jpg", "fanart.JPG", "Show.S01E03.jpg"):
            (season / name).write_bytes(b"x")
        for name in ("landscape.jpg", "folder.jpg"):
            (series / name).write_bytes(b"x")
        # Each file once, whatever the case of its name (and of the disk).
        self.assertEqual([p.name.lower() for _, p in poster.cover_candidates(m)],
                         ["show.s01e02-thumb.jpg", "show.s01e02.png", "fanart.jpg", "poster.jpg",
                          "landscape.jpg", "folder.jpg"])

    def test_a_film_looks_only_in_its_own_folder(self):
        parent = self.make_tempdir()
        d = parent / "Film (2020)"
        d.mkdir()
        m = make_media(d, [video_stream(0), audio_stream(1)], name="Film.2020.mkv")
        (parent / "landscape.jpg").write_bytes(b"x")
        (d / "folder.jpg").write_bytes(b"x")
        self.assertEqual([p.name for _, p in poster.cover_candidates(m)], ["folder.jpg"])


class PosterStoreTest(TempDirMixin, unittest.TestCase):
    """The chain of preference, with each step stood in for."""

    def store(self, cover=None, title=None, frame=None, **kw):
        store = poster.PosterStore(root=self.make_tempdir(), **kw)
        self.calls = []

        def step(name, answer):
            def run(media, key, *args):
                self.calls.append(name)
                if answer is None:
                    return None
                (store.root / f"{key}.jpg").write_bytes(b"\xff\xd8jpeg")
                return answer
            return run
        for name, answer in (("_cover", cover), ("_title_card", title), ("_best_thumbnail", frame)):
            patcher = mock.patch.object(store, name, step(name, answer))
            patcher.start()
            self.addCleanup(patcher.stop)
        return store

    def test_cover_art_wins_and_nothing_else_runs(self):
        m = episode(self.make_tempdir())
        store = self.store(cover={"source": "cover", "time": None}, title={"source": "title", "time": 300})
        self.assertEqual(store.status(m)["status"], "working")
        done = wait_done(store, m)
        key = store.key(m)
        self.assertEqual(done, {"status": "done", "source": "cover", "time": None,
                                "url": f"/api/thumbs/{key}/poster.jpg"})
        self.assertEqual(self.calls, ["_cover"])
        self.assertEqual(store.file(key).read_bytes(), b"\xff\xd8jpeg")
        self.assertEqual(store.status(m), done)          # kept, not chosen again
        self.assertEqual(self.calls, ["_cover"])

    def test_title_card_then_the_best_frame(self):
        m = episode(self.make_tempdir())
        store = self.store(title={"source": "title", "time": 303.5})
        self.assertEqual(wait_done(store, m)["source"], "title")
        self.assertEqual(self.calls, ["_cover", "_title_card"])

        m2 = episode(self.make_tempdir(), "Show.S01E01.mkv")
        store = self.store(frame={"source": "frame", "time": 1230})
        self.assertEqual(wait_done(store, m2), {"status": "done", "source": "frame", "time": 1230,
                                                "url": f"/api/thumbs/{store.key(m2)}/poster.jpg"})
        self.assertEqual(self.calls, ["_cover", "_title_card", "_best_thumbnail"])

    def test_nothing_found_is_kept_too(self):
        m = episode(self.make_tempdir())
        store = self.store()
        self.assertEqual(wait_done(store, m), {"status": "done", "source": None, "time": None, "url": None})
        self.assertIsNone(store.file(store.key(m)))
        self.assertEqual(json.loads((store.root / f"{store.key(m)}.json").read_text()),
                         {"source": None, "time": None})

    def test_a_failing_step_counts_as_nothing_found(self):
        m = episode(self.make_tempdir())
        store = self.store(frame={"source": "frame", "time": 10})
        with mock.patch.object(store, "_title_card", side_effect=subprocess.TimeoutExpired("ffmpeg", 1)):
            self.assertEqual(wait_done(store, m)["source"], "frame")

    def test_not_started_without_make_and_for_downloads_in_progress(self):
        d = self.make_tempdir()
        m = episode(d)
        store = self.store(cover={"source": "cover", "time": None})
        self.assertEqual(store.status(m, start=False)["status"], "unavailable")
        self.assertEqual(self.calls, [])
        partial = make_media(d, [video_stream(0), audio_stream(1)], name="Show.S01E01.mkv.part")
        self.assertEqual(store.status(partial)["status"], "unavailable")
        self.assertEqual(self.calls, [])

    def test_waits_for_thumbnails_and_markers_before_the_title_card(self):
        m = episode(self.make_tempdir())
        tstore = thumbs.ThumbnailStore(self.make_tempdir())
        answers = iter([{"status": "working", "intro": None},
                        {"status": "done", "intro": {"start": 264.1, "end": 307.5, "source": "audio"}}])
        seen = {}
        store = poster.PosterStore(root=self.make_tempdir(), thumbs=lambda: tstore, markers=lambda media: next(answers))

        def title_card(media, key, intro_end):
            seen["intro_end"] = intro_end
            seen["thumbs_waited"] = tstore.folder(media) is not None
            (store.root / f"{key}.jpg").write_bytes(b"\xff\xd8jpeg")
            return {"source": "title", "time": intro_end - 4}
        folder = tstore.root / tstore.key(m)
        folder.mkdir(parents=True)
        (folder / thumbs.DONE_FILE).write_text('{"count": 1}')
        with mock.patch.object(store, "_cover", return_value=None), \
                mock.patch.object(store, "_title_card", title_card), \
                mock.patch.object(poster, "WAIT_MARKERS_S", 5):
            self.assertEqual(wait_done(store, m)["time"], 303.5)
        self.assertEqual(seen, {"intro_end": 307.5, "thumbs_waited": True})

    def test_file_names_are_checked(self):
        store = poster.PosterStore(root=self.make_tempdir())
        key = "0123456789abcdef"
        self.assertIsNone(store.file(key))
        store.root.mkdir(parents=True, exist_ok=True)
        (store.root / f"{key}.jpg").write_bytes(b"x")
        self.assertEqual(store.file(key).name, f"{key}.jpg")
        self.assertIsNone(store.file("../etc"))
        self.assertIsNone(store.file("0123456789ABCDEF"))
        self.assertIsNone(store.file(""))

    def test_old_posters_are_pruned(self):
        store = self.store(cover={"source": "cover", "time": None})
        store.root.mkdir(parents=True, exist_ok=True)
        for i in range(poster.MAX_CACHED + 5):
            (store.root / f"{i:016x}.json").write_text("{}")
            (store.root / f"{i:016x}.jpg").write_bytes(b"x")
        m = episode(self.make_tempdir())
        wait_done(store, m)
        kept = list(store.root.glob("*.json"))
        self.assertEqual(len(kept), poster.MAX_CACHED)
        self.assertIn(store.root / f"{store.key(m)}.json", kept)
        self.assertEqual(len(list(store.root.glob("*.jpg"))), poster.MAX_CACHED)


def make_clip(path, seconds=4, size="320x180"):
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", f"testsrc=s={size}:d={seconds}:r=10",
                    "-f", "lavfi", "-i", f"sine=d={seconds}", "-c:v", "libx264", "-g", "10", "-pix_fmt", "yuv420p",
                    "-c:a", "aac", str(path)], check=True, timeout=60)


def make_image(path, colour, size):
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", f"color=c={colour}:s={size}:d=1",
                    "-frames:v", "1", "-update", "1", str(path)], check=True, timeout=60)


@unittest.skipUnless(HAVE_FFMPEG, "needs ffmpeg")
class RealFilesTest(TempDirMixin, unittest.TestCase):
    def store(self, tstore=None, **kw):
        return poster.PosterStore(root=self.make_tempdir(), thumbs=lambda: tstore, **kw)

    @SLOW
    def test_landscape_cover_inside_the_file_is_taken_portrait_is_not(self):
        d = self.make_tempdir()
        land, portrait = d / "cover_land.jpg", d / "cover.png"
        make_image(land, "orange", "320x180")
        make_image(portrait, "blue", "200x300")
        with_both, portrait_only = d / "Film.2020.mkv", d / "Other.2021.mkv"
        clip = d / "clip.mkv"
        make_clip(clip)
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(clip), "-attach", str(portrait),
                        "-metadata:s:2", "mimetype=image/png", "-attach", str(land),
                        "-metadata:s:3", "mimetype=image/jpeg", "-c", "copy", str(with_both)], check=True, timeout=60)
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(clip), "-attach", str(portrait),
                        "-metadata:s:2", "mimetype=image/png", "-c", "copy", str(portrait_only)], check=True, timeout=60)
        land.unlink()
        portrait.unlink()
        store = self.store()
        m = media_module.probe(with_both)
        self.assertEqual([c[2] for c in m.covers], ["picture", "picture"])
        self.assertEqual(wait_done(store, m)["source"], "cover")
        size = poster.image_size(store.file(store.key(m)))
        self.assertEqual(size, (poster.WIDTH, 270))
        m2 = media_module.probe(portrait_only)
        with mock.patch.object(store, "_title_card", return_value=None):
            self.assertEqual(wait_done(store, m2)["source"], None)

    @SLOW
    def test_sidecar_next_to_the_file(self):
        d = self.make_tempdir()
        clip = d / "Film.2020.mkv"
        make_clip(clip)
        make_image(d / "Film.2020-thumb.png", "green", "400x225")
        m = media_module.probe(clip)
        store = self.store()
        self.assertEqual(wait_done(store, m)["source"], "cover")
        self.assertEqual(poster.image_size(store.file(store.key(m))), (480, 270))

    @SLOW
    def test_title_card_is_the_best_looking_frame_that_says_the_title(self):
        d = self.make_tempdir()
        clip = d / "Harbour.Lights.S01E01.mkv"
        make_clip(clip, seconds=20)
        (d / "Harbour.Lights.S01E02.mkv").write_bytes(b"x")
        m = media_module.probe(clip)
        store = self.store(markers=lambda media: {"status": "done", "intro": {"start": 2, "end": 16}})
        read = []

        def recognise(files):
            # Only the frames 3 s and 5 s into the clip carry the title; the
            # rest of the intro window says other things.
            read.append(len(files))
            return {str(f): ("HARBOUR LIGHTS" if int(f.stem) in (3, 7) else "NORTHERN FILMS") for f in files}
        with mock.patch.object(store, "_read", recognise), mock.patch.object(poster.ocrsubs, "possible", return_value=True):
            done = wait_done(store, m, timeout=120)
        self.assertEqual(done["source"], "title")
        # Window [2, 17] at 2 fps: frame 3 is 3.0 s, frame 7 is 5.0 s in.
        self.assertIn(done["time"], (3.0, 5.0))
        self.assertEqual(poster.image_size(store.file(store.key(m))), (480, 270))
        self.assertEqual(read, [30])

    @SLOW
    def test_best_thumbnail_when_nothing_says_the_title(self):
        d = self.make_tempdir()
        clip = d / "Film.2020.mkv"
        make_clip(clip, seconds=60)
        m = media_module.probe(clip)
        tstore = thumbs.ThumbnailStore(self.make_tempdir())
        self.addCleanup(tstore.stop_all)
        tstore.ensure(m)
        deadline = time.monotonic() + 60
        while tstore.folder(m) is None and time.monotonic() < deadline:
            time.sleep(0.1)
        store = self.store(tstore)
        with mock.patch.object(store, "_read", return_value={}), \
                mock.patch.object(poster.ocrsubs, "possible", return_value=True):
            done = wait_done(store, m, timeout=120)
        self.assertEqual(done["source"], "frame")
        count = len(list(tstore.folder(m).glob("[0-9]*.jpg")))
        self.assertTrue(0 < done["time"] < (count - 1) * thumbs.INTERVAL_S, done)
        self.assertEqual(poster.image_size(store.file(store.key(m))), (480, 270))


if __name__ == "__main__":
    unittest.main()
