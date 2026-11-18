"""The installer window shows Wax and Applications and nothing else (#633).

Builds a real disk image with the pinned dmgbuild and scripts/dmg/settings.py,
mounts it, and reads the .DS_Store Finder will use. Finder drops any root item
without a position at the first free spot, which is over the wordmark, so with
hidden files shown (Cmd+Shift+.) `.background.tiff` and `.VolumeIcon.icns`
covered it. Every item at the image root must have a position, and every
hidden one must lie below the window.

Needs macOS (hdiutil) and dmgbuild from scripts/dmg/requirements.txt:
    python3 -m venv build/dmg-tools
    build/dmg-tools/bin/pip install --require-hashes --only-binary :all: -r scripts/dmg/requirements.txt
    build/dmg-tools/bin/python -m unittest scripts/tests/test_dmg_layout.py
"""
import ast
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SETTINGS = ROOT / 'scripts/dmg/settings.py'

try:
    import dmgbuild
    import ds_store
except ImportError:
    dmgbuild = None


def fake_app(folder):
    """A minimal Wax.app: dmgbuild only needs the bundle and its icon."""
    app = Path(folder) / 'Wax.app'
    resources = app / 'Contents/Resources'
    resources.mkdir(parents=True)
    (app / 'Contents/MacOS').mkdir()
    with open(app / 'Contents/Info.plist', 'wb') as f:
        plistlib.dump({'CFBundleExecutable': 'Wax', 'CFBundleName': 'Wax'}, f)
    png = Path(folder) / 'icon.png'
    subprocess.run(['sips', '-z', '128', '128', str(ROOT / 'scripts/dmg/arch.png'),
                    '--out', str(png)], check=True, capture_output=True)
    subprocess.run(['sips', '-s', 'format', 'icns', str(png),
                    '--out', str(resources / 'AppIcon.icns')], check=True, capture_output=True)
    return app


def settings_value(name):
    tree = ast.parse(SETTINGS.read_text())
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(
                isinstance(t, ast.Name) and t.id == name for t in node.targets):
            return ast.literal_eval(node.value)
    raise KeyError(name)


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('hdiutil'), 'needs hdiutil')
@unittest.skipIf(dmgbuild is None, 'needs dmgbuild from scripts/dmg/requirements.txt')
class InstallerLayout(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.folder = tempfile.mkdtemp()
        image = Path(cls.folder) / 'Wax.dmg'
        dmgbuild.build_dmg(str(image), 'Wax', settings_file=str(SETTINGS),
                           defines={'app': str(fake_app(cls.folder)),
                                    'assets': str(ROOT / 'scripts/dmg')})
        mount = Path(cls.folder) / 'mount'
        mount.mkdir()
        subprocess.run(['hdiutil', 'attach', '-nobrowse', '-readonly', '-noautoopen',
                        '-mountpoint', str(mount), str(image)], check=True, capture_output=True)
        try:
            cls.root_items = sorted(os.listdir(mount))
            cls.positions = {}
            with ds_store.DSStore.open(str(mount / '.DS_Store'), 'r') as store:
                for entry in store:
                    if entry.code == b'Iloc':
                        cls.positions[entry.filename] = entry.value
        finally:
            subprocess.run(['hdiutil', 'detach', str(mount)], check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.folder, ignore_errors=True)

    def test_every_item_at_the_image_root_has_a_position(self):
        self.assertIn('.background.tiff', self.root_items)
        self.assertIn('.VolumeIcon.icns', self.root_items)
        missing = [name for name in self.root_items if name not in self.positions]
        self.assertEqual(missing, [], 'Finder would drop these over the wordmark')

    def test_only_wax_and_applications_lie_in_the_window(self):
        width, height = settings_value('window_rect')[1]
        height -= 32  # the title bar Finder counts inside window_rect
        half = settings_value('icon_size') / 2
        for name in self.root_items:
            x, y = self.positions[name]
            inside = x + half > 0 and x - half < width and y + half > 0 and y - half < height
            if name.startswith('.'):
                self.assertFalse(inside, f'{name} at {(x, y)} shows in the {width} x {height} window')
            else:
                self.assertTrue(inside, f'{name} at {(x, y)} is outside the window')
                self.assertIn(name, ('Wax.app', 'Applications'))


if __name__ == '__main__':
    unittest.main()
