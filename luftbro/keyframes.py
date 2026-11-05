"""Keyframe times of a video file without reading it: the MKV index (Cues), or
the sample tables of MP4/MOV (see the second half).

Fast start (ondemand.py) plans every HLS segment up front, and segments of a
copied video stream can only start on keyframes. Matroska files carry an index
of keyframes - the Cues element, usually at the end of the file and found via
the SeekHead - so their times can be read in milliseconds from a few hundred
kilobytes, instead of scanning gigabytes of video.

Returns None when the file has no usable index (not Matroska/WebM, no Cues, an
unknown-size segment, or a cue every minute and more); callers fall back to
preparing the whole stream first.
"""

import struct

EBML_HEADER = 0x1A45DFA3
SEGMENT = 0x18538067
SEEK_HEAD = 0x114D9B74
SEEK = 0x4DBB
SEEK_ID = 0x53AB
SEEK_POSITION = 0x53AC
INFO = 0x1549A966
TIMESTAMP_SCALE = 0x2AD7B1
TRACKS = 0x1654AE6B
TRACK_ENTRY = 0xAE
TRACK_NUMBER = 0xD7
TRACK_TYPE = 0x83
CUES = 0x1C53BB6B
CUE_POINT = 0xBB
CUE_TIME = 0xB3
CUE_TRACK_POSITIONS = 0xB7
CUE_TRACK = 0xF7
CLUSTER = 0x1F43B675

VIDEO_TRACK_TYPE = 1
MAX_GAP_S = 60          # a sparser index is useless for planning segments
MAX_ELEMENT = 64 << 20  # refuse to read more than this for Cues/Tracks


class _Reader:
    def __init__(self, f):
        self.f = f

    def vint(self, keep_marker=False):
        """An EBML variable-size integer: (value, length) or (None, 0) at EOF."""
        first = self.f.read(1)
        if not first:
            return None, 0
        b = first[0]
        length = 1
        mask = 0x80
        while length <= 8 and not b & mask:
            mask >>= 1
            length += 1
        if length > 8:
            raise ValueError("invalid EBML vint")
        rest = self.f.read(length - 1)
        if len(rest) != length - 1:
            return None, 0
        value = b if keep_marker else b & (mask - 1)
        for c in rest:
            value = (value << 8) | c
        return value, length

    def element(self):
        """(id, size, data offset); size None for an unknown size."""
        eid, n = self.vint(keep_marker=True)
        if eid is None:
            return None, None, None
        size, n2 = self.vint()
        if size is None:
            return None, None, None
        if size == (1 << (7 * n2)) - 1:      # all ones: unknown size
            size = None
        return eid, size, self.f.tell()


def _children(data):
    """Child elements of an in-memory master element: [(id, bytes)]."""
    out = []
    pos = 0
    while pos < len(data):
        b = data[pos]
        length = 1
        mask = 0x80
        while length <= 4 and not b & mask:
            mask >>= 1
            length += 1
        if length > 4:
            break
        eid = int.from_bytes(data[pos:pos + length], "big")
        pos += length
        b = data[pos]
        slen = 1
        mask = 0x80
        while slen <= 8 and not b & mask:
            mask >>= 1
            slen += 1
        if slen > 8:
            break
        size = b & (mask - 1)
        for c in data[pos + 1:pos + slen]:
            size = (size << 8) | c
        pos += slen
        out.append((eid, data[pos:pos + size]))
        pos += size
    return out


def _uint(data):
    return int.from_bytes(data, "big") if data else 0


def mkv_keyframes(path):
    """Sorted keyframe times (seconds) of the first video track, or None."""
    try:
        with open(path, "rb") as f:
            return _read(_Reader(f))
    except (OSError, ValueError, IndexError, struct.error):
        return None


def _read(r):
    eid, size, start = r.element()
    if eid != EBML_HEADER:
        return None
    r.f.seek(start + size)
    eid, seg_size, seg_start = r.element()
    if eid != SEGMENT:
        return None

    # Top-level elements before the first cluster, and the SeekHead's map.
    positions = {}
    while True:
        element_at = r.f.tell()
        eid, size, data_at = r.element()
        if eid is None or size is None:
            break
        if eid == SEEK_HEAD and size < MAX_ELEMENT:
            for cid, seek in _children(r.f.read(size)):
                if cid != SEEK:
                    continue
                fields = dict(_children(seek))
                target = _uint(fields.get(SEEK_ID, b""))
                if SEEK_POSITION in fields:
                    positions.setdefault(target, seg_start + _uint(fields[SEEK_POSITION]))
            continue
        if eid in (INFO, TRACKS, CUES):
            positions.setdefault(eid, element_at)
        if eid == CLUSTER:
            break
        r.f.seek(data_at + size)

    scale = 1_000_000
    if INFO in positions:
        info = _load(r, positions[INFO], INFO)
        if info is not None:
            for cid, value in _children(info):
                if cid == TIMESTAMP_SCALE:
                    scale = _uint(value) or scale
    video_track = None
    if TRACKS in positions:
        tracks = _load(r, positions[TRACKS], TRACKS)
        for cid, entry in _children(tracks or b""):
            if cid != TRACK_ENTRY:
                continue
            fields = dict(_children(entry))
            if _uint(fields.get(TRACK_TYPE, b"")) == VIDEO_TRACK_TYPE:
                video_track = _uint(fields.get(TRACK_NUMBER, b""))
                break
    if video_track is None or CUES not in positions:
        return None
    cues = _load(r, positions[CUES], CUES)
    if cues is None:
        return None

    times = set()
    for cid, point in _children(cues):
        if cid != CUE_POINT:
            continue
        cue_time = None
        tracks = set()
        for fid, value in _children(point):
            if fid == CUE_TIME:
                cue_time = _uint(value)
            elif fid == CUE_TRACK_POSITIONS:
                tracks.update(_uint(v) for tid, v in _children(value) if tid == CUE_TRACK)
        if cue_time is not None and video_track in tracks:
            times.add(cue_time * scale / 1e9)
    times = sorted(times)
    if len(times) < 2 or any(b - a > MAX_GAP_S for a, b in zip(times, times[1:])):
        return None
    return times


def _load(r, offset, expected):
    r.f.seek(offset)
    eid, size, _ = r.element()
    if eid != expected or size is None or size > MAX_ELEMENT:
        return None
    data = r.f.read(size)
    return data if len(data) == size else None


# ---- MP4 / MOV --------------------------------------------------------------
#
# The sample tables in the movie box (moov) say which samples are keyframes
# (stss), when each is decoded (stts) and how far its presentation is shifted
# (ctts); the edit list (elst) moves the whole track, as ffmpeg's demuxer does,
# so the times match the pts ffmpeg reports. Fragmented MP4 (samples in moof
# boxes) and edit lists with more than one real edit fall back (None).

MAX_MOOV = 128 << 20


def mp4_keyframes(path):
    """Sorted keyframe times (seconds) of the first video track, or None."""
    try:
        with open(path, "rb") as f:
            moov = _mp4_moov(f)
            return _mp4_times(moov) if moov is not None else None
    except (OSError, ValueError, IndexError, struct.error):
        return None


def video_keyframes(path):
    """Keyframe times from the file's own index (Matroska/WebM or MP4/MOV), or None."""
    with open(path, "rb") as f:
        head = f.read(12)
    if head[:4] == b"\x1a\x45\xdf\xa3":
        return mkv_keyframes(path)
    if head[4:8] in (b"ftyp", b"moov", b"free", b"mdat", b"wide", b"skip"):
        return mp4_keyframes(path)
    return None


def _mp4_moov(f):
    """The top-level moov box's payload, wherever it is (before or after mdat)."""
    while True:
        start = f.tell()
        head = f.read(8)
        if len(head) < 8:
            return None
        size, kind = struct.unpack(">I4s", head)
        header = 8
        if size == 1:
            size = struct.unpack(">Q", f.read(8))[0]
            header = 16
        elif size == 0:                       # to the end of the file
            if kind != b"moov":
                return None
            return f.read(MAX_MOOV)
        if size < header:
            return None
        if kind == b"moov":
            if size > MAX_MOOV:
                return None
            data = f.read(size - header)
            return data if len(data) == size - header else None
        f.seek(start + size)


def _mp4_boxes(data):
    """Child boxes of an in-memory box: {type: [payload, ...]}."""
    out = {}
    pos = 0
    while pos + 8 <= len(data):
        size, kind = struct.unpack_from(">I4s", data, pos)
        header = 8
        if size == 1:
            size = struct.unpack_from(">Q", data, pos + 8)[0]
            header = 16
        elif size == 0:
            size = len(data) - pos
        if size < header:
            break
        out.setdefault(kind, []).append(data[pos + header:pos + size])
        pos += size
    return out


def _mp4_times(moov):
    top = _mp4_boxes(moov)
    if b"mvex" in top:                        # fragmented: the samples are in moof boxes
        return None
    mvhd = top.get(b"mvhd", [b""])[0]
    if not mvhd:
        return None
    movie_scale = struct.unpack_from(">I", mvhd, 20 if mvhd[0] == 1 else 12)[0]
    for trak in top.get(b"trak", []):
        tbox = _mp4_boxes(trak)
        mdia = _mp4_boxes(tbox.get(b"mdia", [b""])[0])
        hdlr = mdia.get(b"hdlr", [b""])[0]
        if hdlr[8:12] != b"vide":
            continue
        mdhd = mdia[b"mdhd"][0]
        scale = struct.unpack_from(">I", mdhd, 20 if mdhd[0] == 1 else 12)[0]
        stbl = _mp4_boxes(_mp4_boxes(mdia[b"minf"][0])[b"stbl"][0])
        return _track_times(stbl, scale, _mp4_edit(tbox, scale, movie_scale))
    return None


def _mp4_edit(tbox, scale, movie_scale):
    """(media time the track starts at, seconds of empty edit before it), or None
    for edit lists ffmpeg would play differently (several real edits)."""
    edts = tbox.get(b"edts")
    if not edts:
        return 0, 0.0
    elst = _mp4_boxes(edts[0]).get(b"elst", [b""])[0]
    if not elst:
        return 0, 0.0
    version = elst[0]
    count = struct.unpack_from(">I", elst, 4)[0]
    fmt, width = (">Qq", 16) if version == 1 else (">Ii", 8)
    empty_s, media_time, real = 0.0, 0, 0
    for i in range(count):
        duration, time_ = struct.unpack_from(fmt, elst, 8 + i * (width + 4))
        if time_ == -1:
            if real:
                return None
            empty_s += duration / movie_scale
        else:
            real += 1
            media_time = time_
    return (media_time, empty_s) if real <= 1 else None


def _track_times(stbl, scale, edit):
    if edit is None or not scale or b"stts" not in stbl:
        return None
    media_time, empty_s = edit
    # Decode time of each sample.
    stts = stbl[b"stts"][0]
    dts, t = [], 0
    for i in range(struct.unpack_from(">I", stts, 4)[0]):
        count, delta = struct.unpack_from(">II", stts, 8 + i * 8)
        for _ in range(count):
            dts.append(t)
            t += delta
    if len(dts) < 2:
        return None
    # Presentation offsets (version 1: signed).
    offsets = [0] * len(dts)
    if b"ctts" in stbl:
        ctts = stbl[b"ctts"][0]
        fmt = ">Ii" if ctts[0] == 1 else ">II"
        n = 0
        for i in range(struct.unpack_from(">I", ctts, 4)[0]):
            count, off = struct.unpack_from(fmt, ctts, 8 + i * 8)
            for _ in range(count):
                if n < len(offsets):
                    offsets[n] = off
                n += 1
    # Keyframes, numbered from 1; without stss every sample is one.
    if b"stss" in stbl:
        stss = stbl[b"stss"][0]
        samples = [struct.unpack_from(">I", stss, 8 + i * 4)[0] - 1
                   for i in range(struct.unpack_from(">I", stss, 4)[0])]
    else:
        samples = range(len(dts))
    times = sorted({round((dts[s] + offsets[s] - media_time) / scale + empty_s, 6)
                    for s in samples if 0 <= s < len(dts)})
    times = [x for x in times if x >= 0]
    if len(times) < 2 or any(b - a > MAX_GAP_S for a, b in zip(times, times[1:])):
        return None
    return times
