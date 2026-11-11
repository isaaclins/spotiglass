"""
Tests for scripts/screenshot-mode/stage-app.sh (#520).

`make test` failed in MusicKitContentSourceLiveTests with MusicTokenRequestError.unknown while
`scripts/screenshots.sh start --with-apple-music` ran in another checkout. That run staged an
ad-hoc signed copy of the app under the real bundle id. The system log showed what followed:

    tccd: Failed to match existing code requirement for subject com.isaaclins.spotiglass
          and service kTCCServiceMediaLibrary
    tccd: AUTHREQ_PROMPTING ... build/screenshot-mode/Spotiglass.app
    tccd: Publishing <TCCDEvent: type=Create, service=kTCCServiceMediaLibrary ...>
    itunescloudd: Refusing XPC connection ... from pid <test host> ...: TCC not granted.

Allowing the prompt moved the one Apple Music permission the bundle id has from the Developer ID
requirement to the ad-hoc copy, and the signed test host was refused from then on.

These tests stage a small app the way screenshot mode stages Spotiglass.app and check the
signature the permission is matched against.

Run from the repository root:  python3 -m unittest discover -s scripts/tests
"""
import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
STAGE = REPO / 'scripts' / 'screenshot-mode' / 'stage-app.sh'
REAL_BUNDLE_ID = 'com.isaaclins.spotiglass'
SCREENSHOT_BUNDLE_ID = 'com.isaaclins.spotiglass.screenshots'
# The requirement the signed app's Apple Music permission is stored under, as tccd logged it.
DEVELOPER_ID_REQUIREMENT = (
    'anchor apple generic and identifier "com.isaaclins.spotiglass" and '
    '(certificate leaf[field.1.2.840.113635.100.6.1.9] exists or '
    'certificate 1[field.1.2.840.113635.100.6.2.6] exists and '
    'certificate leaf[field.1.2.840.113635.100.6.1.13] exists and '
    'certificate leaf[subject.OU] = BHAF4L4726)'
)


def developer_id_identity():
    out = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning'],
                         capture_output=True, text=True).stdout
    return next((line.split()[1] for line in out.splitlines() if 'Developer ID Application' in line), None)


class StageApp(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        # A built app: one executable and the Info.plist, under the real bundle id like the build.
        self.built = self.tmp / 'built' / 'Spotiglass.app'
        macos = self.built / 'Contents' / 'MacOS'
        macos.mkdir(parents=True)
        subprocess.run(['cc', '-x', 'c', '-', '-o', str(macos / 'Spotiglass')],
                       input='int main(void) { return 0; }', text=True, check=True)
        with open(self.built / 'Contents' / 'Info.plist', 'wb') as f:
            plistlib.dump({'CFBundleIdentifier': REAL_BUNDLE_ID, 'CFBundleExecutable': 'Spotiglass',
                           'CFBundlePackageType': 'APPL'}, f)
        self.staged = self.tmp / 'screenshot-mode' / 'Spotiglass.app'
        self.staged.parent.mkdir()

    def stage(self, bundle_id, without_signing_identities=False):
        env = dict(os.environ)
        if without_signing_identities:
            # A Mac with no signing identity: `security` lists none.
            bin_dir = self.tmp / 'bin'
            bin_dir.mkdir(exist_ok=True)
            fake = bin_dir / 'security'
            fake.write_text('#!/bin/sh\necho "     0 valid identities found"\n')
            fake.chmod(0o755)
            env['PATH'] = f'{bin_dir}:{env["PATH"]}'
        return subprocess.run([str(STAGE), str(self.built), str(self.staged), bundle_id, REAL_BUNDLE_ID],
                              capture_output=True, text=True, env=env)

    def signature(self):
        return subprocess.run(['codesign', '-dv', str(self.staged)], capture_output=True, text=True).stderr

    def staged_bundle_id(self):
        with open(self.staged / 'Contents' / 'Info.plist', 'rb') as f:
            return plistlib.load(f)['CFBundleIdentifier']

    def test_a_copy_under_its_own_bundle_id_stays_ad_hoc(self):
        result = self.stage(SCREENSHOT_BUNDLE_ID, without_signing_identities=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.staged_bundle_id(), SCREENSHOT_BUNDLE_ID)
        self.assertIn('Signature=adhoc', self.signature())

    def test_a_copy_under_the_real_bundle_id_is_never_signed_ad_hoc(self):
        """The copy that took the permission over: without Developer ID it isn't staged at all."""
        result = self.stage(REAL_BUNDLE_ID, without_signing_identities=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn('Apple Music', result.stderr)
        self.assertFalse(self.staged.exists())

    def test_a_copy_under_the_real_bundle_id_matches_the_signed_apps_apple_music_permission(self):
        if developer_id_identity() is None:
            self.skipTest('needs the Developer ID Application identity (and its keychain unlocked)')
        result = self.stage(REAL_BUNDLE_ID)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.staged_bundle_id(), REAL_BUNDLE_ID)
        check = subprocess.run(['codesign', '--verify', f'-R={DEVELOPER_ID_REQUIREMENT}', str(self.staged)],
                               capture_output=True, text=True)
        self.assertEqual(check.returncode, 0,
                         'macOS would ask for Apple Music again and move the permission to this copy: '
                         + check.stderr)


if __name__ == '__main__':
    unittest.main()
