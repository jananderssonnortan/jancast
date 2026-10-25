# dmgbuild settings for the Jancast disk image (package-app.sh):
#   dmgbuild -s dmg-settings.py -D app=<Jancast.app> -D background=<tiff> "<volume name>" <out.dmg>
# Positions match make-dmg-background.swift: icon centres at x 170 / 470,
# y 170 from the top of a 640x440 window. Needs dmgbuild 1.6.6 or later: with
# older ones macOS 26 Finder showed no background.
import os

app = defines["app"]  # noqa: F821 (dmgbuild provides `defines`)
background = defines["background"]  # noqa: F821

format = "UDZO"
files = [app]
symlinks = {"Applications": "/Applications"}

window_rect = ((200, 160), (640, 440))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13
icon_locations = {
    os.path.basename(app): (170, 170),
    "Applications": (470, 170),
}
