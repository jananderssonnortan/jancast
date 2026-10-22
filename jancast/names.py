"""What a video file "is", from its name: a show's season and episode, or a
film's title and year.

File names follow no standard, so this is a set of heuristics, tried in order
of confidence on the file name:

1. an episode tag: S01E02 (also s1e2, S01.E02, S01 E02, multi-episode
   S01E02E03 / S01E02-E03 / S01E02-03), 1x02, "Season 1 Episode 2", an air
   date (Show.2024.03.15), anime style "[Group] Show - 12 [1080p]" /
   "Show - 12v2", or a bare E05 / "Episode 5";
2. otherwise it is a film: the title is what comes before the year or the
   first piece of scene noise (resolution, source, codecs, audio, release
   flags such as REPACK or Directors Cut, [site.to] and group tags).

The show, season or year the file name lacks comes from its folders:
"Show (2019)/Season 01/S01E02.mkv", "Show/Season 2/02x05.mkv",
"Show/Season 1/E05.mkv", "Show/Season 1/05 - Title.mkv".

Deliberately not guessed: bare 3-4 digit numbers ("Show - 102", "Show 102")
- they are as often years, resolutions or part of the title as episodes.

`parse` is the single source of truth for what the app shows (`name_info` in
docs/API.md) and for finding the next episode (episodes.py).
"""

import functools
import re
import time
from pathlib import Path, PurePath

VIDEO_EXTS = {".mkv", ".mp4", ".m4v", ".mov", ".avi", ".ts", ".m2ts", ".webm"}
# Extensions stripped before parsing; anything else may be part of the name.
_EXTS = VIDEO_EXTS | {".wmv", ".mpg", ".mpeg", ".flv", ".ogm", ".divx", ".srt", ".vtt",
                      ".ass", ".ssa", ".sub", ".idx", ".sup", ".nfo"}
MAX_YEAR = time.localtime().tm_year + 1      # "Blade Runner 2049" is not a release year

# Scene noise: the title ends where the first piece starts. Strong tokens never
# occur in titles; weak ones are also words ("Charlotte's Web", "Mr. Holland's
# Opus", "Uncut Gems"), so they only count when written in capitals or, in an
# all-lowercase name, right before strong noise ("show.s01e02.web.h264").
_STRONG = r"""
    \d{3,4}[pi] | [48]k | uhd | fhd
  | hdr(?:10)?\+? | hdr10plus | dovi | dolby[\s-]?vision | hlg | sdr | 1[02][\s-]?bit | 8[\s-]?bit | hi10p?
  | web[\s-]?dl | web[\s-]?rip | blu[\s-]?ray | bd[\s-]?rip | bd[\s-]?remux | br[\s-]?rip | remux
  | hdtv | pdtv | dvd[\s-]?rip | dvdscr | dvd[59] | hd[\s-]?rip | hd[\s-]?dvd
  | amzn | nf | atvp | dsnp | hmax | pcok | pmtp
  | x\.?26[45] | h\s?26[45] | hevc | avc | av1 | xvid | divx | vp9
  | aac(?:\d\.\d|\d)? | e?ac-?3 | dd(?:p|\+)?\d(?:\.\d)? | ddp | dd\+ | dts(?:-?(?:hd|x|ma|es))?
  | truehd | flac | lpcm | \d\.\d
  | proper | repack | rerip | directors?'?s?[\s-]cut | extended[\s-](?:cut|edition)
"""
_WEAK = r"""
    web | dv | dvd | multi | dual | dubbed | subbed | extended | unrated | uncut | remastered
  | theatrical | imax | limited | internal | complete | atmos | opus | hulu | nordic | swesub
"""
_BEFORE = r"(?<![^\s(\-])"          # start, space, "(" or "-"
_AFTER = r"(?![^\s)\-,])"
_STRONG_RE = re.compile(rf"(?ix){_BEFORE}(?:{_STRONG}){_AFTER}")
_WEAK_RE = re.compile(rf"(?ix){_BEFORE}(?:{_WEAK}){_AFTER}")
_WEAK_TAIL_RE = re.compile(rf"(?ix){_BEFORE}(?:{_WEAK})[\s(\-]*$")

# Episode tags, tried in this order. `more` holds a multi-episode range.
_SXE_RE = re.compile(r"""(?ix)(?<![a-z0-9])
    s(?P<s>\d{1,2})\s?[-.]?\s?e(?P<e>\d{1,3})(?!\d)
    (?P<more>(?:\s?-?\s?(?:s\d{1,2})?e\d{1,3}(?!\d) | -\d{1,3}(?![\da-z]))*)""")
_SEASON_EP_RE = re.compile(r"""(?ix)(?<![a-z0-9])
    (?:season|series)\s?(?P<s>\d{1,2})\s?[-,]?\s?(?:episode|ep)\.?\s?(?P<e>\d{1,3})(?!\d)
    (?P<more>(?:\s?-\s?\d{1,3}(?!\d))?)""")
_NXN_RE = re.compile(r"""(?ix)(?<![a-z0-9])
    (?P<s>\d{1,2})x(?P<e>\d{2,3})(?!\d)
    (?P<more>(?:-(?:\d{1,2}x)?\d{2,3}(?!\d))*)""")
_DATE_RE = re.compile(r"(?<!\d)(?P<y>(?:19|20)\d{2})[ .-](?P<m>\d{2})[ .-](?P<d>\d{2})(?!\d)")
# "Show - 12": anime-style absolute numbering. Without a leading [Group] or a
# v2 suffix only 1-2 digits, and only at the end or before " - Title" / "(".
_ABS_RE = re.compile(r"^(?P<show>.+?)\s-\s(?P<e>\d{1,4})(?P<v>v\d)?(?P<end>$|\s-\s|\s?\(|\s)")
_EP_RE = re.compile(r"""(?ix)(?<![a-z0-9])
    (?:ep(?:isode)?\.?\s?|e)(?P<e>\d{1,3})(?!\d)
    (?P<more>(?:-e?\d{1,3}(?!\d))?)""")
_LEADING_NUM_RE = re.compile(r"^(?P<e>\d{1,2})(?=$|\s)")     # "05 - Title" in a season folder
_SEASON_RE = re.compile(r"(?i)(?<![a-z0-9])(?:(?:season|series|saison|staffel)\s?|s)(?P<s>\d{1,2})(?!\d)")
_SHOW_SEASON_RE = re.compile(r"(?i)^(?P<show>.+?)\s(?:s|season\s?)(?P<s>\d{1,2})$")   # "Show S2 - 05"

_ACRONYM_RE = re.compile(r"(?i)(?<![a-z0-9])(?:[a-z]\.){2,}(?:[a-z](?![a-z0-9]))?")
_WWW_RE = re.compile(r"(?i)^\s*www\.[\w.-]+\.[a-z]{2,4}\s*-\s*")
_SMALL_WORDS = {"a", "an", "the", "and", "or", "of", "in", "on", "at", "to", "for", "by", "vs"}
# Folders that say nothing about what is inside.
_GENERIC_DIRS = {"downloads", "download", "movies", "movie", "films", "film", "tv", "tvshows",
                 "shows", "series", "tvseries", "videos", "video", "media", "desktop", "documents",
                 "torrents", "incoming", "complete", "completed", "plex", "library", "volumes",
                 "users", "home", "newfolder", "untitledfolder", "tmp", "temp"}


def parse(path):
    """What the file is: {"title", "show", "season", "episode", "episode_end",
    "episode_title", "year", "kind"} (see docs/API.md `name_info`)."""
    return dict(_parse(str(path)))


def show_key(info):
    """The show name reduced to letters and digits, for matching episodes."""
    return key(info.get("show") or "")


def key(text):
    return re.sub(r"[\W_]", "", text.casefold())


@functools.lru_cache(maxsize=2048)
def _parse(path):
    p = PurePath(path)
    stem = p.stem if p.suffix.lower() in _EXTS else p.name
    info = _parse_name(stem)
    parent, grand = _folder(p.parent.name), _folder(p.parent.parent.name)
    season_dir = parent if parent and parent["season"] is not None else None

    if info["kind"] == "movie" and season_dir:
        flat = _prepare(stem)[1]
        m = _LEADING_NUM_RE.match(flat)
        if m:
            info = _episode(None, None, int(m.group("e")), None, flat[m.end():])
    if info["kind"] == "episode":
        if info["season"] is None and info["episode"] is not None and season_dir:
            info["season"] = season_dir["season"]
        # The parent names the show, or it is "Season 1" and the one above does.
        folder = parent if parent and parent["show"] else grand if season_dir else None
        if not info["show"] and folder:
            info["show"] = folder["show"]
            info["year"] = info["year"] or folder["year"]
    # A year the name lacks, from a folder with the same name: "Inception (2010)/inception.mkv".
    if info["year"] is None:
        own = key(info["show"] or info["title"] or "")
        for f in (parent, grand):
            if own and f and f["year"] and key(f["show"] or "") == own:
                info["year"] = f["year"]
                break

    if info["kind"] == "episode":
        label = _label(info)
        title = f"{info['show']} {label}" if info["show"] else label
    else:
        title = info["title"] or _tidy(_prepare(stem)[1]) or stem or p.name
        if info["year"] and info["title"]:
            title = f"{title} ({info['year']})"
    return {"title": title, "show": info["show"], "season": info["season"],
            "episode": info["episode"], "episode_end": info["episode_end"],
            "episode_title": info["episode_title"], "year": info["year"], "kind": info["kind"]}


def _label(info):
    """"S1 · E2", "S1 · E2–3", "E12" (no season) or the air date."""
    if info["episode"] is None:
        return info["episode_title"] or ""
    ep = f"E{info['episode']}" + (f"–{info['episode_end']}" if info["episode_end"] else "")
    return f"S{info['season']} · {ep}" if info["season"] is not None else ep


def _parse_name(stem):
    """The fields found in one file name (no folders)."""
    had_group, s = _prepare(stem)
    for rx in (_SXE_RE, _SEASON_EP_RE, _NXN_RE):
        m = rx.search(s)
        if m:
            return _episode(s[:m.start()], int(m.group("s")), int(m.group("e")),
                            m.group("more"), s[m.end():])
    m = _DATE_RE.search(s)
    if m and m.start() > 0 and 1 <= int(m.group("m")) <= 12 and 1 <= int(m.group("d")) <= 31:
        info = _episode(s[:m.start()], None, None, None, "")
        info["episode_title"] = f"{m.group('y')}-{m.group('m')}-{m.group('d')}"
        return info
    m = _ABS_RE.match(s)
    if m and _year(m.group("e")) is None and (
            len(m.group("e")) <= 2 and m.group("end") != " "
            or had_group or m.group("v")):
        show, season = m.group("show"), None
        sm = _SHOW_SEASON_RE.match(show)
        if sm:
            show, season = sm.group("show"), int(sm.group("s"))
        rest = s[m.end("v") if m.group("v") else m.end("e"):]
        return _episode(show, season, int(m.group("e")), None, rest)
    m = _EP_RE.search(s)
    if m:
        return _episode(s[:m.start()], None, int(m.group("e")), m.group("more"), s[m.end():])
    title, year = _title_and_year(s)
    return {"kind": "movie", "title": title or None, "show": None, "season": None, "episode": None,
            "episode_end": None, "episode_title": None, "year": year}


def _episode(before, season, episode, more, rest):
    show, year = _title_and_year(before or "")
    nums = re.findall(r"\d+", more or "")
    end = int(nums[-1]) if nums else None
    return {"kind": "episode", "title": None, "show": show or None, "season": season,
            "episode": episode, "episode_end": end if end and episode is not None and end > episode else None,
            "episode_title": _episode_title(rest), "year": year}


def _episode_title(rest):
    """"- '90 - Autumn (1080p x265 GROUP)" → "'90 - Autumn"; None for just noise."""
    if re.fullmatch(r"-[A-Za-z0-9]+\s*", rest):       # "S01E02-GROUP"
        return None
    title = _tidy(_cut_noise(rest.lstrip(" -–—.:,"), from_start=True))
    if not title or _year(title) or re.fullmatch(r"(?i)v\d", title):
        return None
    return title


def _folder(name):
    """{"show", "year", "season"} from a folder name, or None for "Downloads" and the like."""
    if not name or key(name) in _GENERIC_DIRS or name == Path.home().name:
        return None
    _, s = _prepare(name)
    if re.fullmatch(r"(?i)specials?", s):
        return {"show": None, "year": None, "season": 0}
    for rx in (_SXE_RE, _NXN_RE, _SEASON_RE):
        m = rx.search(s)
        if m:
            show, year = _title_and_year(s[:m.start()])
            return {"show": show or None, "year": year, "season": int(m.group("s"))}
    show, year = _title_and_year(s)
    return {"show": show or None, "year": year, "season": None}


def _prepare(name):
    """(starts with a [Group] tag, the name with separators as spaces and
    [tags] removed): "night.train.s06e03.1080p-group[example.to]" →
    "night train s06e03 1080p-group"."""
    s = name.strip()
    had_group = s.startswith("[")
    s = _WWW_RE.sub("", s)
    s = re.sub(r"[\[{]((?:19|20)\d{2})[\]}]", r"(\1)", s)       # [2019] is a year
    s = re.sub(r"\[[^\]]*\]?|\{[^}]*\}?", " ", s)
    s = re.sub(r"\s-[A-Za-z0-9]+\s*$", "", s)                    # "Title [WEBDL-1080p] -GROUP"
    return had_group, re.sub(r"\s+", " ", _flatten(s)).strip()


def _flatten(s):
    """Dots and underscores to spaces, except in acronyms ("S.W.A.T."), channel
    counts ("DDP5.1") and before a space ("Mr. Robot")."""
    s = s.replace("_", " ")
    keep, spaced = set(), set()
    for m in _ACRONYM_RE.finditer(s):
        dots = [i for i in range(m.start(), m.end()) if s[i] == "."]
        keep.update(dots)
        if m.end() < len(s) and s[m.end()] != " " and s[m.end() - 1] == ".":
            spaced.add(m.end() - 1)                              # "S.W.A.T.2017" → "S.W.A.T. 2017"
    for m in re.finditer(r"(?<!\d)\d\.\d(?!\d)", s):
        keep.add(m.start() + 1)
    out = []
    for i, c in enumerate(s):
        if c != "." or (i in keep and i not in spaced):
            out.append(c)
        elif i in spaced:
            out.append(". ")
        elif i + 1 < len(s) and s[i + 1] == " ":
            out.append(c)
        else:
            out.append(" ")
    text = "".join(out)
    for m in _ACRONYM_RE.finditer(text):
        if m.group() == m.group().lower():
            text = text[:m.start()] + m.group().upper() + text[m.end():]
    return text


def _cut_noise(text, from_start=False):
    """`text` up to the first scene noise. The first word is never noise
    ("Uncut Gems") unless `from_start` (what follows an episode tag)."""
    first = 0
    if not from_start:
        m = re.match(r"\s*\S+", text)
        first = m.end() if m else 0
    end = len(text)
    m = _STRONG_RE.search(text, first)
    if m:
        end = m.start()
    for m in _WEAK_RE.finditer(text, first, end):
        if m.group().isupper():
            end = m.start()
            break
    while end < len(text):
        m = _WEAK_TAIL_RE.search(text, first, end)
        if not m or not m.group().strip(" (-").islower():
            break
        end = m.start()
    return text[:end].rstrip(" -([+")


def _title_and_year(text):
    """("Blade Runner 2049", 2017) from "Blade Runner 2049 (2017) 1080p": the
    last year-like word that is not the first one ("1917 2019", "2001 A Space
    Odyssey 1968") ends the title."""
    tokens = _cut_noise(text).split()
    year = None
    for i in range(len(tokens) - 1, 0, -1):
        y = _year(tokens[i])
        if y:
            year, tokens = y, tokens[:i]
            break
    return _tidy(" ".join(tokens)), year


def _year(token):
    m = re.fullmatch(r"\(?((?:19|20)\d{2})\)?(?:-[A-Za-z0-9]+)?", token.strip())   # "2019-GROUP"
    return int(m.group(1)) if m and 1900 <= int(m.group(1)) <= MAX_YEAR else None


def _tidy(text):
    text = re.sub(r"\(\s*\)", " ", text)
    text = re.sub(r"\s+", " ", text).strip(" -–—_+,:;~").rstrip(" ([")
    if text == text.lower() and any(c.isalpha() for c in text):
        text = _titlecase(text)
    return text


def _titlecase(text):
    """"night train" → "Night Train", "agents of s.h.i.e.l.d." keeps small words
    and acronyms; never str.title() ("It'S")."""
    words = text.split(" ")
    out = []
    for i, w in enumerate(words):
        if i > 0 and i < len(words) - 1 and w in _SMALL_WORDS and not words[i - 1].isdigit():
            out.append(w)
        else:
            out.append(re.sub(r"(^|[-(])([^\W\d_])", lambda m: m.group(1) + m.group(2).upper(), w))
    return " ".join(out)
