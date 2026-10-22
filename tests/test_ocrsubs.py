"""ocrsubs.py: PGS decoding (synthetic streams), PNG output, WebVTT, status."""

import struct
import unittest
import zlib
from pathlib import Path
from unittest import mock

from helpers import TempDirMixin, audio_stream, make_media, sub_stream, video_stream
from jancast import ocrsubs


def segment(pts, kind, payload):
    return b"PG" + struct.pack(">II", int(pts * 90000), 0) + bytes([kind]) + struct.pack(">H", len(payload)) + payload


def pcs(objects):
    head = struct.pack(">HHB", 1920, 1080, 0x10) + struct.pack(">H", 1) + bytes([0x80, 0, 0, len(objects)])
    return head + b"".join(struct.pack(">HBBHH", obj, 0, 0, 100, y) for obj, y in objects)


def pds():
    # palette 0: transparent; 1: white opaque (text); 2: black opaque (outline)
    entries = bytes([1, 235, 128, 128, 255]) + bytes([2, 16, 128, 128, 255])
    return bytes([0, 0]) + entries


def ods(obj, width, height, rle):
    return struct.pack(">HBB", obj, 0, 0xC0) + (len(rle) + 4).to_bytes(3, "big") + struct.pack(">HH", width, height) + rle


class RleTest(unittest.TestCase):
    def test_runs_and_line_ends(self):
        # row 1: color 1, then 3x color 0 (short run), end of line
        # row 2: 2x color 2 (short coloured run), end of line
        rle = bytes([1, 0, 0x03, 0, 0, 0, 0x82, 2, 0, 0])
        self.assertEqual(ocrsubs.decode_rle(rle, 4, 2), [bytes([1, 0, 0, 0]), bytes([2, 2, 0, 0])])


class DisplaySetTest(unittest.TestCase):
    def test_subtitle_shown_until_the_clear_screen(self):
        rle = bytes([1, 1, 2, 0, 0]) + bytes([2, 1, 1, 0, 0])
        sup = (segment(10.0, ocrsubs.PCS, pcs([(0, 900)])) + segment(10.0, ocrsubs.PDS, pds())
               + segment(10.0, ocrsubs.ODS, ods(0, 3, 2, rle)) + segment(10.0, ocrsubs.END, b"")
               + segment(12.5, ocrsubs.PCS, pcs([])) + segment(12.5, ocrsubs.END, b""))
        events = ocrsubs.display_sets(ocrsubs.read_segments(sup))
        self.assertEqual(len(events), 1)
        start, end, images = events[0]
        self.assertEqual((start, end), (10.0, 12.5))
        # Letters (light, opaque) black on white; outline and background white.
        self.assertEqual(images[0], [bytes([0, 0, 255]), bytes([255, 0, 0])])

    def test_missing_clear_screen_ends_after_a_while(self):
        rle = bytes([1, 0, 0])
        sup = (segment(5.0, ocrsubs.PCS, pcs([(0, 900)])) + segment(5.0, ocrsubs.PDS, pds())
               + segment(5.0, ocrsubs.ODS, ods(0, 1, 1, rle)) + segment(5.0, ocrsubs.END, b""))
        (start, end, _), = ocrsubs.display_sets(ocrsubs.read_segments(sup))
        self.assertEqual(end, 5.0 + ocrsubs.MAX_CUE_S)

    def test_not_pgs(self):
        with self.assertRaises(ocrsubs.OCRError):
            ocrsubs.read_segments(b"x" * 20)


class OutputTest(unittest.TestCase):
    def test_png_is_valid_grayscale(self):
        data = ocrsubs.png([bytes([0, 255]), bytes([255, 0])])
        self.assertTrue(data.startswith(b"\x89PNG\r\n\x1a\n"))
        width, height, depth, color = struct.unpack(">IIBB", data[16:26])
        self.assertEqual((depth, color), (8, 0))
        self.assertEqual((width, height), (2 * 2 + 64, 2 * 2 + 64))     # 2x scale + white margins
        idat = data[data.index(b"IDAT") + 4:data.index(b"IEND") - 8]
        self.assertEqual(len(zlib.decompress(idat)), height * (width + 1))

    def test_webvtt(self):
        text = ocrsubs.webvtt([(1.5, 3.25, "Hello\nthere"), (3723.0, 3724.0, "Later")])
        self.assertEqual(text, "WEBVTT\n\n00:00:01.500 --> 00:00:03.250\nHello\nthere\n\n"
                               "01:02:03.000 --> 01:02:04.000\nLater\n\n")


class StatusTest(TempDirMixin, unittest.TestCase):
    def test_unavailable_without_swiftc(self):
        d = self.make_tempdir()
        m = make_media(d, [video_stream(0), audio_stream(1), sub_stream(2, "hdmv_pgs_subtitle")])
        with mock.patch.object(ocrsubs.shutil, "which", return_value=None):
            self.assertEqual(ocrsubs.status(m, m.subs[0])["status"], "unavailable")

    def test_cached_text_is_ready(self):
        d = self.make_tempdir()
        m = make_media(d, [video_stream(0), audio_stream(1), sub_stream(2, "hdmv_pgs_subtitle")])
        path = ocrsubs.cache_path(m, m.subs[0], accurate=True)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("WEBVTT\n")
        self.assertEqual(ocrsubs.cached(m, m.subs[0]), path)
        with mock.patch.object(ocrsubs.shutil, "which", return_value="/usr/bin/swiftc"):
            self.assertEqual(ocrsubs.status(m, m.subs[0])["status"], "ready")


class CacheTrimTest(TempDirMixin, unittest.TestCase):
    def test_keeps_the_most_recently_used_texts(self):
        import os
        folder = ocrsubs.cache_dir() / "ocr"
        folder.mkdir(parents=True, exist_ok=True)
        for f in folder.glob("*.vtt"):
            f.unlink()
        for i in range(5):
            f = folder / f"t{i}.vtt"
            f.write_text("WEBVTT\n")
            os.utime(f, (1000 + i, 1000 + i))
        ocrsubs.touch(folder / "t0.vtt")                    # used just now
        ocrsubs.prune_text_cache(keep=2)
        self.assertEqual(sorted(f.name for f in folder.glob("*.vtt")), ["t0.vtt", "t4.vtt"])

    def test_old_helper_builds_are_removed(self):
        bin_dir = ocrsubs.cache_dir() / "bin"
        bin_dir.mkdir(parents=True, exist_ok=True)
        (bin_dir / "jancast-ocr-oldversion").write_bytes(b"x")
        with mock.patch.object(ocrsubs.subprocess, "run") as run, \
                mock.patch.object(ocrsubs.shutil, "which", return_value="/usr/bin/swiftc"):
            run.side_effect = lambda cmd, **kw: (Path(cmd[cmd.index("-o") + 1]).write_bytes(b"y"),
                                                 mock.Mock(returncode=0))[1]
            target = ocrsubs.helper_path()
        self.assertEqual([p.name for p in bin_dir.glob("jancast-ocr-*")], [target.name])
