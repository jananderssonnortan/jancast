"""markers.py: Skip Intro / Next Episode times from named chapters."""

import subprocess
import unittest

from helpers import HAVE_FFMPEG, TempDirMixin
from luftbro import markers, media

EPISODE = 45 * 60


def find(*chapters, duration=EPISODE):
    return markers.from_chapters(list(chapters), duration)


class ChapterNameTest(unittest.TestCase):
    def test_intro_and_credits_by_name(self):
        m = find((0, 95, "Cold Open"), (95, 185, "Opening Credits"), (185, 2500, "Episode"),
                 (2500, 2700, "End Credits"))
        self.assertEqual(m["intro"], {"start": 95, "end": 185})
        self.assertEqual(m["credits"], {"start": 2500})

    def test_anime_style_short_names(self):
        m = find((0, 120, "Prologue"), (120, 210, "OP1"), (210, 1300, "Part A"),
                 (1300, 1390, "ED"), (1390, 1420, "Preview"), duration=1420)
        self.assertEqual(m["intro"], {"start": 120, "end": 210})
        self.assertEqual(m["credits"], {"start": 1300})

    def test_numbered_and_punctuated_titles(self):
        m = find((0, 60, "01 - Intro"), (60, 2600, "02 - Story"), (2600, 2700, "Chapter 3: Ending"))
        self.assertEqual(m["intro"], {"start": 0, "end": 60})
        self.assertEqual(m["credits"], {"start": 2600})

    def test_generic_chapters_say_nothing(self):
        m = find((0, 600, "Chapter 1"), (600, 1200, "Chapter 2"), (1200, 2700, "Chapter 3"))
        self.assertEqual(m, {"intro": None, "credits": None})
        self.assertEqual(find(), {"intro": None, "credits": None})

    def test_opening_credits_are_the_intro_not_the_credits(self):
        m = find((30, 120, "Opening Credits"))
        self.assertEqual(m["intro"], {"start": 30, "end": 120})
        self.assertIsNone(m["credits"])

    def test_implausible_places_are_ignored(self):
        # An "intro" late in the episode, or as long as an act; "credits" early on.
        self.assertIsNone(find((1500, 1590, "Intro"))["intro"])
        self.assertIsNone(find((0, 900, "Intro"))["intro"])
        self.assertIsNone(find((300, 400, "Credits"))["credits"])

    def test_numbered_parts_and_bare_numbers(self):
        m = find((0, 40, "02 Intro"), (40, 2600, "Story"), (2600, 2650, "Credits (Part 2)"))
        self.assertEqual(m["intro"], {"start": 0, "end": 40})
        self.assertEqual(m["credits"], {"start": 2600})
        self.assertEqual(find((30, 120, "Opening 1"))["intro"], {"start": 30, "end": 120})
        self.assertEqual(find((2600, 2700, "Ending 2"))["credits"], {"start": 2600})
        self.assertEqual(find((2600, 2700, "End Credits Part 1"))["credits"], {"start": 2600})
        self.assertEqual(find((10, 70, "Intro Song"))["intro"], {"start": 10, "end": 70})

    def test_titles_early_are_the_intro_late_the_credits(self):
        m = find((20, 80, "Titles"), (80, 2600, "Story"), (2600, 2700, "Titles"))
        self.assertEqual(m["intro"], {"start": 20, "end": 80})
        self.assertEqual(m["credits"], {"start": 2600})

    def test_recaps_are_not_intros(self):
        self.assertIsNone(find((0, 60, "Recap"), (60, 120, "Previously on"))["intro"])

    def test_unknown_duration_still_finds_the_intro(self):
        m = find((30, 90, "Intro"), duration=0)
        self.assertEqual(m["intro"], {"start": 30, "end": 90})
        self.assertIsNone(m["credits"])

    def test_words_containing_the_names_do_not_count(self):
        m = find((60, 150, "The Opening Night"), (2600, 2700, "Endgame"))
        self.assertEqual(m, {"intro": None, "credits": None})


@unittest.skipUnless(HAVE_FFMPEG, "ffmpeg not installed")
class ProbeChaptersTest(TempDirMixin, unittest.TestCase):
    def test_probe_reads_chapters(self):
        d = self.make_tempdir()
        meta = d / "chapters.txt"
        meta.write_text(";FFMETADATA1\n"
                        "[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=5000\ntitle=Intro\n"
                        "[CHAPTER]\nTIMEBASE=1/1000\nSTART=5000\nEND=16000\ntitle=Story\n"
                        "[CHAPTER]\nTIMEBASE=1/1000\nSTART=16000\nEND=20000\ntitle=Credits\n")
        clip = d / "ep.mkv"
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                        "-f", "lavfi", "-i", "testsrc=size=320x240:rate=10:duration=20",
                        "-f", "lavfi", "-i", "sine=duration=20",
                        "-i", str(meta), "-map", "0", "-map", "1", "-map_chapters", "2",
                        "-c:v", "libx264", "-c:a", "aac", str(clip)], check=True, capture_output=True)
        m = media.probe(clip)
        self.assertEqual([c[2] for c in m.chapters], ["Intro", "Story", "Credits"])
        self.assertEqual(markers.from_chapters(m.chapters, m.duration),
                         {"intro": {"start": 0.0, "end": 5.0}, "credits": {"start": 16.0}})


if __name__ == "__main__":
    unittest.main()
