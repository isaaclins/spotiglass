"""Finder layout, written headlessly by dmgbuild (no AppleScript or Finder automation)."""
import os

application = defines['app']
files = [application]
symlinks = {'Applications': '/Applications'}
icon = os.path.join(application, 'Contents', 'Resources', 'AppIcon.icns')
# dmgbuild picks up background@2x.png next to it and combines both into one Retina image.
background = os.path.join(defines['assets'], 'background.png')
# Finder counts its 32 pt title bar inside this size, so the window is 32 pt
# taller than the 720 x 460 background to show all of it.
window_rect = ((180, 120), (720, 492))
icon_locations = {'Wax.app': (174, 230), 'Applications': (528, 230)}
# The image root also holds dmgbuild's own hidden files. Finder puts anything
# without a position at the first free spot, which is over the wordmark, so
# with hidden files shown (Cmd+Shift+.) they covered it (#633). Park them,
# and what macOS may add to a volume, well below the window instead.
HIDDEN_ROOT_ITEMS = ('.background.tiff', '.VolumeIcon.icns', '.DS_Store',
                     '.fseventsd', '.Trashes', '.Spotlight-V100', '.TemporaryItems')
for index, name in enumerate(HIDDEN_ROOT_ITEMS):
    icon_locations[name] = (100 + 130 * (index % 4), 900 + 160 * (index // 4))
icon_size = 96
text_size = 14
show_toolbar = False
show_status_bar = False
show_tab_view = False
show_pathbar = False
show_sidebar = False
sidebar_width = 0
view = 'icon-view'
include_icon_view_settings = True
include_list_view_settings = False
arrange_by = None
format = 'UDZO'
