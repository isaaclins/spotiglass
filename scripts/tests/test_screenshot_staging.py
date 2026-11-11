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
# The requirement the signed app's Apple Music permission is stored under, as tccd logged it (with my
# team, BHAF4L4726, in the last line).
def developer_id_requirement(team):
    return ('anchor apple generic and identifier "com.isaaclins.spotiglass" and '
            '(certificate leaf[field.1.2.840.113635.100.6.1.9] exists or '
            'certificate 1[field.1.2.840.113635.100.6.2.6] exists and '
            'certificate leaf[field.1.2.840.113635.100.6.1.13] exists and '
            f'certificate leaf[subject.OU] = {team})')


def developer_id_team():
    """The team of the identity stage-app.sh signs with, or None without one."""
    out = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning'],
                         capture_output=True, text=True).stdout
    line = next((line for line in out.splitlines() if 'Developer ID Application' in line), None)
    return line.rsplit('(', 1)[1].split(')')[0] if line else None


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

    def stage(self, bundle_id, without_signing_identities=False, local_sign_identity=None):
        env = dict(os.environ)
        env.pop('LOCAL_SIGN_IDENTITY', None)
        if local_sign_identity is not None:
            env['LOCAL_SIGN_IDENTITY'] = local_sign_identity
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

    def test_an_ad_hoc_local_sign_identity_is_refused_too(self):
        result = self.stage(REAL_BUNDLE_ID, local_sign_identity='-')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertFalse(self.staged.exists())

    def test_a_copy_under_the_real_bundle_id_matches_the_signed_apps_apple_music_permission(self):
        team = developer_id_team()
        if team is None:
            self.skipTest('needs a Developer ID Application identity')
        result = self.stage(REAL_BUNDLE_ID)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.staged_bundle_id(), REAL_BUNDLE_ID)
        check = subprocess.run(['codesign', '--verify', f'-R={developer_id_requirement(team)}', str(self.staged)],
                               capture_output=True, text=True)
        self.assertEqual(check.returncode, 0,
                         'macOS would ask for Apple Music again and move the permission to this copy: '
                         + check.stderr)


class StartWithAppleMusic(unittest.TestCase):
    """`screenshots.sh start --with-apple-music` when the copy can't be staged.

    A refusal after the build used to leave this checkout owning the real app's defaults backup, so
    every other checkout's `start --with-apple-music` and `appearance` were refused until a `stop`
    here, although nothing ran.
    """

    def start(self, security_output, codesign_script='exec /usr/bin/codesign "$@"', make_status=1):
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp)
        bin_dir = tmp / 'bin'
        bin_dir.mkdir()
        self.built = tmp / 'make-ran'
        (bin_dir / 'security').write_text(f"#!/bin/sh\ncat <<'EOF'\n{security_output}\nEOF\n")
        (bin_dir / 'codesign').write_text(f'#!/bin/sh\n{codesign_script}\n')
        (bin_dir / 'make').write_text(f'#!/bin/sh\ntouch "{self.built}"\nexit {make_status}\n')
        for tool in bin_dir.iterdir():
            tool.chmod(0o755)
        self.home = tmp / 'home'
        self.home.mkdir()
        env = dict(os.environ, HOME=str(self.home), PATH=f'{bin_dir}:{os.environ["PATH"]}')
        env.pop('LOCAL_SIGN_IDENTITY', None)
        return subprocess.run([str(REPO / 'scripts' / 'screenshots.sh'), 'start', '--with-apple-music'],
                              capture_output=True, text=True, env=env)

    def assert_refused_before_anything_changed(self, result):
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertFalse(self.built.exists(), 'it built the app before refusing')
        self.assertEqual(list(self.home.rglob('*')), [], 'it changed state outside the checkout before refusing')

    def test_without_a_developer_id_identity_it_stops_before_building_or_claiming_the_backups(self):
        result = self.start('     0 valid identities found')
        self.assert_refused_before_anything_changed(result)
        self.assertIn('signing identity', result.stderr)

    def test_with_a_locked_keychain_it_stops_before_building_or_claiming_the_backups(self):
        # A locked keychain still lists its identities; only signing fails.
        result = self.start(
            '  1) 0123456789ABCDEF0123456789ABCDEF01234567 "Developer ID Application: Someone (TEAM123456)"\n'
            '     1 valid identities found',
            codesign_script='echo "errSecInternalComponent" >&2; exit 1')
        self.assert_refused_before_anything_changed(result)
        self.assertIn('errSecInternalComponent', result.stderr)
        self.assertIn('unlock', result.stderr)

    def test_a_failed_staging_after_the_build_leaves_the_backups_unclaimed(self):
        # The identity passes the check, the build succeeds, and signing the staged copy fails (an
        # identity that can sign a binary but not this bundle, or a keychain locked meanwhile).
        # Nothing is launched: staging stops the run either way.
        result = self.start(
            '  1) 0123456789ABCDEF0123456789ABCDEF01234567 "Developer ID Application: Someone (TEAM123456)"\n'
            '     1 valid identities found',
            codesign_script='case "$*" in *.app*) echo "errSecInternalComponent" >&2; exit 1 ;; esac',
            make_status=0)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertTrue(self.built.exists())
        self.assertEqual(list(self.home.rglob('*')), [], 'it claimed the backups before the copy was staged')

if __name__ == '__main__':
    unittest.main()
