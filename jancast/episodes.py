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


def next_episode(path):
    path = Path(path)
    cur = names.parse(path)
    if cur["kind"] != "episode" or cur["episode"] is None:
        return None
    show = names.show_key(cur)
    after = (cur["season"] or 0, cur["episode_end"] or cur["episode"])
    best = None
    try:
        entries = sorted(path.parent.iterdir())
    except OSError:
        return None
    for f in entries:
        if not names.is_video(f) or "sample" in f.name.lower():
            continue
        # Itself, also across the rename when its download completes, and a
        # download in progress next to its finished copy.
        if names.without_partial(f) == names.without_partial(path) or (
                names.is_partial(f) and names.without_partial(f).exists()):
            continue
        p = parse(f)
        if p is None or p[0] != show or (p[1] or 0, p[2]) <= after:
            continue
        if not f.is_file():
            continue
        if best is None or (p[1] or 0, p[2]) < (best[1] or 0, best[2]):
            best = (f, p[1], p[2])
    if best is None:
        return None
    f, s, e = best
    return {"path": str(f), "name": f.name, "season": s, "episode": e,
            "name_info": names.parse(f)}
