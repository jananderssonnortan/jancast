"""media.py: ffmpeg command building, master rewriting, sidecars, progress parsing."""

import time
import unittest
from unittest import mock
from pathlib import Path

from helpers import (TempDirMixin, audio_stream, make_media, sub_stream, video_stream,
                     write_script)
from jancast import media
from jancast.media import Track, audio_plan, build_ffmpeg_cmd, write_master


def arg(cmd, flag, occurrence=0):
    """Value following the n-th occurrence of `flag`."""
    idx = [i for i, a in enumerate(cmd) if a == flag]
    return cmd[idx[occurrence] + 1]


# The separate, language-tagged audio rendition every command starts its map with.
AUDIO_MAP = "a:0,agroup:aud,language:en,name:audio,default:yes "


def maps(cmd):
    return [cmd[i + 1] for i, a in enumerate(cmd) if a == "-map"]


class OCRSubtitleTest(TempDirMixin, unittest.TestCase):
    def test_pgs_is_text_via_ocr_when_possible(self):
        pgs = Track("sub", 3, "hdmv_pgs_subtitle")
        dvd = Track("sub", 4, "dvd_subtitle")
        with mock.patch.object(media.shutil, "which", return_value="/usr/bin/swiftc"):
            self.assertTrue(pgs.via_ocr)
            self.assertFalse(pgs.burns_in)
            self.assertTrue(dvd.burns_in)           # only PGS can be read
        with mock.patch.object(media.shutil, "which", return_value=None):
            self.assertTrue(pgs.burns_in)

    def test_subtitle_delay_shifts_the_subtitle_file(self):
        d = self.make_tempdir()
        m = make_media(d, [video_stream(0), audio_stream(1)])
        sub = Track("sub", 0, "webvtt", file=d / "x.vtt")
        cmd = build_ffmpeg_cmd(m, m.audio[0], sub, d, sub_delay=-1.5)
        i = cmd.index(str(d / "x.vtt"))
        self.assertEqual(cmd[i - 3:i], ["-itsoffset", "-1.500", "-i"])
        self.assertNotIn("-itsoffset", build_ffmpeg_cmd(m, m.audio[0], sub, d))


class BuildCmdTest(TempDirMixin, unittest.TestCase):
    def setUp(self):
        self.dir = self.make_tempdir()
        self.out = self.dir / "out"

    def media(self, vcodec="h264", streams=(), **vextra):
        return make_media(self.dir, [video_stream(0, vcodec, **vextra), *streams])

    def test_h264_aac_copy(self):
        m = self.media(streams=[audio_stream(1, "aac", 2)])
        cmd = build_ffmpeg_cmd(m, m.audio[0], None, self.out)
        self.assertEqual(maps(cmd), ["0:0", "0:1"])
        self.assertEqual(arg(cmd, "-c:v"), "copy")
        self.assertEqual(arg(cmd, "-c:a"), "copy")
        self.assertNotIn("-filter_complex", cmd)
        self.assertNotIn("-tag:v", cmd)
        self.assertEqual(arg(cmd, "-var_stream_map"), AUDIO_MAP + "v:0,agroup:aud,name:video")
        self.assertEqual(arg(cmd, "-hls_fmp4_init_filename"), "init_%v.mp4")
        self.assertEqual(cmd.count("-i"), 1)
        self.assertEqual(arg(cmd, "-progress"), "pipe:1")
        self.assertEqual(arg(cmd, "-hls_segment_filename"), str(self.out / "seg_%v_%05d.m4s"))
        self.assertEqual(cmd[-1], str(self.out / "stream_%v.m3u8"))
        self.assertEqual(arg(cmd, "-hls_segment_type"), "fmp4")
        self.assertEqual(arg(cmd, "-hls_time"), str(media.SEGMENT_SECONDS))

    def test_hevc_copy_tags_hvc1(self):
        m = self.media("hevc", [audio_stream(1, "eac3", 6)])
        self.assertEqual(m.video_plan(None), ("copy", None))
        cmd = build_ffmpeg_cmd(m, m.audio[0], None, self.out)
        self.assertEqual(arg(cmd, "-c:v"), "copy")
        self.assertEqual(arg(cmd, "-tag:v"), "hvc1")
        self.assertEqual(arg(cmd, "-c:a"), "copy")

    def test_av1_and_vp9_reencode_with_videotoolbox(self):
        for codec in ("av1", "vp9"):
            with self.subTest(codec=codec):
                m = self.media(codec, [audio_stream(1)])
                mode, reason = m.video_plan(None)
                self.assertEqual(mode, "reencode")
                self.assertIn(codec.upper(), reason)
                cmd = build_ffmpeg_cmd(m, m.audio[0], None, self.out, quality=55)
                self.assertEqual(arg(cmd, "-filter_complex"), "[0:0]null,format=yuv420p[v]")
                self.assertEqual(maps(cmd)[0], "[v]")
                self.assertEqual(arg(cmd, "-c:v"), "h264_videotoolbox")
                self.assertEqual(arg(cmd, "-q:v"), "55")
                self.assertIn("expr:gte(t,n_forced*6)", cmd)

    @mock.patch("jancast.media.shutil.which", return_value=None)     # no OCR: burn in
    def test_pgs_burn_in_same_size(self, _which):
        m = self.media(streams=[audio_stream(1),
                                sub_stream(2, "hdmv_pgs_subtitle", width=1920, height=1080)])
        sub = m.subs[0]
        self.assertTrue(sub.is_bitmap)
        cmd = build_ffmpeg_cmd(m, m.audio[0], sub, self.out)
        self.assertEqual(arg(cmd, "-filter_complex"),
                         "[0:0][0:2]overlay=eof_action=pass,format=yuv420p[v]")
        self.assertEqual(maps(cmd), ["[v]", "0:1"])         # sub not mapped as a stream
        self.assertNotIn("-c:s", cmd)
        self.assertEqual(arg(cmd, "-var_stream_map"), AUDIO_MAP + "v:0,agroup:aud,name:video")
        self.assertEqual(arg(cmd, "-c:v"), "h264_videotoolbox")

    @mock.patch("jancast.media.shutil.which", return_value=None)     # no OCR: burn in
    def test_pgs_burn_in_size_mismatch_scales(self, _which):
        m = self.media(streams=[audio_stream(1),
                                sub_stream(2, "hdmv_pgs_subtitle", width=1920, height=1080)],
                       width=3840, height=2160)
        cmd = build_ffmpeg_cmd(m, m.audio[0], m.subs[0], self.out)
        self.assertEqual(arg(cmd, "-filter_complex"),
                         "[0:2]scale=3840:2160[subs];[0:0][subs]overlay=eof_action=pass,"
                         "format=yuv420p[v]")
        self.assertEqual(maps(cmd), ["[v]", "0:1"])

    @mock.patch("jancast.media.shutil.which", return_value=None)     # no OCR: burn in
    def test_pgs_burn_in_on_hevc_uses_hevc_encoder(self, _which):
        m = self.media("hevc", [audio_stream(1), sub_stream(2, "hdmv_pgs_subtitle")])
        cmd = build_ffmpeg_cmd(m, m.audio[0], m.subs[0], self.out)
        self.assertEqual(arg(cmd, "-filter_complex"), "[0:0][0:2]overlay=eof_action=pass[v]")
        self.assertEqual(arg(cmd, "-c:v"), "hevc_videotoolbox")
        self.assertEqual(arg(cmd, "-tag:v"), "hvc1")

    def test_text_sub_soft(self):
        m = self.media(streams=[audio_stream(1), sub_stream(2, "subrip")])
        cmd = build_ffmpeg_cmd(m, m.audio[0], m.subs[0], self.out)
        self.assertEqual(maps(cmd), ["0:0", "0:1", "0:2"])
        self.assertEqual(arg(cmd, "-c:s"), "webvtt")
        self.assertEqual(arg(cmd, "-var_stream_map"),
                         AUDIO_MAP + "v:0,s:0,agroup:aud,sgroup:subs,name:video")
        self.assertEqual(arg(cmd, "-c:v"), "copy")

    def test_external_srt_sidecar(self):
        (self.dir / "movie.en.srt").write_text("1\n00:00:01,000 --> 00:00:02,000\nhi\n")
        m = self.media(streams=[audio_stream(1)])
        self.assertEqual(len(m.subs), 1)
        sub = m.subs[0]
        cmd = build_ffmpeg_cmd(m, m.audio[0], sub, self.out)
        self.assertEqual(cmd.count("-i"), 2)
        self.assertEqual(arg(cmd, "-i", 1), str(sub.file))
        self.assertEqual(maps(cmd), ["0:0", "0:1", "1:0"])
        self.assertEqual(arg(cmd, "-var_stream_map"),
                         AUDIO_MAP + "v:0,s:0,agroup:aud,sgroup:subs,name:video")

    def test_audio_rendition_language_is_bcp47(self):
        cases = {"swe": "sv", "ENG": "en", "": "und", "tlh": "tlh"}
        for lang, expected in cases.items():
            with self.subTest(lang=lang):
                m = self.media(streams=[audio_stream(1, lang=lang)])
                stream_map = arg(build_ffmpeg_cmd(m, m.audio[0], None, self.out),
                                 "-var_stream_map")
                self.assertEqual(stream_map.split(" ")[0],
                                 f"a:0,agroup:aud,language:{expected},name:audio,default:yes")

    def test_stereo_downmix(self):
        m = self.media(streams=[audio_stream(1, "eac3", 6)])
        cmd = build_ffmpeg_cmd(m, m.audio[0], None, self.out, stereo=True)
        self.assertEqual(arg(cmd, "-c:a"), "aac")
        self.assertEqual(arg(cmd, "-ac"), "2")

    def test_audio_plans(self):
        cases = [
            # (codec, channels, stereo) -> (mode, out, -ac, -b:a)
            (("dts", 6, False), ("transcode", "eac3", "6", "640k")),
            (("truehd", 8, False), ("transcode", "eac3", "6", "640k")),
            (("flac", 2, False), ("transcode", "aac", "2", "192k")),
            (("opus", 1, False), ("transcode", "aac", "2", "192k")),
            (("ac3", 6, False), ("copy", "ac3", None, None)),
            (("aac", 2, True), ("transcode", "aac", "2", "192k")),
        ]
        for (codec, ch, stereo), (mode, out, ac, br) in cases:
            with self.subTest(codec=codec, ch=ch, stereo=stereo):
                m, o, args = audio_plan(Track("audio", 1, codec, channels=ch), stereo)
                self.assertEqual((m, o), (mode, out))
                if ac:
                    self.assertEqual(args[args.index("-ac") + 1], ac)
                    self.assertEqual(args[args.index("-b:a") + 1], br)
                    self.assertEqual(args[args.index("-c:a") + 1], out)
                else:
                    self.assertEqual(args, ["-c:a", "copy"])

    def test_dts_51_cmd(self):
        m = self.media(streams=[audio_stream(1, "aac", 2), audio_stream(2, "dts", 6)])
        cmd = build_ffmpeg_cmd(m, m.audio[1], None, self.out)
        self.assertEqual(maps(cmd), ["0:0", "0:2"])
        self.assertEqual(arg(cmd, "-c:a"), "eac3")
        self.assertEqual(arg(cmd, "-b:a"), "640k")

    def test_defaults(self):
        m = self.media(streams=[audio_stream(1), audio_stream(2, default=True),
                                sub_stream(3), sub_stream(4, forced=True)])
        self.assertEqual(m.default_audio, 2)
        self.assertEqual(m.default_sub, 2)

    def test_no_audio_or_video_raises(self):
        with self.assertRaises(media.MediaError):
            make_media(self.dir, [video_stream(0)])
        with self.assertRaises(media.MediaError):
            make_media(self.dir, [audio_stream(0)])

    def test_attached_pic_is_not_the_video(self):
        m = make_media(self.dir, [
            {**video_stream(0, "mjpeg"), "disposition": {"attached_pic": 1}},
            video_stream(1, "h264"), audio_stream(2)])
        self.assertEqual(m.video["index"], 1)


class WriteMasterTest(TempDirMixin, unittest.TestCase):
    # What ffmpeg writes for our var_stream_map (separate audio rendition + subs).
    FFMASTER = ('#EXTM3U\n#EXT-X-VERSION:7\n'
                '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="group_aud",NAME="audio_0",DEFAULT=YES,'
                'LANGUAGE="sv",CHANNELS="2",URI="stream_audio.m3u8"\n'
                '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="subtitle_1",DEFAULT=NO,'
                'URI="stream_video_vtt.m3u8"\n'
                '#EXT-X-STREAM-INF:BANDWIDTH=774947,CODECS="avc1.42c00c,mp4a.40.2",'
                'AUDIO="group_aud",SUBTITLES="subs"\nstream_video.m3u8\n')

    def setUp(self):
        self.dir = self.make_tempdir()

    def master(self, audio, sub, ffmaster=None):
        (self.dir / "ffmaster.m3u8").write_text(ffmaster or self.FFMASTER)
        write_master(self.dir, audio, sub)
        return (self.dir / "master.m3u8").read_text().splitlines()

    def test_variant_written_while_ffmpeg_is_still_running(self):
        # Early on ffmpeg's master has only the audio rendition (no variant yet).
        early = self.FFMASTER.split("#EXT-X-MEDIA:TYPE=SUBTITLES")[0]
        media = make_media(self.dir, [video_stream(0, width=1920, height=800), audio_stream(1)],
                           duration=100.0, content=b"x" * 12_500_000)   # 1 Mbit/s
        audio = media.audio[0]
        sub = Track("sub", 2, "subrip", lang="eng")
        (self.dir / "ffmaster.m3u8").write_text(early)
        write_master(self.dir, audio, sub, media)
        lines = (self.dir / "master.m3u8").read_text().splitlines()
        inf = [line for line in lines if line.startswith("#EXT-X-STREAM-INF")]
        self.assertEqual(inf, ['#EXT-X-STREAM-INF:BANDWIDTH=1500000,AVERAGE-BANDWIDTH=1000000,'
                               'RESOLUTION=1920x800,AUDIO="group_aud",SUBTITLES="subs"'])
        self.assertEqual(lines[lines.index(inf[0]) + 1], "stream_video.m3u8")
        subs = [line for line in lines if line.startswith("#EXT-X-MEDIA:TYPE=SUBTITLES")]
        self.assertEqual(len(subs), 1)
        self.assertIn('URI="stream_video_vtt.m3u8"', subs[0])
        # Without subtitles: no SUBTITLES group.
        (self.dir / "ffmaster.m3u8").write_text(early)
        write_master(self.dir, audio, None, media)
        self.assertNotIn("SUBTITLES", (self.dir / "master.m3u8").read_text())

    def test_names_the_file_in_session_data(self):
        audio = Track("audio", 1, "aac", lang="swe")
        (self.dir / "ffmaster.m3u8").write_text(self.FFMASTER)
        path = self.dir / "Harbour Lights (2010) - S03E03 - '90 - Autumn (1080p).mkv"
        write_master(self.dir, audio, None, path=path)
        lines = (self.dir / "master.m3u8").read_text().splitlines()
        self.assertEqual([line for line in lines if line.startswith("#EXT-X-SESSION-DATA")], [
            '#EXT-X-SESSION-DATA:DATA-ID="com.apple.hls.title",VALUE="Harbour Lights S3 · E3"',
            '#EXT-X-SESSION-DATA:DATA-ID="com.apple.hls.description",VALUE="\'90 - Autumn"',
        ])
        self.assertLess(lines.index("#EXT-X-START:TIME-OFFSET=0"),
                        next(i for i, line in enumerate(lines) if "SESSION-DATA" in line))
        # Without a file: no session data.
        write_master(self.dir, audio, None)
        self.assertNotIn("SESSION-DATA", (self.dir / "master.m3u8").read_text())

    def test_inserts_start_and_rewrites_renditions(self):
        audio = Track("audio", 1, "aac", lang="swe")
        sub = Track("sub", 2, "subrip", lang="eng", title='English "SDH"')
        lines = self.master(audio, sub)
        self.assertEqual(lines[1], "#EXT-X-VERSION:7")
        self.assertEqual(lines[2], "#EXT-X-START:TIME-OFFSET=0")
        self.assertEqual(lines[3],
                         '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="group_aud",NAME="swe",DEFAULT=YES,'
                         'AUTOSELECT=YES,LANGUAGE="sv",CHANNELS="2",URI="stream_audio.m3u8"')
        # Subtitles are tagged with the audio's (BCP 47) language so AVPlayer
        # auto-shows them as FORCED; NAME keeps the real one.
        self.assertEqual(lines[4],
                         '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English \'SDH\'",'
                         'LANGUAGE="sv",DEFAULT=YES,AUTOSELECT=YES,FORCED=YES,'
                         'URI="stream_video_vtt.m3u8"')
        self.assertEqual(lines[5:], ['#EXT-X-STREAM-INF:BANDWIDTH=774947,'
                                     'CODECS="avc1.42c00c,mp4a.40.2",AUDIO="group_aud",'
                                     'SUBTITLES="subs"', "stream_video.m3u8"])
        self.assertEqual(sum(1 for l in lines if l.startswith("#EXT-X-START")), 1)
        self.assertFalse((self.dir / "master.m3u8.tmp").exists())

    def test_audio_rendition_name(self):
        cases = [(Track("audio", 1, "aac", lang="eng", title='Director "cut"'),
                  "Director 'cut'"),
                 (Track("audio", 1, "aac", lang="eng"), "eng"),
                 (Track("audio", 1, "aac"), "Audio")]
        for audio, name in cases:
            with self.subTest(name=name):
                line = next(l for l in self.master(audio, None)
                            if l.startswith("#EXT-X-MEDIA:TYPE=AUDIO"))
                self.assertIn(f'NAME="{name}",DEFAULT=YES,AUTOSELECT=YES,', line)
                self.assertNotIn("audio_0", line)
                self.assertIn('LANGUAGE="sv"', line)       # ffmpeg's tag is kept
                self.assertEqual(line.count('"') % 2, 0)

    def test_audio_autoselect_not_duplicated(self):
        ffmaster = ('#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",'
                    'NAME="audio_0",DEFAULT=YES,AUTOSELECT=YES,URI="stream_audio.m3u8"\n'
                    '#EXT-X-STREAM-INF:BANDWIDTH=1,CODECS="avc1.640028,mp4a.40.2",AUDIO="a"\n'
                    'stream_video.m3u8\n')
        line = self.master(Track("audio", 1, "aac", lang="eng"), None, ffmaster)[3]
        self.assertEqual(line.count("AUTOSELECT=YES"), 1)
        self.assertIn('NAME="eng"', line)

    def test_subtitle_name_and_language_fall_back(self):
        text = "\n".join(self.master(Track("audio", 1, "aac"), Track("sub", 2, "subrip")))
        self.assertIn('NAME="Subtitles",LANGUAGE="und"', text)
        # No audio language: the subtitle's own, converted to BCP 47.
        text = "\n".join(self.master(Track("audio", 1, "aac"),
                                     Track("sub", 2, "subrip", lang="swe")))
        self.assertIn('NAME="swe",LANGUAGE="sv"', text)

    def test_without_subs_only_adds_start(self):
        plain = ('#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-STREAM-INF:BANDWIDTH=1\nstream_video.m3u8\n')
        self.master(Track("audio", 1, "aac"), None, plain)
        self.assertEqual((self.dir / "master.m3u8").read_text(),
                         '#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-START:TIME-OFFSET=0\n'
                         '#EXT-X-STREAM-INF:BANDWIDTH=1\nstream_video.m3u8\n')


class Bcp47Test(unittest.TestCase):
    def test_bcp47(self):
        cases = {"eng": "en", "swe": "sv", "ger": "de", "deu": "de", "fre": "fr",
                 "ENG": "en", " swe ": "sv", "en": "en", "sv": "sv",   # already BCP 47
                 "tlh": "tlh",                                       # no 2-letter code
                 "": "und", None: "und", "  ": "und", '"': "und", 'e"ng': "en"}
        for lang, expected in cases.items():
            with self.subTest(lang=lang):
                self.assertEqual(media.bcp47(lang), expected)


class CodecsFromInitTest(TempDirMixin, unittest.TestCase):
    @staticmethod
    def box(fourcc, payload):
        return (8 + len(payload)).to_bytes(4, "big") + fourcc + payload

    def esds(self, asc):
        dec_specific = b"\x05" + bytes([len(asc)]) + asc
        dec_config = b"\x04" + bytes([13 + len(dec_specific)]) + b"\x40\x15" + bytes(11) \
            + dec_specific
        es = b"\x03" + bytes([3 + len(dec_config)]) + b"\x00\x01\x00" + dec_config
        return self.box(b"esds", bytes(4) + es)

    def write(self, *boxes):
        path = self.make_tempdir() / "init.mp4"
        path.write_bytes(b"".join(boxes))
        return path

    def test_hevc_main10_and_he_aac(self):
        # Main10, main tier, level 5.1 (153), progressive+frame-only constraints.
        hvcc = bytes([1, 0x02, 0x20, 0, 0, 0, 0xB0, 0, 0, 0, 0, 0, 153]) + bytes(10)
        path = self.write(self.box(b"hvcC", hvcc), self.esds(bytes([0x2B, 0x92, 0x08, 0x00])))
        self.assertEqual(media.codecs_from_init(path), "hvc1.2.4.L153.B0,mp4a.40.5")

    def test_high_tier_and_profile_space(self):
        hvcc = bytes([1, (1 << 6) | (1 << 5) | 1, 0x60, 0, 0, 0, 0x90, 0, 0, 0, 0, 0x01, 120])
        path = self.write(self.box(b"hvcC", hvcc), self.box(b"dec3", b"\x00\x00\x00"))
        self.assertEqual(media.codecs_from_init(path), "hvc1.A1.6.H120.90.0.0.0.0.1,ec-3")

    def test_unknown_or_garbage_gives_none(self):
        self.assertIsNone(media.codecs_from_init(self.make_tempdir() / "missing.mp4"))
        self.assertIsNone(media.codecs_from_init(self.write(b"garbage hvcC esds")))
        hvcc = bytes([1, 1, 0x60, 0, 0, 0, 0x90, 0, 0, 0, 0, 0, 93])
        # Video known but audio unknown: leave CODECS out rather than guess.
        self.assertIsNone(media.codecs_from_init(self.write(self.box(b"hvcC", hvcc))))
        truncated = self.box(b"esds", bytes(4) + b"\x03\x80")
        self.assertIsNone(media.codecs_from_init(
            self.write(self.box(b"hvcC", hvcc), truncated)))

    def test_codecs_from_video_and_audio_init(self):
        """The video and audio renditions have separate init segments."""
        d = self.make_tempdir()
        hvcc = bytes([1, 1, 0x60, 0, 0, 0, 0x90, 0, 0, 0, 0, 0, 93])
        (d / "init_video.mp4").write_bytes(self.box(b"hvcC", hvcc))
        (d / "init_audio.mp4").write_bytes(self.esds(bytes([0x11, 0x90])))
        self.assertEqual(media.codecs_from_init(d / "init_video.mp4", d / "init_audio.mp4"),
                         "hvc1.1.6.L93.90,mp4a.40.2")
        # Video alone has no audio codec; a missing init gives None.
        self.assertIsNone(media.codecs_from_init(d / "init_video.mp4"))
        self.assertIsNone(media.codecs_from_init(d / "init_video.mp4", d / "missing.mp4"))
        self.assertIsNone(media.codecs_from_init())

    def test_write_master_adds_missing_codecs_only(self):
        d = self.make_tempdir()
        hvcc = bytes([1, 1, 0x60, 0, 0, 0, 0x90, 0, 0, 0, 0, 0, 93])
        (d / media.VIDEO_INIT).write_bytes(self.box(b"hvcC", hvcc))
        (d / media.AUDIO_INIT).write_bytes(self.box(b"dac3", b"\x00" * 3))
        (d / "ffmaster.m3u8").write_text(
            "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-STREAM-INF:BANDWIDTH=1,RESOLUTION=1x1,"
            'AUDIO="group_aud"\nstream_video.m3u8\n')
        write_master(d, Track("audio", 1, "ac3"), None)
        self.assertIn('#EXT-X-STREAM-INF:BANDWIDTH=1,RESOLUTION=1x1,AUDIO="group_aud",'
                      'CODECS="hvc1.1.6.L93.90,ac-3"', (d / "master.m3u8").read_text())
        (d / "ffmaster.m3u8").write_text(
            '#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-STREAM-INF:BANDWIDTH=1,CODECS="avc1.640028,ec-3"\n'
            "stream_video.m3u8\n")
        write_master(d, Track("audio", 1, "ac3"), None)
        self.assertEqual((d / "master.m3u8").read_text().count("CODECS="), 1)


class SidecarTest(TempDirMixin, unittest.TestCase):
    def test_language_parsing(self):
        d = self.make_tempdir()
        video = d / "movie.mkv"
        video.write_bytes(b"")
        for n in ("movie.srt", "movie.en.srt", "movie.sv.forced.ass", "movie.vtt",
                  "movie.nfo", "other.srt"):
            (d / n).write_text("")
        got = {(t.file.name, t.lang, t.codec) for t in media.find_sidecar_subs(video)}
        self.assertEqual(got, {("movie.srt", "", "subrip"), ("movie.en.srt", "en", "subrip"),
                               ("movie.sv.forced.ass", "sv.forced", "ass"),
                               ("movie.vtt", "", "webvtt")})
        for t in media.find_sidecar_subs(video):
            self.assertEqual((t.kind, t.index), ("sub", 0))
            self.assertIn(f"file {t.file.name}", t.label())

    def test_other_episode_with_same_prefix_not_matched(self):
        # Regression: "show.s01e1.mkv" used to pick up "show.s01e10.srt" (lang "0")
        # and "movie.mkv" picked up "movie2.srt" / "movie-extras.srt".
        d = self.make_tempdir()
        for n in ("show.s01e1.mkv", "show.s01e10.srt", "show.s01e1.en.srt",
                  "movie.mkv", "movie2.srt", "movie-extras.srt", "Movie.srt"):
            (d / n).write_text("")
        self.assertEqual([t.file.name for t in media.find_sidecar_subs(d / "show.s01e1.mkv")],
                         ["show.s01e1.en.srt"])
        self.assertEqual([t.file.name for t in media.find_sidecar_subs(d / "movie.mkv")], [])


FAKE_FFMPEG = r'''
import sys, time
out, err = sys.stdout, sys.stderr
def p(*lines):
    for l in lines:
        out.write(l + "\n")
    out.flush()
p("out_time_us=-9223372036854775807", "speed=N/A", "progress=continue")
err.write("[aac @ 0x1] codec frame size is not set\n"); err.flush()
p("out_time_us=N/A", "speed=N/A", "progress=continue")
p("frame=10", "out_time_us=5000000", "out_time=00:00:05.000000", "speed=   2.5x",
  "progress=continue")
err.write("[matroska @ 0x2] Invalid data found when processing input\n\n"); err.flush()
p("out_time_us=garbage", "speed=fastx")
time.sleep(0.4)
p("out_time_us=8000000", "speed=1.9x", "progress=continue")
time.sleep(float(sys.argv[1]) if len(sys.argv) > 1 else 0)
p("out_time_us=9500000", "speed=2x", "progress=end")
sys.exit(int(sys.argv[2]) if len(sys.argv) > 2 else 0)
'''


class TranscoderTest(TempDirMixin, unittest.TestCase):
    def setUp(self):
        self.cmd = write_script(self.make_tempdir(), FAKE_FFMPEG)

    def test_progress_and_warnings(self):
        warnings = []
        tc = media.Transcoder(self.cmd, 10.0, on_warning=warnings.append)
        seen = []
        while not tc.done:
            seen.append((tc.prepared_s, tc.progress, tc.speed))
            time.sleep(0.02)
        tc.wait()
        self.assertTrue(all(p >= 0 for p, _, _ in seen), "prepared_s went negative")
        self.assertIn((5.0, 0.5, 2.5), seen)
        self.assertEqual(tc.progress, 1.0)
        self.assertEqual(tc.prepared_s, 10.0)          # end -> full duration
        self.assertEqual(tc.speed, 2.0)
        self.assertFalse(tc.failed)
        self.assertEqual(warnings, ["[matroska @ 0x2] Invalid data found when processing input"])
        self.assertEqual(len(tc.stderr_tail), 2)       # ignored lines still kept in the tail

    def test_failed_exit(self):
        tc = media.Transcoder(self.cmd + ["0", "1"], 10.0)
        tc.wait()
        self.assertTrue(tc.done)
        self.assertTrue(tc.failed)

    def test_zero_duration_no_division(self):
        tc = media.Transcoder(self.cmd, 0)
        tc.wait()
        self.assertEqual(tc.progress, 1.0)
        self.assertEqual(tc.prepared_s, 9.5)

    def test_stop_is_not_failure(self):
        # Regression: stop() -> SIGTERM -> returncode -15 was reported as an ffmpeg
        # failure (prep.error set, diagnosis blamed the encoder after a user stop).
        tc = media.Transcoder(self.cmd + ["30"], 10.0)
        time.sleep(0.2)
        self.assertFalse(tc.done)
        tc.stop()
        self.assertTrue(tc.done)
        self.assertNotEqual(tc.proc.returncode, 0)
        self.assertFalse(tc.failed)

    def test_raising_warning_callback_does_not_block_ffmpeg(self):
        # Regression: an exception in on_warning killed the stderr reader thread;
        # ffmpeg would then block forever once the stderr pipe filled up.
        cmd = write_script(self.make_tempdir(), (
            "import sys\n"
            "for i in range(20000):\n"
            "    sys.stderr.write('warning line %d padding padding padding\\n' % i)\n"
            "print('progress=end')\n"))

        def boom(line):
            raise RuntimeError("callback bug")

        tc = media.Transcoder(cmd, 1.0, on_warning=boom)
        deadline = time.time() + 10
        while not tc.done and time.time() < deadline:
            time.sleep(0.05)
        self.assertTrue(tc.done, "child blocked on a full stderr pipe")
        tc.wait()
        self.assertEqual(tc.progress, 1.0)


class SegmentDurationsTest(TempDirMixin, unittest.TestCase):
    def test_read(self):
        d = self.make_tempdir()
        self.assertEqual(media.read_segment_durations(d), [])
        # Only the video playlist counts; the audio rendition's EXTINFs differ.
        (d / media.AUDIO_PLAYLIST).write_text("#EXTM3U\n#EXTINF:6.0158,\na\n")
        self.assertEqual(media.read_segment_durations(d), [])
        (d / media.VIDEO_PLAYLIST).write_text(
            "#EXTM3U\n#EXTINF:6.000000,\na\n#EXTINF:2.5,\nb\n")
        self.assertEqual(media.read_segment_durations(d), [6.0, 2.5])


if __name__ == "__main__":
    unittest.main()


class ExtractTextSubtitlesTest(TempDirMixin, unittest.TestCase):
    def test_second_call_uses_the_cache(self):
        d = self.make_tempdir()
        m = make_media(d, [video_stream(0), audio_stream(1), sub_stream(2)])

        def fake_ffmpeg(cmd, **kw):
            Path(cmd[-1]).write_text("WEBVTT\n")
            return mock.Mock(returncode=0)
        with mock.patch("jancast.media.subprocess.run", side_effect=fake_ffmpeg) as run:
            first = media.extract_text_subtitles(m, m.subs[0])
            second = media.extract_text_subtitles(m, m.subs[0])
        self.assertEqual(first, second)
        self.assertEqual(run.call_count, 1)
