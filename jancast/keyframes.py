"""Keyframe times of a video file without reading it: the MKV index (Cues).

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
