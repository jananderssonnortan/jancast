"""Finding the next episode of a series next to the file being played.

Files are recognised by names.parse (S06E02, 1x02, "Show - 12", a bare E05 in
a season folder, ...) and matched on the show name, so other shows in the same
folder are ignored; a show name that comes from the folder matches too. The
next episode is the lowest (season, episode) after the current one (after the
last of a multi-episode file): E03 after E02, or the first episode of the next
season if that is in the same folder.
"""

from pathlib import Path

from . import names


def parse(path):
    """(show key, season, episode) for a file, or None if it is not a
    numbered episode. `season` is None for absolute numbering ("Show - 12")."""
    info = names.parse(path)
    if info["kind"] != "episode" or info["episode"] is None:
        return None
    return names.show_key(info), info["season"], info["episode"]


def _siblings(path):
    """[(file, season, episode)] of the same show next to `path`, itself left
    out (also across the rename when its download completes, and a download
    in progress next to its finished copy)."""
    cur = names.parse(path)
    if cur["kind"] != "episode" or cur["episode"] is None:
        return None, []
    show = names.show_key(cur)
    try:
        entries = sorted(path.parent.iterdir())
    except OSError:
        return cur, []
    out = []
    for f in entries:
        if not names.is_video(f) or "sample" in f.name.lower():
            continue
        if names.without_partial(f) == names.without_partial(path) or (
                names.is_partial(f) and names.without_partial(f).exists()):
            continue
        p = parse(f)
        if p is None or p[0] != show or not f.is_file():
            continue
        out.append((f, p[1], p[2]))
    return cur, out


def _entry(best):
    if best is None:
        return None
    f, s, e = best
    return {"path": str(f), "name": f.name, "season": s, "episode": e,
            "name_info": names.parse(f)}


def next_episode(path):
    cur, siblings = _siblings(Path(path))
    if cur is None:
        return None
    after = (cur["season"] or 0, cur["episode_end"] or cur["episode"])
    later = [x for x in siblings if (x[1] or 0, x[2]) > after]
    return _entry(min(later, key=lambda x: (x[1] or 0, x[2]), default=None))


def nearest_episodes(path, count=4):
    """Paths of up to `count` episodes of the same show in the folder, nearest
    first (the one before, after, two before, two after, ...)."""
    cur, siblings = _siblings(Path(path))
    if cur is None:
        return []
    here = (cur["season"] or 0, cur["episode"])
    order = sorted(siblings, key=lambda x: (x[1] or 0, x[2]))
    before = [x for x in order if (x[1] or 0, x[2]) < here][::-1]
    after = [x for x in order if (x[1] or 0, x[2]) > here]
    out = []
    for i in range(max(len(before), len(after))):
        out += [str(x[0]) for x in (before[i:i + 1] + after[i:i + 1])]
    return out[:count]


def previous_episode(path):
    """The episode before, in the same folder (the credits of the last
    episode are compared with it, as there is no next one)."""
    cur, siblings = _siblings(Path(path))
    if cur is None:
        return None
    before = (cur["season"] or 0, cur["episode"])
    earlier = [x for x in siblings if (x[1] or 0, x[2]) < before]
    return _entry(max(earlier, key=lambda x: (x[1] or 0, x[2]), default=None))
