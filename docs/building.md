# Building and development

[Back to the README](../README.md)

- [Build from source](#build-from-source)
- [Command line](#command-line)
- [Development](#development)
- [Environment variables](#environment-variables)
- [Where things are kept](#where-things-are-kept)

## Build from source

Besides macOS 14 or later, you need Xcode's command line tools
(`xcode-select --install`), [Homebrew](https://brew.sh) for ffmpeg, and Python 3
(tested with 3.14). This works on Intel Macs too.

```sh
brew install ffmpeg
git clone https://github.com/luftbro/luftbro.git
cd luftbro
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
bash app/build-app.sh          # builds build/Luftbro.app
open build/Luftbro.app
```

The app runs its backend from the cloned folder, so leave `build/Luftbro.app`
where it is (or set `LUFTBRO_BACKEND_DIR` to the folder). To update, `git pull`
and run `bash app/build-app.sh` again; a build of your own doesn't update
itself. `bash app/package-app.sh` makes the self-contained app and the `.dmg`
instead, the same way the download is made.

To try the app without a TV or a video, run it against a simulated backend:

```sh
open build/Luftbro.app --args --mock
```

## Command line

The backend also works on its own:

```sh
bin/luftbro movie.mkv                          # asks for tracks and device
bin/luftbro movie.mkv -a eng -s swe -d "Living Room"
bin/luftbro movie.mkv -s off --from-start
bin/luftbro --info movie.mkv                   # list the tracks
bin/luftbro --devices                          # Apple TVs on the network
bin/luftbro --pair                             # pair once (PIN on the TV)
```

Tracks can be given as numbers, language codes or part of their title.

## Development

```sh
.venv/bin/python -m unittest discover -s tests                     # LUFTBRO_SKIP_SLOW=1 skips the ffmpeg tests
.venv/bin/python scripts/e2e_sim.py                                # end to end against a simulated Apple TV
LUFTBRO_API_TOKEN=dev .venv/bin/python -m luftbro serve --api-port 8722 --simulate slow  # backend with a fake TV
cd app && swift build                                              # just the app
```

The simulated Apple TV fetches the real stream with the profiles `good`, `slow`,
`flaky`, `tv-error` and `stuck`; the end-to-end script checks that the diagnosis
blames the right cause in each.

The app normally launches its own backend and gets a random API token from it
(every request must carry it, see [`API.md`](API.md)). To attach the app to a
backend started by hand, as above, give both the same `LUFTBRO_API_TOKEN`, and
the app `LUFTBRO_API_PORT=8722`.

[`DESIGN.md`](DESIGN.md) describes the app: its layout, the Diagnostics panel,
the keyboard handling and the engineering behind them. [`API.md`](API.md) is the
contract between the app and the backend.

### Releasing

Bump the version in `luftbro/__init__.py`, `app/build-app.sh` and
`app/package-app.sh`, add `docs/releases/<version>.md` and push. The Release
workflow on GitHub builds and checks the app and makes a draft release.
`.venv/bin/python scripts/publish_release.py <version>` then signs its
`latest.json` with the key in `~/.config/luftbro-release` and publishes it.
The app installs only updates signed with that key, and the key never goes to
GitHub.

## Environment variables

None of these are needed to use Luftbro. They're for development and tests.

| Variable | What it does |
|---|---|
| `LUFTBRO_BACKEND_DIR` | The folder the app runs the backend from (a development build) |
| `LUFTBRO_API_TOKEN` | Sets the backend's API token instead of a random one; give the app the same one to attach it |
| `LUFTBRO_API_PORT` | Makes the app attach to a backend already listening on this port |
| `LUFTBRO_LOCAL_ONLY=1` | Keeps a run away from real Apple TVs: no scanning, and it plays only to This Mac or a simulated device |
| `LUFTBRO_SKIP_SLOW=1` | Skips the tests that run ffmpeg |
| `LUFTBRO_SIM_SPEED` | Speeds up the simulated Apple TV (same as `--sim-speed`) |
| `LUFTBRO_FAST_START=0` | Turns fast start off |
| `LUFTBRO_EARLY_START=1` | Starts playback on a stream that is still being prepared (testing) |
| `LUFTBRO_CONFIG_DIR`, `LUFTBRO_CACHE_DIR` | Use other folders for settings and caches |
| `LUFTBRO_MOCK=1` | Same as `--mock`: the app runs against a simulated backend |
| `LUFTBRO_MOCK_SPEED`, `LUFTBRO_MOCK_AUTOPLAY=1`, `LUFTBRO_MOCK_START`, `LUFTBRO_MOCK_FAIL` | Tune the mock: run it faster, start playing at launch, start near a given second, fail after N seconds |
| `LUFTBRO_UPDATE_FEED` | Points the update check at another `latest.json` |
| `LUFTBRO_UPDATE_KEY` | The public key (base64) that feed's `latest.json.sig` is checked against |
| `LUFTBRO_SNAPSHOT_*` | In-app window captures to PNG, for screenshots ([`DESIGN.md`](DESIGN.md#engineering-notes)) |

## Where things are kept

Watch history and the Apple TV pairing live in `~/.config/luftbro/`, readable
only by your user account. The app's own preferences (subtitle delays,
Settings) are ordinary macOS preferences. Caches (thumbnails, subtitles read
from pictures, intro and credits markers) are in `~/Library/Caches/luftbro/`;
deleting them is safe, since they're made again when needed.
