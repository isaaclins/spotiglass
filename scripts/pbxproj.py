"""
Read and edit Spotiglass.xcodeproj/project.pbxproj without Xcode.

Shared by audit-orphaned-sources.sh, register-test-files.py and
register-source-files.py so all three agree on what "in a target" means.

Reading parses the whole file (an old-style ASCII property list) into
objects. Writing never re-serializes it: new entries are inserted as text
lines at positions found from the parse, so Xcode's own formatting and
comments stay untouched and every other line of the diff is unchanged.

Standard library only, so it runs on the Linux CI runner.
"""
import fnmatch
import hashlib
import posixpath
import re
from pathlib import Path, PurePosixPath

PBX_PATH = Path('Spotiglass.xcodeproj/project.pbxproj')

# Which target must compile the Swift files under each top-level directory.
TARGET_FOR_DIR = {
    'Spotiglass': 'Spotiglass',
    'SpotiglassTests': 'SpotiglassTests',
}


class PBXError(Exception):
    """Raised for anything that would leave the project half-edited."""


# ---------------------------------------------------------------------------
# Parsing


_BARE = re.compile(r'[A-Za-z0-9_$/:.\-+<>]+')


class _Parser:
    def __init__(self, text):
        self.text = text
        self.i = 0

    def _skip(self):
        t = self.text
        while self.i < len(t):
            c = t[self.i]
            if c in ' \t\r\n':
                self.i += 1
            elif t.startswith('/*', self.i):
                end = t.find('*/', self.i + 2)
                if end < 0:
                    raise PBXError('unterminated comment')
                self.i = end + 2
            elif t.startswith('//', self.i):
                end = t.find('\n', self.i)
                self.i = len(t) if end < 0 else end + 1
            else:
                return

    def _expect(self, ch):
        self._skip()
        if self.text[self.i:self.i + 1] != ch:
            raise PBXError(f'expected {ch!r} at offset {self.i}')
        self.i += 1

    def value(self):
        self._skip()
        c = self.text[self.i:self.i + 1]
        if c == '{':
            self.i += 1
            out = {}
            while True:
                self._skip()
                if self.text[self.i:self.i + 1] == '}':
                    self.i += 1
                    return out
                key = self.value()
                self._expect('=')
                out[key] = self.value()
                self._expect(';')
        if c == '(':
            self.i += 1
            out = []
            while True:
                self._skip()
                if self.text[self.i:self.i + 1] == ')':
                    self.i += 1
                    return out
                out.append(self.value())
                self._skip()
                if self.text[self.i:self.i + 1] == ',':
                    self.i += 1
        if c == '"':
            j = self.i + 1
            buf = []
            while self.text[j] != '"':
                if self.text[j] == '\\':
                    j += 1
                    c = self.text[j]
                    hex4 = re.match(r'[0-9A-Fa-f]{1,4}', self.text[j + 1:j + 5]) if c == 'U' else None
                    octal = re.match(r'[0-7]{1,3}', self.text[j:j + 3])
                    if hex4:
                        # \Uxxxx, as Apple's parser reads it.
                        buf.append(chr(int(hex4.group(0), 16)))
                        j += len(hex4.group(0))
                    elif octal:
                        buf.append(chr(int(octal.group(0), 8)))
                        j += len(octal.group(0)) - 1
                    else:
                        buf.append({'n': '\n', 't': '\t', 'r': '\r'}.get(c, c))
                else:
                    buf.append(self.text[j])
                j += 1
            self.i = j + 1
            return ''.join(buf)
        m = _BARE.match(self.text, self.i)
        if not m:
            raise PBXError(f'unexpected {c!r} at offset {self.i}')
        self.i = m.end()
        return m.group(0)


class Project:
    def __init__(self, text):
        self.text = text
        root = _Parser(text).value()
        self.objects = root['objects']
        self.root_id = root['rootObject']
        self._resolve_paths()

    @classmethod
    def load(cls, path=PBX_PATH):
        return cls(Path(path).read_text())

    def _resolve_paths(self):
        """Repo-relative path of every file reference and group, walking the
        group tree from the main group the way Xcode does."""
        self.path_of = {}
        self.parent_of = {}
        main = self.objects[self.root_id]['mainGroup']

        def walk(obj_id, parent_dir):
            obj = self.objects[obj_id]
            tree = obj.get('sourceTree', '<group>')
            own = obj.get('path')
            if tree == 'SOURCE_ROOT':
                base = PurePosixPath(own or '.')
            elif tree == '<group>':
                base = parent_dir / own if own else parent_dir
            else:
                return  # built products, SDK paths: not files in the repo
            # Normalise `a/../b` so two references to the same file compare
            # equal and a duplicate cannot hide behind a different spelling.
            base = PurePosixPath(posixpath.normpath(str(base)))
            self.path_of[obj_id] = str(base)
            for child in obj.get('children', []):
                self.parent_of[child] = obj_id
                walk(child, base)

        walk(main, PurePosixPath('.'))

    def targets(self):
        return {
            obj['name']: oid
            for oid, obj in self.objects.items()
            if obj.get('isa') == 'PBXNativeTarget'
        }

    def sources_phase(self, target_name):
        target_id = self.targets().get(target_name)
        if target_id is None:
            raise PBXError(f'no target named {target_name}')
        for phase in self.objects[target_id]['buildPhases']:
            if self.objects[phase].get('isa') == 'PBXSourcesBuildPhase':
                return phase
        raise PBXError(f'target {target_name} has no Sources phase')

    def source_path_list(self, target_name):
        """Repo-relative paths in `target_name`'s Sources phase, one per
        build-file entry, so a file listed twice appears twice."""
        out = []
        for build_id in self.objects[self.sources_phase(target_name)].get('files', []):
            ref = self.objects.get(build_id, {}).get('fileRef')
            if ref in self.path_of:
                out.append(self.path_of[ref])
        return out

    def _configurations(self, target_name):
        """{configuration name: build settings} for `target_name`, with the
        project's settings of the same configuration underneath the target's,
        the way Xcode layers them."""
        def by_name(list_id):
            out = {}
            for conf in self.objects.get(list_id, {}).get('buildConfigurations', []):
                obj = self.objects[conf]
                out[obj.get('name', conf)] = obj.get('buildSettings', {})
            return out
        project = by_name(self.objects[self.root_id].get('buildConfigurationList'))
        target = by_name(self.objects[self.targets()[target_name]].get('buildConfigurationList'))
        return {name: {**project.get(name, {}), **settings} for name, settings in target.items()}

    @staticmethod
    def _patterns(settings, key):
        """Patterns `key` lists for a macOS build, including conditional
        variants such as `KEY[sdk=macosx*]` (variants for other SDKs are
        ignored)."""
        out = []
        for name, value in settings.items():
            if name != key and not name.startswith(key + '['):
                continue
            sdks = re.findall(r'sdk=([^\],]+)', name)
            if sdks and not any(fnmatch.fnmatchcase('macosx', s) or s.startswith('macosx') for s in sdks):
                continue
            for item in [value] if isinstance(value, str) else value:
                out.extend(item.split())
        return out

    def exclusion_reason(self, build_id, target_name):
        """Why the build file `build_id` in the Sources phase is still not
        compiled on macOS, or None when it is."""
        build = self.objects.get(build_id, {})
        filters = build.get('platformFilters') or ([build['platformFilter']] if 'platformFilter' in build else [])
        if filters and 'macos' not in filters:
            return f'has platform filter {", ".join(filters)} (not macos)'
        path = self.path_of.get(build.get('fileRef'), '')
        candidates = (path, PurePosixPath(path).name)
        # Each configuration on its own: an inclusion in Release does not
        # bring a file back into Debug.
        for name, settings in sorted(self._configurations(target_name).items()):
            def hits(key):
                return any(fnmatch.fnmatchcase(c, pat) for pat in self._patterns(settings, key) for c in candidates)
            if hits('EXCLUDED_SOURCE_FILE_NAMES') and not hits('INCLUDED_SOURCE_FILE_NAMES'):
                return f'is excluded by EXCLUDED_SOURCE_FILE_NAMES in {name}'
        return None

    def excluded_paths(self, target_name):
        """{path: reason} for Sources entries the build skips anyway."""
        out = {}
        for build_id in self.objects[self.sources_phase(target_name)].get('files', []):
            reason = self.exclusion_reason(build_id, target_name)
            if reason:
                out[self.path_of.get(self.objects[build_id].get('fileRef'), '')] = reason
        return out

    def compiled_paths(self, target_name):
        """Paths `target_name` really compiles on macOS."""
        excluded = self.excluded_paths(target_name)
        return {p for p in self.source_path_list(target_name) if p not in excluded}

    def file_refs_for(self, path):
        return [
            oid for oid, p in self.path_of.items()
            if p == path and self.objects[oid].get('isa') == 'PBXFileReference'
        ]

    def group_for_dir(self, directory):
        for oid, p in self.path_of.items():
            if p == directory and self.objects[oid].get('isa') == 'PBXGroup':
                return oid
        return None


# ---------------------------------------------------------------------------
# Audit


def audit(repo_root='.'):
    """Return (path, problem) for every Swift file on disk that its target
    does not compile."""
    root = Path(repo_root)
    project = Project.load(root / PBX_PATH)
    problems = []
    compiled_by = {t: project.compiled_paths(t) for t in project.targets()}
    for directory, target in TARGET_FOR_DIR.items():
        listed = project.source_path_list(target)
        compiled = project.compiled_paths(target)
        excluded = project.excluded_paths(target)
        for file in sorted((root / directory).rglob('*.swift')):
            rel = file.relative_to(root).as_posix()
            # A test helper also compiled into the app or the privileged helper
            # ships test code, and an app file also in the test target is
            # compiled twice. App files shared with the privileged helper are
            # fine (EqualizerPrivilegedHelperIdentity.swift is on purpose).
            for other, paths in compiled_by.items():
                shared_app_file = target == 'Spotiglass' and other not in TARGET_FOR_DIR.values()
                if other != target and rel in paths and not shared_app_file:
                    problems.append((rel, f'is also compiled by the {other} target'))
            refs = len(project.file_refs_for(rel))
            if refs > 1:
                problems.append((rel, f'has {refs} file references (registered twice)'))
            if listed.count(rel) > 1:
                problems.append((rel, f'is in the {target} Sources phase {listed.count(rel)} times'))
            if rel in compiled:
                continue
            if rel in excluded:
                problems.append((rel, f'is in the {target} Sources phase but {excluded[rel]}'))
            elif refs:
                problems.append((rel, f'in the project but not in the {target} target\'s Sources phase'))
            else:
                problems.append((rel, 'not in the Xcode project at all'))
    return problems


# ---------------------------------------------------------------------------
# Registering


def stable_id(role, path):
    """An object ID derived from the file's path, so two branches that add
    different files can never hand out the same ID, and the same file always
    gets the same ID."""
    digest = hashlib.sha1(f'spotiglass:{role}:{path}'.encode()).hexdigest()
    return digest[:24].upper()


def _quote(value):
    return value if re.fullmatch(r'[A-Za-z0-9._/]+', value) else f'"{value}"'


def _object_span(text, obj_id):
    """Offsets of the `{ ... };` body of a multi-line object definition."""
    m = re.search(rf'^\t\t{re.escape(obj_id)}(?: /\*.*?\*/)? = \{{\n', text, re.M)
    if not m:
        raise PBXError(f'could not find the definition of {obj_id}')
    end = text.find('\n\t\t};\n', m.end())
    if end < 0:
        raise PBXError(f'could not find the end of {obj_id}')
    return m.end(), end


def _insert_list_item(text, obj_id, key, line):
    start, end = _object_span(text, obj_id)
    m = re.compile(rf'^\t\t\t{key} = \(\n(.*?)^\t\t\t\);\n', re.M | re.S).search(text, start, end)
    if not m:
        raise PBXError(f'could not find {key} of {obj_id}')
    return _insert_after_predecessor(text, m.start(1), m.end(1), line, _entry_name)


def _entry_name(line):
    m = re.search(r'/\* (.*?) \*/', line)
    return (m.group(1) if m else '').lower()


def _insert_in_section(text, section, line):
    begin = f'/* Begin {section} section */\n'
    finish = f'/* End {section} section */\n'
    s = text.find(begin)
    e = text.find(finish)
    if s < 0 or e < 0:
        raise PBXError(f'could not find the {section} section')
    return _insert_after_predecessor(text, s + len(begin), e, line, _entry_name)


def _insert_after_predecessor(text, start, end, line, key):
    """Insert `line` right after the existing entry whose key is the largest
    one below the new line's key, wherever that entry sits.

    Xcode does not keep these lists sorted, so appending would put every
    branch's new line at the same spot and every parallel registration would
    conflict on merge. Placing each line next to its own neighbour means two
    branches adding different files usually touch different parts of the file.
    """
    new_key = key(line)
    best_key, pos = None, start
    cursor = start
    while cursor < end:
        nl = text.index('\n', cursor) + 1
        k = key(text[cursor:nl])
        if k < new_key and (best_key is None or k > best_key):
            best_key, pos = k, nl
        cursor = nl
    return text[:pos] + line + '\n' + text[pos:]


def register(text, path, target_name):
    """Make `target_name` compile the file at repo-relative `path`.

    Returns (new_text, message). Registering a file that is already compiled
    by the target returns the text unchanged. Raises PBXError instead of
    writing a partial edit.
    """
    project = Project(text)
    path = posixpath.normpath(PurePosixPath(path).as_posix())
    name = PurePosixPath(path).name
    sources = project.sources_phase(target_name)

    refs = project.file_refs_for(path)
    if len(refs) > 1:
        raise PBXError(f'{path} has {len(refs)} file references; remove the duplicates first')
    if path in project.compiled_paths(target_name):
        return text, f'skip (already in {target_name}): {path}'
    excluded = project.excluded_paths(target_name).get(path)
    if excluded:
        raise PBXError(f'{path} is in {target_name} but {excluded}; fix that in Xcode instead of registering it again')

    if refs:
        ref_id = refs[0]
    else:
        directory = str(PurePosixPath(path).parent)
        group = project.group_for_dir(directory)
        if group is None:
            raise PBXError(f'no Xcode group for {directory}/; add the group in Xcode first')
        ref_id = stable_id('ref', path)
        if ref_id in project.objects:
            raise PBXError(f'ID {ref_id} for {path} is already used')
        text = _insert_in_section(
            text, 'PBXFileReference',
            f'\t\t{ref_id} /* {name} */ = {{isa = PBXFileReference; '
            f'lastKnownFileType = sourcecode.swift; path = {_quote(name)}; sourceTree = "<group>"; }};',
        )
        text = _insert_list_item(text, group, 'children', f'\t\t\t\t{ref_id} /* {name} */,')

    build_id = stable_id(f'build:{target_name}', path)
    if build_id in project.objects:
        raise PBXError(f'ID {build_id} for {path} is already used')
    text = _insert_in_section(
        text, 'PBXBuildFile',
        f'\t\t{build_id} /* {name} in Sources */ = {{isa = PBXBuildFile; '
        f'fileRef = {ref_id} /* {name} */; }};',
    )
    text = _insert_list_item(text, sources, 'files', f'\t\t\t\t{build_id} /* {name} in Sources */,')

    # Prove the edit did what it claims before anyone writes it to disk.
    if path not in Project(text).compiled_paths(target_name):
        raise PBXError(f'registering {path} did not add it to {target_name}')
    return text, f'registered {path}  (build={build_id}, ref={ref_id})'


def register_files(paths, target_name, pbx=PBX_PATH):
    """Register every path or none of them."""
    text = Path(pbx).read_text()
    original = text
    for path in paths:
        text, message = register(text, path, target_name)
        print(message)
    if text != original:
        Path(pbx).write_text(text)
