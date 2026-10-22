"""Probing source files and turning them into HLS (fMP4) with ffmpeg."""

import hashlib
import json
import os
import re
import shutil
import subprocess
import threading
from pathlib import Path

from .config import cache_dir

# Codecs Apple TV plays natively from HLS fMP4, so they can be copied as-is.
COPY_VIDEO = {"h264", "hevc"}
COPY_AUDIO = {"aac", "ac3", "eac3"}
TEXT_SUBS = {"subrip", "ass", "ssa", "webvtt", "mov_text", "text"}
BITMAP_SUBS = {"hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle"}
OCR_SUBS = {"hdmv_pgs_subtitle"}          # picture subtitles ocrsubs.py can read as text
SIDECAR_EXTS = {".srt", ".ass", ".ssa", ".vtt"}
SEGMENT_SECONDS = 6

# HLS output layout (ffmpeg names files after the var_stream_map "name:" keys).
VIDEO_PLAYLIST = "stream_video.m3u8"     # segments seg_video_NNNNN.m4s
AUDIO_PLAYLIST = "stream_audio.m3u8"     # segments seg_audio_NNNNN.m4s
VIDEO_INIT = "init_video.mp4"
AUDIO_INIT = "init_audio.mp4"
SUBTITLE_PLAYLIST = "stream_video_vtt.m3u8"   # segments stream_videoN.vtt

# ffmpeg warnings that are harmless for our use and would only add noise.
IGNORED_FFMPEG_WARNINGS = ("codec frame size is not set",
                           "Bandwidth info not available")


class MediaError(Exception):
    pass


class Track:
    def __init__(self, kind, index, codec, lang="", title="", channels=0,
                 default=False, forced=False, width=0, height=0, file=None):
        self.kind = kind          # "audio" | "sub"
        self.index = index        # stream index within its input file
        self.codec = codec
        self.lang = lang
        self.title = title
        self.channels = channels
        self.default = default
        self.forced = forced
        self.width = width
        self.height = height
        self.file = file          # sidecar subtitle file, None if embedded

    @property
    def is_bitmap(self):
        return self.codec in BITMAP_SUBS

    @property
    def via_ocr(self):
        """Picture subtitles shown as text (recognised with macOS Vision)."""
        return self.codec in OCR_SUBS and shutil.which("swiftc") is not None

    @property
    def burns_in(self):
        """Picture subtitles that must be painted into the video (re-encode)."""
        return self.is_bitmap and not self.via_ocr

    def label(self):
        parts = [self.lang or "und"]
        if self.title:
            parts.append(self.title)
        info = self.codec + (f", {self.channels}ch" if self.channels else "")
        if self.file:
            info += f", file {self.file.name}"
        parts.append(f"({info})")
        return "  ".join(parts)


class MediaInfo:
    def __init__(self, path, probe):
        self.path = path
        self.size_bytes = path.stat().st_size
        self.duration = float(probe["format"].get("duration") or 0)
        self.video = None
        self.audio = []
        self.subs = []
        for s in probe["streams"]:
            tags = s.get("tags", {})
            disp = s.get("disposition", {})
            kind = s.get("codec_type")
            if kind == "video" and not disp.get("attached_pic") and self.video is None:
                self.video = s
            elif kind in ("audio", "subtitle"):
                t = Track(
                    "audio" if kind == "audio" else "sub", s["index"], s.get("codec_name", "?"),
                    lang=tags.get("language", ""), title=tags.get("title", ""),
                    channels=s.get("channels", 0), default=bool(disp.get("default")),
                    forced=bool(disp.get("forced")),
                    width=s.get("width", 0), height=s.get("height", 0),
                )
                (self.audio if kind == "audio" else self.subs).append(t)
        if self.video is None:
            raise MediaError("no video stream found")
        if not self.audio:
            raise MediaError("no audio stream found")
        self.subs += find_sidecar_subs(path)

    @property
    def video_codec(self):
        return self.video.get("codec_name", "?")

    @property
    def hdr(self):
        return self.video.get("color_transfer") in ("smpte2084", "arib-std-b67")

    def video_plan(self, sub):
        """("copy"|"reencode", reason) for the given subtitle choice."""
        if sub is not None and sub.burns_in:
            return "reencode", "image subtitles must be burned into the picture"
        if self.video_codec not in COPY_VIDEO:
            return "reencode", f"{self.video_codec.upper()} video is not supported by Apple TV"
        return "copy", None

    @property
    def default_audio(self):
        return next((i for i, t in enumerate(self.audio, 1) if t.default), 1)

    @property
    def default_sub(self):
        return next((i for i, t in enumerate(self.subs, 1) if t.forced), 0)


def audio_plan(track, stereo):
    """(mode, output codec, extra ffmpeg args)."""
    if stereo:
        return "transcode", "aac", ["-c:a", "aac", "-ac", "2", "-b:a", "192k"]
    if track.codec in COPY_AUDIO:
        return "copy", track.codec, ["-c:a", "copy"]
    if track.channels > 2:
        return "transcode", "eac3", ["-c:a", "eac3", "-ac", str(min(track.channels, 6)),
                                     "-b:a", "640k"]
    return "transcode", "aac", ["-c:a", "aac", "-ac", "2", "-b:a", "192k"]


def probe(path):
    path = Path(path).expanduser().resolve()
    if not path.is_file():
        raise MediaError(f"no such file: {path}")
    try:
        out = subprocess.run(
            ["ffprobe", "-v", "error", "-print_format", "json",
             "-show_format", "-show_streams", str(path)],
            capture_output=True, text=True,
        )
    except FileNotFoundError as e:
        raise MediaError("ffprobe not found - install ffmpeg with: brew install ffmpeg") from e
    if out.returncode != 0:
        raise MediaError(f"ffprobe failed: {out.stderr.strip()}")
    return MediaInfo(path, json.loads(out.stdout))


def extract_text_subtitles(media, sub):
    """An embedded text subtitle track as a WebVTT file (cached), so it can be
    shifted like a sidecar file."""
    st = media.path.stat()
    key = hashlib.sha1(f"{media.path}|{st.st_size}|{st.st_mtime}|{sub.index}".encode()).hexdigest()[:16]
    out = cache_dir() / "subs" / f"{key}.vtt"
    if out.exists():
        os.utime(out)               # recently used: kept by the cache trim
        return out
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = out.with_suffix(".tmp")
    r = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(media.path),
                        "-map", f"0:{sub.index}", "-c:s", "webvtt", "-f", "webvtt", str(tmp)],
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise MediaError("could not read the subtitle track: " + r.stderr.strip()[-200:])
    tmp.replace(out)
    return out


def find_sidecar_subs(path):
    """Subtitle files next to the video, e.g. movie.srt or movie.en.srt."""
    tracks = []
    for f in sorted(path.parent.iterdir()):
        # "movie.srt" or "movie.<lang...>.srt" - not "movie2.srt" or "movie-extras.srt".
        if f.suffix.lower() in SIDECAR_EXTS and (
                f.name == path.stem + f.suffix or f.name.startswith(path.stem + ".")):
            lang = f.name[len(path.stem):-len(f.suffix)].strip(".")
            codec = {".srt": "subrip", ".vtt": "webvtt"}.get(f.suffix.lower(), "ass")
            tracks.append(Track("sub", 0, codec, lang=lang, file=f))
    return tracks


def build_ffmpeg_cmd(media, audio, sub, outdir, stereo=False, quality=65, sub_delay=0.0):
    """`sub_delay` (seconds, + = later) shifts a subtitle file (`sub.file`)."""
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "warning", "-nostats",
           "-progress", "pipe:1", "-y", "-i", str(media.path)]
    if sub and sub.file:
        if sub_delay:
            cmd += ["-itsoffset", f"{sub_delay:.3f}"]
        cmd += ["-i", str(sub.file)]

    vidx = media.video["index"]
    vmode, _ = media.video_plan(sub)
    hevc = media.video_codec == "hevc"

    if vmode == "reencode":
        if sub is not None and sub.is_bitmap:
            w, h = media.video.get("width", 0), media.video.get("height", 0)
            if sub.width and (sub.width, sub.height) != (w, h):
                graph = (f"[0:{sub.index}]scale={w}:{h}[subs];"
                         f"[0:{vidx}][subs]overlay=eof_action=pass")
            else:
                graph = f"[0:{vidx}][0:{sub.index}]overlay=eof_action=pass"
        else:
            graph = f"[0:{vidx}]null"
        if not hevc:
            graph += ",format=yuv420p"
        cmd += ["-filter_complex", graph + "[v]", "-map", "[v]"]
        if hevc:
            cmd += ["-c:v", "hevc_videotoolbox", "-tag:v", "hvc1"]
        else:
            cmd += ["-c:v", "h264_videotoolbox", "-profile:v", "high"]
        cmd += ["-q:v", str(quality),
                "-force_key_frames", f"expr:gte(t,n_forced*{SEGMENT_SECONDS})"]
    else:
        cmd += ["-map", f"0:{vidx}", "-c:v", "copy"]
        if hevc:
            # Apple players require the hvc1 sample entry; keep Dolby Vision boxes.
            cmd += ["-tag:v", "hvc1", "-strict", "unofficial"]

    cmd += ["-map", f"0:{audio.index}"] + audio_plan(audio, stereo)[2]

    # Audio is its own rendition (not muxed into the video playlist) and tagged
    # with its language: AVPlayer only auto-selects the FORCED subtitles (see
    # write_master) when it knows the audio language. Verified on tvOS 26.
    lang = bcp47(audio.lang)
    video = "v:0,agroup:aud,name:video"
    if sub and not sub.is_bitmap:
        cmd += ["-map", "1:0" if sub.file else f"0:{sub.index}", "-c:s", "webvtt"]
        video = "v:0,s:0,agroup:aud,sgroup:subs,name:video"
    stream_map = f"a:0,agroup:aud,language:{lang},name:audio,default:yes {video}"

    cmd += [
        "-max_muxing_queue_size", "4096",
        "-f", "hls", "-hls_time", str(SEGMENT_SECONDS), "-hls_playlist_type", "event",
        "-hls_segment_type", "fmp4", "-hls_fmp4_init_filename", "init_%v.mp4",
        "-hls_flags", "independent_segments+temp_file",
        "-master_pl_name", "ffmaster.m3u8", "-var_stream_map", stream_map,
        "-hls_segment_filename", str(outdir / "seg_%v_%05d.m4s"),
        str(outdir / "stream_%v.m3u8"),
    ]
    return cmd


def _box(data, fourcc):
    """Payload of the first `fourcc` box in an MP4 byte string, or None."""
    i = data.find(fourcc)
    if i < 4:
        return None
    size = int.from_bytes(data[i - 4:i], "big")
    if size < 8 or i - 4 + size > len(data):
        return None
    return data[i + 4:i - 4 + size]


def _video_codec_string(data):
    if (c := _box(data, b"hvcC")) and len(c) >= 13 and c[0] == 1:
        # ISO/IEC 14496-15 annex E, e.g. "hvc1.2.4.L150.B0".
        space, tier, profile = c[1] >> 6, (c[1] >> 5) & 1, c[1] & 0x1F
        compat = int("{:032b}".format(int.from_bytes(c[2:6], "big"))[::-1], 2)
        constraints = list(c[6:12])
        while constraints and constraints[-1] == 0:
            constraints.pop()
        return ".".join(["hvc1", ("", "A", "B", "C")[space] + str(profile), f"{compat:X}",
                         ("L", "H")[tier] + str(c[12])] + [f"{b:X}" for b in constraints])
    if (c := _box(data, b"avcC")) and len(c) >= 4 and c[0] == 1:
        return f"avc1.{c[1]:02x}{c[2]:02x}{c[3]:02x}"
    return None


def _audio_codec_string(data):
    if _box(data, b"dec3") is not None:
        return "ec-3"
    if _box(data, b"dac3") is not None:
        return "ac-3"
    esds = _box(data, b"esds")
    if not esds:
        return None
    pos = 4                                    # version + flags

    def descriptor():
        nonlocal pos
        tag, length = esds[pos], 0
        pos += 1
        for _ in range(4):
            b = esds[pos]
            pos += 1
            length = (length << 7) | (b & 0x7F)
            if not b & 0x80:
                break
        return tag, length

    try:
        tag, _ = descriptor()
        if tag != 3:
            return None
        flags = esds[pos + 2]
        pos += 3 + (2 if flags & 0x80 else 0) + (2 if flags & 0x20 else 0)
        if flags & 0x40:
            pos += 1 + esds[pos]
        tag, _ = descriptor()
        if tag != 4:
            return None
        oti = esds[pos]
        pos += 13
        tag, _ = descriptor()
        if tag != 5 or oti != 0x40:
            return f"mp4a.{oti:x}" if tag == 5 else None
        aot = esds[pos] >> 3
        if aot == 31:
            aot = 32 + (((esds[pos] & 7) << 3) | (esds[pos + 1] >> 5))
        return f"mp4a.40.{aot}"
    except IndexError:
        return None


def codecs_from_init(*paths):
    """RFC 6381 CODECS value ("hvc1....,mp4a.40.2") from fMP4 init segment(s):
    one with both tracks, or the video and audio init segments."""
    try:
        data = b"".join(Path(p).read_bytes() for p in paths)
    except OSError:
        return None
    video, audio = _video_codec_string(data), _audio_codec_string(data)
    return f"{video},{audio}" if video and audio else None


# MKV uses ISO 639-2 codes ("eng", "swe"); HLS LANGUAGE must be BCP 47, whose
# canonical form uses the 2-letter code where one exists ("en", "sv").
ISO639_2_TO_1 = {
    "ara": "ar", "bul": "bg", "cat": "ca", "ces": "cs", "cze": "cs", "chi": "zh", "zho": "zh",
    "dan": "da", "deu": "de", "ger": "de", "ell": "el", "gre": "el", "eng": "en", "spa": "es",
    "est": "et", "fin": "fi", "fra": "fr", "fre": "fr", "heb": "he", "hin": "hi", "hrv": "hr",
    "hun": "hu", "ind": "id", "isl": "is", "ice": "is", "ita": "it", "jpn": "ja", "kor": "ko",
    "lav": "lv", "lit": "lt", "may": "ms", "msa": "ms", "nld": "nl", "dut": "nl", "nob": "nb",
    "nor": "no", "nno": "nn", "pol": "pl", "por": "pt", "ron": "ro", "rum": "ro", "rus": "ru",
    "slk": "sk", "slo": "sk", "slv": "sl", "srp": "sr", "swe": "sv", "tha": "th", "tur": "tr",
    "ukr": "uk", "vie": "vi",
}


def bcp47(lang):
    """An HLS LANGUAGE value for a container language tag ("und" if unknown)."""
    lang = (lang or "").strip().lower().replace('"', "")
    return ISO639_2_TO_1.get(lang, lang) or "und"


def session_data(path):
    """#EXT-X-SESSION-DATA lines naming what plays, for the receiver's own UI
    (tvOS info panel / Now Playing, if it shows them): the parsed title, and the
    episode title or year as description."""
    from . import names
    info = names.parse(path)
    def clean(s):
        return re.sub(r'[\r\n"]', " ", s).strip()
    lines = [f'#EXT-X-SESSION-DATA:DATA-ID="com.apple.hls.title",VALUE="{clean(info["title"])}"']
    detail = info.get("episode_title") or (str(info["year"]) if info.get("year") else None)
    if detail:
        lines.append(f'#EXT-X-SESSION-DATA:DATA-ID="com.apple.hls.description",VALUE="{clean(detail)}"')
    return lines


def write_master(outdir, audio, sub, media=None, path=None):
    """Rewrite ffmpeg's master playlist: start at the beginning, and make the
    subtitle rendition auto-selected so the Apple TV shows it without the user
    having to enable it from the player menu. ffmpeg leaves out CODECS when it
    copies HEVC; Apple requires it, so it is filled in from the init segments.

    ffmpeg only adds the video variant (#EXT-X-STREAM-INF) when it finishes,
    so while it is still running that line is written here from `media`
    (bandwidth estimated from the file); call again when ffmpeg is done.
    The file's title goes in as session data (`path`, else `media.path`)."""
    text = (outdir / "ffmaster.m3u8").read_text()
    if "#EXT-X-STREAM-INF" not in text and media is not None:
        text = _with_variant(text, sub, media)
    lines = []
    for line in text.splitlines():
        if line.startswith("#EXT-X-STREAM-INF:") and "CODECS=" not in line:
            if codecs := codecs_from_init(outdir / VIDEO_INIT, outdir / AUDIO_INIT):
                line += f',CODECS="{codecs}"'
        if line.startswith("#EXT-X-MEDIA:TYPE=AUDIO"):
            name = (audio.title or audio.lang or "Audio").replace('"', "'")
            line = re.sub(r'NAME="[^"]*"', f'NAME="{name}"', line)
            if "AUTOSELECT=" not in line:
                line = line.replace("DEFAULT=YES", "DEFAULT=YES,AUTOSELECT=YES")
        if line.startswith("#EXT-X-MEDIA:TYPE=SUBTITLES") and sub:
            name = (sub.title or sub.lang or "Subtitles").replace('"', "'")
            # AVPlayer auto-shows FORCED subtitles in the audio language, so tag the
            # rendition with the audio's language; NAME still shows the real one.
            lang = bcp47(audio.lang or sub.lang)
            uri = re.search(r'URI="([^"]+)"', line).group(1)
            line = (f'#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="{name}",'
                    f'LANGUAGE="{lang}",DEFAULT=YES,AUTOSELECT=YES,FORCED=YES,URI="{uri}"')
        lines.append(line)
        if line.startswith("#EXT-X-VERSION"):
            lines.append("#EXT-X-START:TIME-OFFSET=0")
            if (src := path or (media.path if media is not None else None)) is not None:
                lines.extend(session_data(src))
    tmp = outdir / "master.m3u8.tmp"
    tmp.write_text("\n".join(lines) + "\n")
    tmp.replace(outdir / "master.m3u8")


def _with_variant(text, sub, media):
    lines = [line for line in text.splitlines() if line.strip()]
    group = next((m.group(1) for line in lines if line.startswith("#EXT-X-MEDIA:TYPE=AUDIO")
                  for m in [re.search(r'GROUP-ID="([^"]+)"', line)] if m), "group_aud")
    has_subs = any(line.startswith("#EXT-X-MEDIA:TYPE=SUBTITLES") for line in lines)
    if sub is not None and not sub.is_bitmap and not has_subs:
        lines.append(f'#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="subtitle_1",DEFAULT=NO,'
                     f'URI="{SUBTITLE_PLAYLIST}"')
        has_subs = True
    avg = int(media.size_bytes * 8 / media.duration) if media.duration else 10_000_000
    inf = f"#EXT-X-STREAM-INF:BANDWIDTH={int(avg * 1.5)},AVERAGE-BANDWIDTH={avg}"
    if media.video.get("width") and media.video.get("height"):
        inf += f",RESOLUTION={media.video['width']}x{media.video['height']}"
    inf += f',AUDIO="{group}"' + (',SUBTITLES="subs"' if has_subs else "")
    return "\n".join(lines + [inf, VIDEO_PLAYLIST]) + "\n"


def read_segment_durations(outdir):
    """Media durations of the video segments ffmpeg has written so far."""
    try:
        text = (outdir / VIDEO_PLAYLIST).read_text()
    except FileNotFoundError:
        return []
    return [float(m) for m in re.findall(r"#EXTINF:([\d.]+)", text)]


class Transcoder:
    """Runs ffmpeg and exposes its progress. Warnings go to `on_warning`."""

    def __init__(self, cmd, duration, on_warning=None):
        self.duration = duration
        self.progress = 0.0
        self.prepared_s = 0.0
        self.speed = None
        self.on_warning = on_warning or (lambda line: None)
        self.stderr_tail = []
        self._stopped = False
        self.proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     text=True)
        self._threads = [threading.Thread(target=self._read_progress, daemon=True),
                         threading.Thread(target=self._read_stderr, daemon=True)]
        for t in self._threads:
            t.start()

    def _read_progress(self):
        for line in self.proc.stdout:
            key, _, value = line.strip().partition("=")
            try:
                if key == "out_time_us" and value != "N/A":
                    # Before the first frame ffmpeg reports AV_NOPTS_VALUE (a huge
                    # negative number); never let prepared_s go backwards.
                    self.prepared_s = max(self.prepared_s, int(value) / 1e6)
                    if self.duration:
                        self.progress = min(1.0, self.prepared_s / self.duration)
                elif key == "speed" and value.endswith("x"):
                    self.speed = float(value[:-1])
                elif key == "progress" and value == "end":
                    self.progress = 1.0
                    self.prepared_s = max(self.prepared_s, self.duration)
            except ValueError:
                pass
        self.proc.stdout.close()            # EOF: don't leak the pipe fd

    def _read_stderr(self):
        for line in self.proc.stderr:
            line = line.rstrip()
            if not line:
                continue
            self.stderr_tail = (self.stderr_tail + [line])[-20:]
            if not any(w in line for w in IGNORED_FFMPEG_WARNINGS):
                try:
                    self.on_warning(line)
                except Exception:  # noqa: BLE001 - must keep draining stderr
                    pass
        self.proc.stderr.close()

    @property
    def done(self):
        return self.proc.poll() is not None

    @property
    def failed(self):
        # Being terminated by stop() is not an ffmpeg failure.
        return self.done and self.proc.returncode != 0 and not self._stopped

    def wait(self):
        self.proc.wait()
        for t in self._threads:
            t.join(1)

    def stop(self):
        if not self.done:
            self._stopped = True
            self.proc.terminate()
            try:
                self.proc.wait(5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
