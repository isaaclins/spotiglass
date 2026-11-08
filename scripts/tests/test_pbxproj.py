"""
Tests for scripts/pbxproj.py and the scripts built on it (#384).

Every test runs against a copy of the real Spotiglass.xcodeproj/project.pbxproj
and the real Swift files, and replays a way the project file has actually gone
wrong:

- a test file that sits in a group but is missing from the test target's
  Sources phase (the old audit only grepped for the basename and passed it);
- a file registered twice (PlaylistBrowserPlaybackHelpersTests.swift had two
  file references and two build files on main until this fix);
- two branches registering files at the same time and handing out the same
  object ID (#377 and #378);
- an insertion point that is missing, which used to write a half-registered
  project.

Run from the repository root:  python3 -m unittest discover -s scripts/tests
"""
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPTS = REPO / 'scripts'
sys.path.insert(0, str(SCRIPTS))
import pbxproj  # noqa: E402

PBX_REL = 'Spotiglass.xcodeproj/project.pbxproj'


class RepoCopy(unittest.TestCase):
    """A throwaway copy of the project file, the Swift sources and the scripts."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        (self.tmp / PBX_REL).parent.mkdir(parents=True)
        shutil.copy(REPO / PBX_REL, self.tmp / PBX_REL)
        for d in ('Spotiglass', 'SpotiglassTests'):
            for f in (REPO / d).rglob('*.swift'):
                dest = self.tmp / f.relative_to(REPO)
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy(f, dest)
        shutil.copytree(SCRIPTS, self.tmp / 'scripts', ignore=shutil.ignore_patterns('tests', '__pycache__'))

    @property
    def pbx(self):
        return self.tmp / PBX_REL

    def run_script(self, *args):
        return subprocess.run(
            [str(a) for a in args], cwd=self.tmp, capture_output=True, text=True,
        )

    def add_swift(self, rel):
        path = self.tmp / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('import XCTest\n')


class AuditTests(RepoCopy):
    def test_real_project_passes(self):
        result = self.run_script('scripts/audit-orphaned-sources.sh')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_test_file_only_in_a_group_fails(self):
        target = 'PlaylistOwnerDisplayTests.swift'
        text = self.pbx.read_text()
        # Drop only the Sources-phase line: the file keeps its group entry,
        # its file reference and even its PBXBuildFile, so it is "in the
        # project" by every text check, but the target never compiles it.
        broken, n = re.subn(rf'\n\t\t\t\t\w+ /\* {re.escape(target)} in Sources \*/,', '', text)
        self.assertEqual(n, 1)
        self.pbx.write_text(broken)
        # The old audit's check, for the record: the basename is still there.
        self.assertIn(target, broken)

        result = self.run_script('scripts/audit-orphaned-sources.sh')
        self.assertEqual(result.returncode, 1)
        self.assertIn(
            f"SpotiglassTests/{target}: in the project but not in the SpotiglassTests target's Sources phase",
            result.stdout,
        )

    def test_file_in_the_wrong_target_fails(self):
        # A test file compiled into the app target instead of the test target.
        self.add_swift('SpotiglassTests/WrongTargetTests.swift')
        text, _ = pbxproj.register(self.pbx.read_text(), 'SpotiglassTests/WrongTargetTests.swift', 'Spotiglass')
        self.pbx.write_text(text)
        result = self.run_script('scripts/audit-orphaned-sources.sh')
        self.assertEqual(result.returncode, 1)
        self.assertIn("WrongTargetTests.swift: in the project but not in the SpotiglassTests target's Sources phase", result.stdout)

    def test_file_in_both_targets_fails(self):
        # A test helper that is compiled by the test target and also ticked
        # for the app target: its own target compiles it, but it ships in the app.
        self.add_swift('SpotiglassTests/BothTargetsHelper.swift')
        text, _ = pbxproj.register(self.pbx.read_text(), 'SpotiglassTests/BothTargetsHelper.swift', 'SpotiglassTests')
        text, _ = pbxproj.register(text, 'SpotiglassTests/BothTargetsHelper.swift', 'Spotiglass')
        self.pbx.write_text(text)
        result = self.run_script('scripts/audit-orphaned-sources.sh')
        self.assertEqual(result.returncode, 1)
        self.assertIn('SpotiglassTests/BothTargetsHelper.swift: is also compiled by the Spotiglass target', result.stdout)

    def test_file_registered_twice_fails(self):
        # Rebuild the duplicate that main carried for
        # PlaylistBrowserPlaybackHelpersTests.swift: a second file reference,
        # build file, group child and Sources line for the same path.
        name = 'PlaylistBrowserPlaybackHelpersTests.swift'
        text = self.pbx.read_text()
        dup_lines = [l for l in text.splitlines(keepends=True) if f'/* {name}' in l]
        self.assertEqual(len(dup_lines), 4)
        for line in dup_lines:
            text = text.replace(line, line + line.replace('TST', 'DUP'), 1)
        self.pbx.write_text(text)
        result = self.run_script('scripts/audit-orphaned-sources.sh')
        self.assertEqual(result.returncode, 1)
        self.assertIn(f'SpotiglassTests/{name}: has 2 file references (registered twice)', result.stdout)
        self.assertIn(f'SpotiglassTests/{name}: is in the SpotiglassTests Sources phase 2 times', result.stdout)


class RegisterTests(RepoCopy):
    def test_new_test_file_is_compiled_and_audit_passes(self):
        self.add_swift('SpotiglassTests/BrandNewTests.swift')
        self.assertEqual(self.run_script('scripts/audit-orphaned-sources.sh').returncode, 1)

        result = self.run_script(sys.executable, 'scripts/register-test-files.py', 'BrandNewTests.swift')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('SpotiglassTests/BrandNewTests.swift',
                      pbxproj.Project.load(self.pbx).compiled_paths('SpotiglassTests'))
        result = self.run_script('scripts/audit-orphaned-sources.sh')
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_registering_twice_is_a_no_op(self):
        self.add_swift('SpotiglassTests/BrandNewTests.swift')
        self.run_script(sys.executable, 'scripts/register-test-files.py', 'BrandNewTests.swift')
        once = self.pbx.read_text()
        result = self.run_script(sys.executable, 'scripts/register-test-files.py', 'BrandNewTests.swift')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('skip', result.stdout)
        self.assertEqual(self.pbx.read_text(), once)

    def test_registering_an_existing_file_is_a_no_op(self):
        # The file that the old script registered a second time on main.
        before = self.pbx.read_text()
        result = self.run_script(sys.executable, 'scripts/register-test-files.py',
                                 'PlaylistBrowserPlaybackHelpersTests.swift')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.pbx.read_text(), before)

        before_src = self.pbx.read_text()
        result = self.run_script(sys.executable, 'scripts/register-source-files.py',
                                 'HomeFeedModels.swift', 'HomeFeedModels.swift')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.pbx.read_text(), before_src)

    def test_file_with_reference_but_no_build_file_gets_only_the_build_file(self):
        target = 'PlaylistOwnerDisplayTests.swift'
        text = self.pbx.read_text()
        text = re.sub(rf'\n\t\t\t\t\w+ /\* {re.escape(target)} in Sources \*/,', '', text)
        text = re.sub(rf'\n\t\t\w+ /\* {re.escape(target)} in Sources \*/ = .*', '', text)
        self.pbx.write_text(text)
        result = self.run_script(sys.executable, 'scripts/register-test-files.py', target)
        self.assertEqual(result.returncode, 0, result.stderr)
        project = pbxproj.Project.load(self.pbx)
        self.assertEqual(len(project.file_refs_for(f'SpotiglassTests/{target}')), 1)
        self.assertEqual(self.run_script('scripts/audit-orphaned-sources.sh').returncode, 0)

    def test_missing_anchor_is_an_error_and_writes_nothing(self):
        self.add_swift('Spotiglass/Browsing/NewThing.swift')
        before = self.pbx.read_text()
        result = self.run_script(sys.executable, 'scripts/register-source-files.py',
                                 'NoSuchAnchor.swift', 'NewThing.swift')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('nothing written', result.stderr)
        self.assertEqual(self.pbx.read_text(), before)

    def test_missing_group_is_an_error_and_writes_nothing(self):
        # The second file has no group; the first must not be written either.
        self.add_swift('SpotiglassTests/FineTests.swift')
        self.add_swift('SpotiglassTests/NoGroupHere/LostTests.swift')
        before = self.pbx.read_text()
        result = self.run_script(sys.executable, 'scripts/register-test-files.py',
                                 'FineTests.swift', 'NoGroupHere/LostTests.swift')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('no Xcode group for SpotiglassTests/NoGroupHere/', result.stderr)
        self.assertEqual(self.pbx.read_text(), before)

    def test_source_file_lands_in_the_anchor_group_and_app_target(self):
        self.add_swift('Spotiglass/Browsing/NewThing.swift')
        anchor = 'PlaylistBrowserViewModel+Home.swift'
        result = self.run_script(sys.executable, 'scripts/register-source-files.py', anchor, 'NewThing.swift')
        self.assertEqual(result.returncode, 0, result.stderr)
        project = pbxproj.Project.load(self.pbx)
        anchor_dir = [p for p in project.path_of.values() if p.endswith('/' + anchor)][0].rsplit('/', 1)[0]
        self.assertEqual(anchor_dir, 'Spotiglass/Browsing')
        self.assertIn('Spotiglass/Browsing/NewThing.swift', project.compiled_paths('Spotiglass'))
        self.assertEqual(self.run_script('scripts/audit-orphaned-sources.sh').returncode, 0)


class ParallelBranchTests(RepoCopy):
    """#377 and #378 each registered files from the same main and both got
    the same "next free" IDs, so the merged project pointed two files at one
    object. Replay that: register different files on two copies of the same
    base, then merge them the way git does."""

    def test_two_branches_get_distinct_ids_and_merge_cleanly(self):
        base = self.pbx.read_text()
        branch_files = {
            'a': ['SpotiglassTests/AlbumShelfTests.swift', 'SpotiglassTests/QueueReorderTests.swift'],
            'b': ['SpotiglassTests/MenuBarTitleTests.swift', 'SpotiglassTests/ZoomLevelTests.swift'],
        }
        results = {}
        for branch, files in branch_files.items():
            text = base
            for f in files:
                text, _ = pbxproj.register(text, f, 'SpotiglassTests')
            results[branch] = text

        def new_ids(text):
            return set(pbxproj.Project(text).objects) - set(pbxproj.Project(base).objects)

        ids_a, ids_b = new_ids(results['a']), new_ids(results['b'])
        self.assertEqual(len(ids_a), 4)
        self.assertEqual(len(ids_b), 4)
        self.assertFalse(ids_a & ids_b, 'two branches handed out the same object ID')

        paths = {}
        for name, text in (('base', base), ('a', results['a']), ('b', results['b'])):
            paths[name] = self.tmp / f'{name}.pbxproj'
            paths[name].write_text(text)
        merge = subprocess.run(
            ['git', 'merge-file', '-p', paths['a'], paths['base'], paths['b']],
            capture_output=True, text=True,
        )
        self.assertEqual(merge.returncode, 0, 'merge conflicted:\n' + merge.stdout[-2000:])

        self.pbx.write_text(merge.stdout)
        for f in branch_files['a'] + branch_files['b']:
            self.add_swift(f)
        result = self.run_script('scripts/audit-orphaned-sources.sh')
        self.assertEqual(result.returncode, 0, result.stdout)


if __name__ == '__main__':
    unittest.main()
