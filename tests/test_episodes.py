"""episodes.py: episode parsing and picking the next episode in the folder."""

import unittest

from helpers import TempDirMixin
from jancast import episodes


class ParseTest(unittest.TestCase):
    def test_parse(self):
        cases = {
            "Night.Train.S06E02.1080p.WEB.mkv": ("nighttrain", 6, 2),
            "night train - s06e10 - title.mkv": ("nighttrain", 6, 10),
            "Show_S1E5.mp4": ("show", 1, 5),
            "Show.S01.E03.mkv": ("show", 1, 3),
            "Show.S01E02E03.mkv": ("show", 1, 2),
            "Movie.2021.2160p.mkv": None,
            "Docs.S2024E01.mkv": None,          # 4-digit "seasons" are years, not seasons
            "BOSS01E02.mkv": None,              # S must start a token
            "Harbour Lights (2010) - S03E03 - '90.mkv": ("harbourlights", 3, 3),   # no year in the key
            "[Group] Lantern - 12 [1080p].mkv": ("lantern", None, 12),
            "Show.1x02.mkv": ("show", 1, 2),
        }
        for name, want in cases.items():
            self.assertEqual(episodes.parse(name), want, name)


class NextEpisodeTest(TempDirMixin, unittest.TestCase):
    def folder(self, *names):
        d = self.make_tempdir()
        for n in names:
            (d / n).write_bytes(b"x")
        return d

    def next_name(self, d, current):
        n = episodes.next_episode(d / current)
        return n and n["name"]

    def test_next_in_season(self):
        d = self.folder("Show.S01E01.mkv", "Show.S01E02.mkv", "Show.S01E03.mkv")
        self.assertEqual(self.next_name(d, "Show.S01E01.mkv"), "Show.S01E02.mkv")
        n = episodes.next_episode(d / "Show.S01E02.mkv")
        self.assertEqual((n["name"], n["season"], n["episode"], n["path"]),
                         ("Show.S01E03.mkv", 1, 3, str(d / "Show.S01E03.mkv")))
        self.assertIsNone(self.next_name(d, "Show.S01E03.mkv"))

    def test_skips_gaps_and_crosses_seasons(self):
        d = self.folder("Show.S01E01.mkv", "Show.S01E04.mkv", "Show.S02E01.mkv")
        self.assertEqual(self.next_name(d, "Show.S01E01.mkv"), "Show.S01E04.mkv")
        self.assertEqual(self.next_name(d, "Show.S01E04.mkv"), "Show.S02E01.mkv")

    def test_ignores_other_shows_samples_and_non_video(self):
        d = self.folder("Show.S01E01.mkv", "Other.S01E02.mkv", "Show.S01E02.sample.mkv",
                        "Show.S01E02.srt", "Show.S01E03.mkv")
        self.assertEqual(self.next_name(d, "Show.S01E01.mkv"), "Show.S01E03.mkv")

    def test_not_an_episode(self):
        d = self.folder("Movie.2021.mkv", "Movie.S01E02.mkv")
        self.assertIsNone(episodes.next_episode(d / "Movie.2021.mkv"))

    def test_multi_episode_file_is_followed_by_the_one_after_it(self):
        d = self.folder("Show.S01E01E02.mkv", "Show.S01E02.mkv", "Show.S01E03.mkv")
        self.assertEqual(self.next_name(d, "Show.S01E01E02.mkv"), "Show.S01E03.mkv")

    def test_naming_schemes_mix_and_years_are_ignored(self):
        d = self.folder("Show (2019) - S01E01 - Pilot.mkv", "show.s01e02.1080p.web.mkv",
                        "Show.2019.1x03.mkv")
        self.assertEqual(self.next_name(d, "Show (2019) - S01E01 - Pilot.mkv"),
                         "show.s01e02.1080p.web.mkv")
        self.assertEqual(self.next_name(d, "show.s01e02.1080p.web.mkv"), "Show.2019.1x03.mkv")

    def test_show_name_from_the_folder(self):
        root = self.make_tempdir()
        d = root / "Show Name (2019)" / "Season 1"
        d.mkdir(parents=True)
        for n in ("E01.mkv", "E02.mkv", "Show.Name.S01E03.mkv", "Other.S01E04.mkv"):
            (d / n).write_bytes(b"x")
        n = episodes.next_episode(d / "E01.mkv")
        self.assertEqual((n["name"], n["season"], n["episode"]), ("E02.mkv", 1, 2))
        self.assertEqual(n["name_info"]["title"], "Show Name S1 · E2")
        self.assertEqual(self.next_name(d, "E02.mkv"), "Show.Name.S01E03.mkv")
        self.assertIsNone(self.next_name(d, "Show.Name.S01E03.mkv"))

    def test_absolute_numbering(self):
        d = self.folder("[Grp] Lantern - 11 [1080p].mkv", "[Grp] Lantern - 12 [1080p].mkv")
        n = episodes.next_episode(d / "[Grp] Lantern - 11 [1080p].mkv")
        self.assertEqual((n["name"], n["season"], n["episode"]),
                         ("[Grp] Lantern - 12 [1080p].mkv", None, 12))
