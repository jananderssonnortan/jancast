# Troubleshooting

[Back to the README](../README.md)

## Common problems

### macOS won't open Luftbro

It isn't notarized, so macOS blocks it the first time. The [install steps in
the README](../README.md#install) show how to open it anyway, or how to do it
with one Terminal command.

### The Apple TV isn't listed

It has to be on the same network and awake. Use *Scan for Apple TVs* (⌘R) in
the device menu. AirPlay must be allowed for everyone on the network, or for
the current user (Apple TV Settings → AirPlay and HomeKit).

### It connects but never plays

Check that macOS didn't block incoming connections (System Settings → Network →
Firewall). The Apple TV fetches the stream from your Mac, so Luftbro has to be
allowed to accept them.

### It stops when the Mac goes to sleep

Luftbro keeps the Mac awake while it streams (the display may still turn off),
but closing the lid sleeps it. If the connection to the TV is lost anyway,
Luftbro reconnects and carries on from where the TV was, for about a minute
before it gives up.

### The TV volume keys do nothing

Volume goes through the Apple TV, so it has to be set up to control your TV's
volume (Apple TV Settings → Remotes and Devices → Volume Control). For the
Mac's own volume keys, turn on *Playback → Mac Volume Keys Control the TV* and
give Luftbro the Accessibility permission.

### Install doesn't work for an update

Luftbro has to be in a folder it can write to, like Applications, and macOS may
ask once whether Luftbro may modify apps. Allow it.

### Something stutters or fails

Open Diagnostics (⌥⌘I). The Summary names the likely cause, and *Copy Report*
(⇧⌘C) gives a text report to share in an
[issue](https://github.com/luftbro/luftbro/issues).

## Known limitations

- The download is for Apple Silicon. Luftbro builds and runs on Intel Macs, but
  you have to [build it yourself](building.md).
- It's tested with tvOS 26.
- Text subtitles can't be burned in (Homebrew's ffmpeg lacks libass), so they
  are always shown as soft subtitles, which the Apple TV draws itself.
- HDR is lost when video has to be re-encoded (AV1/VP9 HDR, or burning in
  picture subtitles on 10-bit HDR).
- Without fast start (re-encoded video, formats other than MKV, WebM, MP4, M4V
  and MOV, files still downloading), playback waits for the start to be
  prepared, and the stream needs temporary disk space about the size of the
  file.
- Interlaced video (DVD and VOB files, DV, some camcorder footage) isn't
  deinterlaced when it's converted, so fast motion can show comb lines.
- Subtitles made for another cut of the film, with scenes added or removed,
  are early in some parts and late in others: no single delay or stretch fits
  them, and *Sync Automatically* leaves them alone. Subtitles that drift
  steadily (made for another frame rate) are stretched to fit.
