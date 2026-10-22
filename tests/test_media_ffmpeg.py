"""End-to-end with the real ffmpeg: generate tiny clips, probe, remux to HLS.

Slow-ish (a few seconds). Skip with JANCAST_SKIP_SLOW=1.
"""

import re
import subprocess
import unittest

from helpers import HAVE_FFMPEG, SLOW, TempDirMixin
from jancast import media

SRT = ('1\n00:00:01,000 --> 00:00:04,000\nHello "world"\n\n'
       '2\n00:00:08,000 --> 00:00:12,000\nSecond line\n')


def ffmpeg(*args):
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *args],
                   check=True, capture_output=True)


def make_clip(directory, vcodec_args, name="clip.mkv", seconds=20, embed_sub=True):
    srt = directory / "src.srt"
    srt.write_text(SRT)
    out = directory / name
    args = ["-f", "lavfi", "-i", "testsrc2=size=320x180:rate=25",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000"]
    if embed_sub:
        args += ["-i", str(srt)]
    args += ["-t", str(seconds), "-map", "0:v", "-map", "1:a"]
    if embed_sub:
        args += ["-map", "2:s", "-c:s", "srt", "-metadata:s:s:0", "language=eng",
                 "-metadata:s:s:0", 'title=English "SDH"']
    args += [*vcodec_args, "-g", "50", "-c:a", "aac", "-metadata:s:a:0", "language=swe",
             str(out)]
    ffmpeg(*args)
    srt.unlink()
    return out


def run_pipeline(test, clip, sub_choice):
    m = media.probe(clip)
    out = test.make_tempdir()
    sub = sub_choice(m)
    cmd = media.build_ffmpeg_cmd(m, m.audio[0], sub, out)
    warnings = []
    tc = media.Transcoder(cmd, m.duration, on_warning=warnings.append)
    tc.wait()
    test.assertFalse(tc.failed, tc.stderr_tail)
    test.assertEqual(tc.progress, 1.0)
    test.assertGreater(tc.speed or 0, 0)
    test.assertAlmostEqual(tc.prepared_s, m.duration, delta=0.5)
    test.assertEqual(warnings, [], "unexpected (non-ignored) ffmpeg warnings")
    media.write_master(out, m.audio[0], sub)
    return m, out, sub


@SLOW
@unittest.skipUnless(HAVE_FFMPEG, "ffmpeg not installed")
class RealFfmpegTest(TempDirMixin, unittest.TestCase):
    def check_rendition(self, out, name, init, total, min_segments):
        names = {p.name for p in out.iterdir()}
        self.assertIn(init, names)
        segs = sorted(n for n in names if re.fullmatch(rf"seg_{name}_\d{{5}}\.m4s", n))
        self.assertGreaterEqual(len(segs), min_segments)
        playlist = (out / f"stream_{name}.m3u8").read_text()
        self.assertIn("#EXT-X-ENDLIST", playlist)
        self.assertIn(f'#EXT-X-MAP:URI="{init}"', playlist)
        self.assertEqual(segs, re.findall(r"^seg_\w+\.m4s$", playlist, re.M))
        durations = [float(d) for d in re.findall(r"#EXTINF:([\d.]+)", playlist)]
        self.assertAlmostEqual(sum(durations), total, delta=0.5)
        return segs

    def check_video_output(self, out, total=20.0, min_segments=3):
        """Video and audio are separate renditions, each with its own init."""
        names = {p.name for p in out.iterdir()}
        self.assertFalse([n for n in names if n.endswith(".tmp")])
        self.assertNotIn("init.mp4", names)
        segs = self.check_rendition(out, "video", media.VIDEO_INIT, total, min_segments)
        self.assertEqual(len(media.read_segment_durations(out)), len(segs))
        self.check_rendition(out, "audio", media.AUDIO_INIT, total, min_segments)
        from jancast.hls_server import classify
        self.assertEqual(classify("/" + segs[1]), ("segment", 1))
        self.assertEqual(classify("/seg_audio_00001.m4s"), ("audio", 1))
        self.assertEqual(classify("/" + media.VIDEO_INIT), ("init", None))
        self.assertEqual(classify("/" + media.AUDIO_INIT), ("init", None))
        # The video init holds no audio track and vice versa.
        self.assertNotIn(b"esds", (out / media.VIDEO_INIT).read_bytes())
        self.assertNotIn(b"avcC", (out / media.AUDIO_INIT).read_bytes())
        self.assertNotIn(b"hvcC", (out / media.AUDIO_INIT).read_bytes())
        return names

    def check_master(self, out, with_subs, audio_name="swe", audio_lang="sv"):
        lines = (out / "master.m3u8").read_text().splitlines()
        self.assertEqual(lines[0], "#EXTM3U")
        self.assertTrue(lines[1].startswith("#EXT-X-VERSION"))
        self.assertEqual(lines[2], "#EXT-X-START:TIME-OFFSET=0")
        inf = [l for l in lines if l.startswith("#EXT-X-STREAM-INF")]
        self.assertEqual(len(inf), 1)
        self.assertEqual(lines[lines.index(inf[0]) + 1], media.VIDEO_PLAYLIST)
        self.assertIn("CODECS=", inf[0])
        auds = [l for l in lines if l.startswith("#EXT-X-MEDIA:TYPE=AUDIO")]
        self.assertEqual(len(auds), 1)
        group = re.search(r'GROUP-ID="([^"]+)"', auds[0]).group(1)
        self.assertIn(f'AUDIO="{group}"', inf[0])
        self.assertIn(f'NAME="{audio_name}"', auds[0])
        self.assertIn(f'LANGUAGE="{audio_lang}"', auds[0])
        self.assertIn("DEFAULT=YES", auds[0])
        self.assertIn("AUTOSELECT=YES", auds[0])
        self.assertEqual(auds[0].count('"') % 2, 0)
        self.assertEqual(re.search(r'URI="([^"]+)"', auds[0]).group(1), media.AUDIO_PLAYLIST)
        subs = [l for l in lines if l.startswith("#EXT-X-MEDIA:TYPE=SUBTITLES")]
        if with_subs:
            self.assertEqual(len(subs), 1)
            self.assertIn('SUBTITLES="subs"', inf[0])
            self.assertIn('GROUP-ID="subs"', subs[0])
            self.assertIn("NAME=\"English 'SDH'\"", subs[0])
            self.assertIn(f'LANGUAGE="{audio_lang}"', subs[0])   # the audio's, BCP 47
            self.assertIn("AUTOSELECT=YES", subs[0])
            self.assertIn("FORCED=YES", subs[0])
            self.assertEqual(subs[0].count('"') % 2, 0)
            uri = re.search(r'URI="([^"]+)"', subs[0]).group(1)
            self.assertEqual(uri, media.SUBTITLE_PLAYLIST)
            self.assertTrue((out / uri).is_file())
        else:
            self.assertEqual(subs, [])
            self.assertNotIn("SUBTITLES=", inf[0])
        return inf[0]

    def test_h264_with_embedded_srt(self):
        clip = make_clip(self.make_tempdir(), ["-c:v", "libx264", "-preset", "ultrafast"])
        m = media.probe(clip)
        self.assertEqual(m.video_codec, "h264")
        self.assertAlmostEqual(m.duration, 20.0, delta=0.2)
        self.assertEqual([(t.codec, t.lang) for t in m.audio], [("aac", "swe")])
        self.assertEqual([(t.codec, t.lang, t.title) for t in m.subs],
                         [("subrip", "eng", 'English "SDH"')])
        m, out, sub = run_pipeline(self, clip, lambda m: m.subs[0])
        names = self.check_video_output(out)
        vtt_pl = (out / media.SUBTITLE_PLAYLIST).read_text()
        self.assertIn("#EXT-X-ENDLIST", vtt_pl)
        vtts = sorted((n for n in names if n.endswith(".vtt")),
                      key=lambda n: int(re.search(r"(\d+)\.vtt$", n).group(1)))
        self.assertTrue(vtts)
        self.assertEqual(vtts[0], "stream_video0.vtt")
        self.assertTrue(all(n in vtt_pl for n in vtts))
        # The HLS server must classify the real subtitle segment names.
        from jancast.hls_server import classify
        self.assertEqual([classify("/" + n) for n in vtts],
                         [("subtitle", i) for i in range(len(vtts))])
        self.assertIn("WEBVTT", (out / vtts[0]).read_text())
        self.assertIn("Hello", "".join((out / n).read_text() for n in vtts))
        inf = self.check_master(out, with_subs=True)
        self.assertIn("avc1", inf)

    def test_external_sidecar_srt(self):
        d = self.make_tempdir()
        clip = make_clip(d, ["-c:v", "libx264", "-preset", "ultrafast"], embed_sub=False)
        (d / "clip.en.srt").write_text(SRT)
        m, out, sub = run_pipeline(self, clip, lambda m: m.subs[0])
        self.assertEqual((sub.lang, sub.file.name), ("en", "clip.en.srt"))
        self.check_video_output(out)
        self.assertIn("#EXT-X-ENDLIST", (out / media.SUBTITLE_PLAYLIST).read_text())
        master = (out / "master.m3u8").read_text()
        self.assertIn('NAME="en"', master)
        sub_line = next(l for l in master.splitlines() if "TYPE=SUBTITLES" in l)
        self.assertIn('LANGUAGE="sv"', sub_line)          # audio language (swe)

    def test_hevc_copy_is_tagged_hvc1_and_has_codecs(self):
        # Regression: for copied HEVC ffmpeg writes no CODECS attribute at all
        # (it only does when it encodes); write_master now fills it in.
        for pix_fmt, prefix in (("yuv420p", "hvc1.1.6.L"), ("yuv420p10le", "hvc1.2.4.L")):
            with self.subTest(pix_fmt=pix_fmt):
                clip = make_clip(self.make_tempdir(),
                                 ["-c:v", "libx265", "-preset", "ultrafast", "-pix_fmt", pix_fmt,
                                  "-x265-params", "log-level=error"], embed_sub=False)
                m, out, _ = run_pipeline(self, clip, lambda m: None)
                self.assertEqual(m.video_codec, "hevc")
                self.check_video_output(out)
                self.assertNotIn("CODECS=", (out / "ffmaster.m3u8").read_text())
                inf = self.check_master(out, with_subs=False)
                codecs = re.search(r'CODECS="([^"]+)"', inf).group(1)
                self.assertTrue(codecs.startswith(prefix), codecs)
                self.assertTrue(codecs.endswith(",mp4a.40.2"), codecs)
                self.assertIn(b"hvc1", (out / media.VIDEO_INIT).read_bytes())
                # CODECS needs both inits: the video's hvcC and the audio's esds.
                self.assertEqual(codecs, media.codecs_from_init(out / media.VIDEO_INIT,
                                                                out / media.AUDIO_INIT))
                self.assertIsNone(media.codecs_from_init(out / media.VIDEO_INIT))

    def test_codecs_string_matches_ffmpeg(self):
        """Our init segment parser must produce exactly what ffmpeg writes when it
        can: for one init with both tracks, and for our layout (separate video
        and audio renditions, one init each)."""
        d = self.make_tempdir()
        src = make_clip(d, ["-c:v", "libx264", "-preset", "ultrafast"], seconds=4,
                        embed_sub=False)
        cases = {"h264_aac": ["-c:v", "copy", "-c:a", "copy"],
                 "h264_eac3": ["-c:v", "copy", "-c:a", "eac3", "-ac", "6"],
                 "h264_ac3": ["-c:v", "copy", "-c:a", "ac3"],
                 "hevc_enc": ["-c:v", "libx265", "-preset", "ultrafast", "-tag:v", "hvc1",
                              "-x265-params", "log-level=error", "-c:a", "copy"],
                 "hevc10_enc": ["-c:v", "libx265", "-preset", "ultrafast", "-tag:v", "hvc1",
                                "-pix_fmt", "yuv420p10le", "-x265-params", "log-level=error",
                                "-c:a", "copy"]}
        layouts = {"muxed": ("v:0,a:0", "init.mp4", lambda o: [o / "init.mp4"]),
                   "split": ("a:0,agroup:aud,name:audio,default:yes v:0,agroup:aud,name:video",
                             "init_%v.mp4",
                             lambda o: [o / media.VIDEO_INIT, o / media.AUDIO_INIT])}
        for name, codec_args in cases.items():
            for layout, (stream_map, init_name, inits) in layouts.items():
                with self.subTest(name, layout=layout):
                    out = d / f"{name}_{layout}"
                    out.mkdir()
                    ffmpeg("-i", str(src), "-map", "0:v", "-map", "0:a", *codec_args,
                           "-f", "hls", "-hls_time", "2", "-hls_segment_type", "fmp4",
                           "-hls_fmp4_init_filename", init_name, "-master_pl_name", "m.m3u8",
                           "-var_stream_map", stream_map,
                           "-hls_segment_filename", str(out / "seg_%v_%05d.m4s"),
                           str(out / "stream_%v.m3u8"))
                    expected = re.search(r'CODECS="([^"]+)"', (out / "m.m3u8").read_text())
                    self.assertIsNotNone(expected, "ffmpeg wrote no CODECS for " + name)
                    self.assertEqual(media.codecs_from_init(*inits(out)).lower(),
                                     expected.group(1).lower())

    def test_vp9_reencode_with_videotoolbox(self):
        clip = make_clip(self.make_tempdir(), ["-c:v", "libvpx-vp9", "-deadline", "realtime",
                                               "-cpu-used", "8", "-b:v", "300k"],
                         seconds=8, embed_sub=False)
        m = media.probe(clip)
        self.assertEqual(m.video_plan(None)[0], "reencode")
        out = self.make_tempdir()
        cmd = media.build_ffmpeg_cmd(m, m.audio[0], None, out)
        tc = media.Transcoder(cmd, m.duration)
        tc.wait()
        if tc.failed and any("videotoolbox" in l.lower() or "vt" in l.lower()
                             for l in tc.stderr_tail):
            self.skipTest("VideoToolbox encoder unavailable: " + " | ".join(tc.stderr_tail[-2:]))
        self.assertFalse(tc.failed, tc.stderr_tail)
        media.write_master(out, m.audio[0], None)
        self.check_video_output(out, total=8.0, min_segments=2)
        self.assertIn("avc1", self.check_master(out, with_subs=False))
        # -force_key_frames every 6 s -> segments of ~6 s each.
        durations = media.read_segment_durations(out)
        self.assertAlmostEqual(durations[0], 6.0, delta=0.1)

    def test_pgs_burn_in(self):
        self.skipTest("ffmpeg cannot encode PGS (no hdmv_pgs_subtitle encoder) and cannot "
                      "convert text subtitles to bitmap; burn-in is covered by the "
                      "command-builder tests")

    def test_probe_errors(self):
        d = self.make_tempdir()
        with self.assertRaises(media.MediaError):
            media.probe(d / "missing.mkv")
        bad = d / "bad.mkv"
        bad.write_bytes(b"not a video at all" * 10)
        with self.assertRaises(media.MediaError):
            media.probe(bad)


if __name__ == "__main__":
    unittest.main()
