"""names.py: what a file is, from real-world style file and folder names."""

import unittest
from pathlib import Path

from jancast import names

E, M = "episode", "movie"

# path → (title, show, season, episode, episode_end, episode_title, year, kind)
CASES = {
    # The user's own files.
    "night.train.s06e03.1080p.web.h264-group[example.to].mkv":
        ("Night Train S6 · E3", "Night Train", 6, 3, None, None, None, E),
    "/v/Harbour Lights (2010) Season 3 S03 + Extras (1080p x265 HEVC 10bit AAC 2.0 GROUP)/"
    "Harbour Lights (2010) - S03E03 - '90 - Autumn (1080p x265 GROUP).mkv":
        ("Harbour Lights S3 · E3", "Harbour Lights", 3, 3, None, "'90 - Autumn", 2010, E),
    "Quiet Hours 2025 1080p WEB-DL HEVC x265 5.1 GROUP.mkv":
        ("Quiet Hours (2025)", None, None, None, None, None, 2025, M),

    # SxxEyy spellings.
    "Show.S01E02.mkv": ("Show S1 · E2", "Show", 1, 2, None, None, None, E),
    "show s1e2.mkv": ("Show S1 · E2", "Show", 1, 2, None, None, None, E),
    "Show.S01.E02.720p.mkv": ("Show S1 · E2", "Show", 1, 2, None, None, None, E),
    "Show S01 E02.mkv": ("Show S1 · E2", "Show", 1, 2, None, None, None, E),
    "Show_-_S01E02_-_Title.mkv": ("Show S1 · E2", "Show", 1, 2, None, "Title", None, E),
    "Show.Name.S01E02.The.Title.1080p.mkv":
        ("Show Name S1 · E2", "Show Name", 1, 2, None, "The Title", None, E),
    "Show.Name.S01E02.720p.HDTV.x264-KILLERS[ettv].mkv":
        ("Show Name S1 · E2", "Show Name", 1, 2, None, None, None, E),
    "Breaking Bad S05E16 Felina 1080p.mkv":
        ("Breaking Bad S5 · E16", "Breaking Bad", 5, 16, None, "Felina", None, E),
    "The.Mandalorian.S03E01.Chapter.17.1080p.WEB.mkv":
        ("The Mandalorian S3 · E1", "The Mandalorian", 3, 1, None, "Chapter 17", None, E),
    "Fargo.S05E01.1080p.WEB.H264-GLHF[TGx].mkv": ("Fargo S5 · E1", "Fargo", 5, 1, None, None, None, E),
    "www.example.org    -    Night Train S06E01 1080p.mkv":
        ("Night Train S6 · E1", "Night Train", 6, 1, None, None, None, E),
    "Show (2019) - S01E02 - Title [WEBDL-1080p][EAC3 5.1][h264]-GROUP.mkv":
        ("Show S1 · E2", "Show", 1, 2, None, "Title", 2019, E),
    "Show.S01E02-GRP.mkv": ("Show S1 · E2", "Show", 1, 2, None, None, None, E),
    "Show.S01E02.REPACK.PROPER.720p.mkv": ("Show S1 · E2", "Show", 1, 2, None, None, None, E),
    "The Office (US) - S05E14 - Stress Relief.mkv":
        ("The Office (US) S5 · E14", "The Office (US)", 5, 14, None, "Stress Relief", None, E),

    # Multi-episode files.
    "Show.S01E02E03.1080p.mkv": ("Show S1 · E2–3", "Show", 1, 2, 3, None, None, E),
    "Show.S01E02-E03.mkv": ("Show S1 · E2–3", "Show", 1, 2, 3, None, None, E),
    "Show.S01E02-03.mkv": ("Show S1 · E2–3", "Show", 1, 2, 3, None, None, E),
    "the.office.us.s05e14-e15.720p.mkv":
        ("The Office Us S5 · E14–15", "The Office Us", 5, 14, 15, None, None, E),

    # Other episode tags.
    "Show.1x02.Title.mkv": ("Show S1 · E2", "Show", 1, 2, None, "Title", None, E),
    "Top.Gear.20x01.mkv": ("Top Gear S20 · E1", "Top Gear", 20, 1, None, None, None, E),
    "Show - Season 1 Episode 2 - Pilot.mkv": ("Show S1 · E2", "Show", 1, 2, None, "Pilot", None, E),
    "The.Daily.Show.2024.03.15.Guest.Name.720p.WEB.h264-GRP.mkv":
        ("The Daily Show 2024-03-15", "The Daily Show", None, None, None, "2024-03-15", None, E),

    # Anime-style absolute numbering.
    "[Group] Lantern - 12 (1080p) [ABCD1234].mkv":
        ("Lantern E12", "Lantern", None, 12, None, None, None, E),
    "Lantern - 12v2.mkv": ("Lantern E12", "Lantern", None, 12, None, None, None, E),
    "[Erai-raws] One Piece - 1071 [1080p][Multiple Subtitle].mkv":
        ("One Piece E1071", "One Piece", None, 1071, None, None, None, E),
    "[Group] Kaguya-sama - 03 [1080p].mkv":
        ("Kaguya-sama E3", "Kaguya-sama", None, 3, None, None, None, E),
    "[Group] Show S2 - 05 - The Title [1080p].mkv":
        ("Show S2 · E5", "Show", 2, 5, None, "The Title", None, E),
    # Not guessed: a bare 3-digit number, or a number that starts a title.
    "Show - 102.mkv": ("Show - 102", None, None, None, None, None, None, M),
    "Show - 12 Angry Men.mkv": ("Show - 12 Angry Men", None, None, None, None, None, None, M),

    # Titles with numbers, years and dots.
    "9-1-1.S07E01.1080p.WEB.h264-ETHEL.mkv": ("9-1-1 S7 · E1", "9-1-1", 7, 1, None, None, None, E),
    "The.100.S01E01.mkv": ("The 100 S1 · E1", "The 100", 1, 1, None, None, None, E),
    "1923.S01E01.mkv": ("1923 S1 · E1", "1923", 1, 1, None, None, None, E),
    "Babylon.5.S01E01.mkv": ("Babylon 5 S1 · E1", "Babylon 5", 1, 1, None, None, None, E),
    "Doctor.Who.2005.S01E01.Rose.1080p.mkv":
        ("Doctor Who S1 · E1", "Doctor Who", 1, 1, None, "Rose", 2005, E),
    "Marvels.Agents.of.S.H.I.E.L.D.S01E01.720p.mkv":
        ("Marvels Agents of S.H.I.E.L.D. S1 · E1", "Marvels Agents of S.H.I.E.L.D.", 1, 1, None,
         None, None, E),
    "S.W.A.T.2017.S07E01.1080p.mkv": ("S.W.A.T. S7 · E1", "S.W.A.T.", 7, 1, None, None, 2017, E),
    "house.of.the.dragon.s02e01.2160p.web.h265-ggez.mkv":
        ("House of the Dragon S2 · E1", "House of the Dragon", 2, 1, None, None, None, E),
    "Movie (2019).mkv": ("Movie (2019)", None, None, None, None, None, 2019, M),
    "Movie.2019.1080p.BluRay.x264-GRP.mkv": ("Movie (2019)", None, None, None, None, None, 2019, M),
    "Movie.2019-GROUP.mkv": ("Movie (2019)", None, None, None, None, None, 2019, M),
    "2001 A Space Odyssey 1968.mkv":
        ("2001 A Space Odyssey (1968)", None, None, None, None, None, 1968, M),
    "2001.A.Space.Odyssey.1968.1080p.BluRay.mkv":
        ("2001 A Space Odyssey (1968)", None, None, None, None, None, 1968, M),
    "Blade Runner 2049 (2017).mkv": ("Blade Runner 2049 (2017)", None, None, None, None, None, 2017, M),
    "Blade.Runner.2049.2017.2160p.UHD.BluRay.REMUX.HDR.HEVC.Atmos-EPSiLON.mkv":
        ("Blade Runner 2049 (2017)", None, None, None, None, None, 2017, M),
    "Blade.Runner.2049.1080p.mkv": ("Blade Runner 2049", None, None, None, None, None, None, M),
    "1917.2019.1080p.BluRay.mkv": ("1917 (2019)", None, None, None, None, None, 2019, M),
    "1917.mkv": ("1917", None, None, None, None, None, None, M),
    "Wonder.Woman.1984.2020.1080p.mkv": ("Wonder Woman 1984 (2020)", None, None, None, None, None, 2020, M),
    "Toy.Story.4.2019.1080p.mkv": ("Toy Story 4 (2019)", None, None, None, None, None, 2019, M),
    "12 Angry Men (1957).mkv": ("12 Angry Men (1957)", None, None, None, None, None, 1957, M),
    "(500) Days of Summer (2009) [1080p].mkv":
        ("(500) Days of Summer (2009)", None, None, None, None, None, 2009, M),
    "E.T. the Extra-Terrestrial 1982.mkv":
        ("E.T. the Extra-Terrestrial (1982)", None, None, None, None, None, 1982, M),
    "Harry.Potter.and.the.Deathly.Hallows.Part.1.2010.1080p.mkv":
        ("Harry Potter and the Deathly Hallows Part 1 (2010)", None, None, None, None, None, 2010, M),
    "the.matrix.1999.mkv": ("The Matrix (1999)", None, None, None, None, None, 1999, M),
    "Movie.Name.1080p.mkv": ("Movie Name", None, None, None, None, None, None, M),

    # Release flags and words that are also titles.
    "Movie.2019.EXTENDED.1080p.BluRay.mkv": ("Movie (2019)", None, None, None, None, None, 2019, M),
    "Movie (2019) Directors Cut 1080p.mkv": ("Movie (2019)", None, None, None, None, None, 2019, M),
    "Movie.Title.2019.MULTi.1080p.mkv": ("Movie Title (2019)", None, None, None, None, None, 2019, M),
    "Charlotte's Web 1973 1080p.mkv": ("Charlotte's Web (1973)", None, None, None, None, None, 1973, M),
    "Uncut Gems 2019 1080p.mkv": ("Uncut Gems (2019)", None, None, None, None, None, 2019, M),
    "Mr.Hollands.Opus.1995.1080p.mkv": ("Mr Hollands Opus (1995)", None, None, None, None, None, 1995, M),
    "show.s01e02.web.h264-grp.mkv": ("Show S1 · E2", "Show", 1, 2, None, None, None, E),

    # Folders fill in what the name lacks.
    "/tv/Show Name (2019)/Season 01/S01E02.mkv":
        ("Show Name S1 · E2", "Show Name", 1, 2, None, None, 2019, E),
    "/tv/Show/Season 2/02x05.mkv": ("Show S2 · E5", "Show", 2, 5, None, None, None, E),
    "/tv/Show Name (2019)/Season 1/E05.mkv": ("Show Name S1 · E5", "Show Name", 1, 5, None, None, 2019, E),
    "/tv/Lost/Season 1/Episode 5.mkv": ("Lost S1 · E5", "Lost", 1, 5, None, None, None, E),
    "/tv/Show Name/Season 1/05 - Pilot.mkv": ("Show Name S1 · E5", "Show Name", 1, 5, None, "Pilot", None, E),
    "/tv/Breaking Bad/Season 5/Breaking Bad - 5x16 - Felina.mkv":
        ("Breaking Bad S5 · E16", "Breaking Bad", 5, 16, None, "Felina", None, E),
    "/tv/Night.Train.S06.1080p.WEB/s06e03.mkv": ("Night Train S6 · E3", "Night Train", 6, 3, None, None, None, E),
    "/tv/Show/Specials/Show.S00E01.mkv": ("Show S0 · E1", "Show", 0, 1, None, None, None, E),
    "/films/Inception (2010)/inception.mkv": ("Inception (2010)", None, None, None, None, None, 2010, M),
    # A generic folder is not a show name.
    "/Users/x/Downloads/S01E02 - Pilot.mkv": ("S1 · E2", None, 1, 2, None, "Pilot", None, E),

    # Not episodes.
    "Show.S2024E01.mkv": ("Show S2024E01", None, None, None, None, None, None, M),
    "BOSS01E02.mkv": ("BOSS01E02", None, None, None, None, None, None, M),
    "2019.mkv": ("2019", None, None, None, None, None, None, M),
}

KEYS = ("title", "show", "season", "episode", "episode_end", "episode_title", "year", "kind")


class ParseTest(unittest.TestCase):
    def test_table(self):
        for path, want in CASES.items():
            with self.subTest(path):
                got = names.parse(path)
                self.assertEqual(tuple(got[k] for k in KEYS), want)

    def test_keys_and_types(self):
        for path in CASES:
            got = names.parse(path)
            self.assertEqual(set(got), set(KEYS), path)
            self.assertTrue(got["title"], path)          # never empty

    def test_fallback_to_the_file_name(self):
        self.assertEqual(names.parse("/x/[only a tag].mkv")["title"], "[only a tag]")
        self.assertEqual(names.parse("weird_name.mkv")["title"], "Weird Name")

    def test_download_in_progress(self):
        got = names.parse("/dl/Star City (2026) - S01E01 - The Eyes (1080p ATV WEB-DL x265).mkv.part")
        self.assertEqual((got["show"], got["season"], got["episode"]), ("Star City", 1, 1))
        for n in ("a.mkv.part", "a.mp4.!qB", "a.avi.crdownload"):
            self.assertTrue(names.is_partial(n), n)
            self.assertTrue(names.is_video(n), n)
        for n in ("a.part", "Part.mkv", "a.zip.part", "a.mkv"):
            self.assertFalse(names.is_partial(n), n)
        self.assertEqual(names.without_partial("/dl/a.mkv.part"), Path("/dl/a.mkv"))

    def test_show_key(self):
        a = names.parse("The.Office.US.S05E14.mkv")
        b = names.parse("the office us - s05e15 - title.mkv")
        self.assertEqual(names.show_key(a), names.show_key(b))
        self.assertEqual(names.show_key(names.parse("Movie (2019).mkv")), "")
