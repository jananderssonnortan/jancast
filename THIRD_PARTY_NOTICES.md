# Third-party notices

jancast's own code is MIT-licensed (see `LICENSE`). It builds on the work below.
None of it is bundled in this repository: Python packages are installed with
pip from `requirements.txt`, ffmpeg is installed separately (e.g. Homebrew),
and Apple's frameworks come with macOS.

## Runtime dependencies

| Component | Used for | Licence |
|---|---|---|
| [pyatv](https://pyatv.dev) © Pierre Ståhl and contributors | AirPlay / MediaRemote / Companion protocols to the Apple TV | MIT |
| [FFmpeg](https://ffmpeg.org) (ffmpeg, ffprobe) | Probing, remuxing / encoding to HLS, thumbnails | LGPL-2.1-or-later; GPL builds (e.g. with x264/x265, as in Homebrew) are GPL-2.0-or-later. Run as a separate program, not linked. |
| Apple frameworks (SwiftUI, AVKit, AVFoundation, Vision, Charts, …) | The macOS app, the This Mac player, OCR of picture subtitles | Part of macOS |

### Installed with pyatv (pip)

| Package | Licence |
|---|---|
| aiohttp, aiosignal, frozenlist, multidict, propcache, yarl, requests | Apache-2.0 (aiohttp: Apache-2.0 AND MIT) |
| cryptography, chacha20poly1305-reuseable | Apache-2.0 OR BSD-3-Clause |
| protobuf, idna, pycparser, srptools | BSD-3-Clause |
| aiohappyeyeballs, typing_extensions | PSF-2.0 |
| attrs, annotated-types, cffi (MIT-0), charset-normalizer, ifaddr, miniaudio, pydantic, pydantic-core, six, tabulate, tinytag, typing-inspection, urllib3 | MIT |
| certifi | MPL-2.0 |
| zeroconf | LGPL-2.1-or-later (used as an installed library, unmodified) |

Versions as of jancast 1.0; `pip show <package>` gives each one's licence.

## Artwork and screenshots

- The app icon artwork was generated with Google's Gemini image model and
  composed into the macOS icon shape for this project.
- The README screenshots show frames from TV series that are © their
  respective owners, under the stand-in title "Night Train", only to
  illustrate the app.

## Trademarks

Apple, Apple TV, AirPlay, macOS and tvOS are trademarks of Apple Inc. jancast
is an independent project, not affiliated with or endorsed by Apple.
