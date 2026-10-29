# dmgbuild's settings for Joinery's disk image: the app, a link to Applications, and the background
# scripts/make_dmg_background.swift draws, laid out without Finder.
#   dmgbuild -s scripts/dmg.py -D app=Joinery.app -D background=background.png Joinery Joinery.dmg
# background@2x.png beside background.png is used on Retina screens. The numbers match make_dmg_background.swift.
import os.path

app = defines["app"]
files = [app]
symlinks = {"Applications": "/Applications"}
background = defines["background"]
window_rect = ((200, 120), (640, 400))
default_view = "icon-view"
show_toolbar = False
show_status_bar = False
show_sidebar = False
show_pathbar = False
icon_size = 128
text_size = 13
icon_locations = {os.path.basename(app): (180, 180), "Applications": (460, 180)}
format = "ULFO"
filesystem = "HFS+"
