"""Finder layout, written headlessly by dmgbuild (no AppleScript or Finder automation)."""
import os

application = defines['app']
files = [application]
symlinks = {'Applications': '/Applications'}
icon = os.path.join(application, 'Contents', 'Resources', 'AppIcon.icns')
background = os.path.join(defines['assets'], 'background.png')
window_rect = ((180, 120), (720, 460))
icon_locations = {'Wax.app': (174, 230), 'Applications': (528, 230)}
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
