# Contributing to Wax

Thank you for your interest in improving Wax. This project is a personal
macOS client for Spotify and Apple Music; contributions are welcome within the scope below.

## License

By contributing, you agree that your contributions will be licensed under the
same terms as the repository. See [LICENSE](LICENSE) for use restrictions
(personal / non-commercial vs commercial licensing).

## Before you start

1. Read [docs/getting-started.md](docs/getting-started.md) for Spotify setup.
2. Read [docs/architecture.md](docs/architecture.md) for module layout.
3. Check open work in the [issue tracker](https://github.com/isaaclins/spotiglass/issues).

## Build and test

From the repository root:

```sh
make build          # Debug build
make test           # unit tests (unsigned: make test UNSIGNED=1)
make coverage       # tests + coverage report
```

See [docs/building-and-testing.md](docs/building-and-testing.md) for Xcode,
Release bundles, and coverage gates.

## Code style

Run formatting locally when you touch Swift files:

```sh
make format         # requires swift-format (see docs/building-and-testing.md)
```

Avoid drive-by reformatting of unrelated files in the same change.

## Adding a new test file

The Xcode project uses explicit file references. After adding
`SpotiglassTests/YourTests.swift`:

```sh
python3 scripts/register-test-files.py YourTests.swift
```

Running it again for the same file changes nothing, and the object IDs it
writes are derived from the file's path, so two branches adding different
files do not collide. Main-target files go through
`scripts/register-source-files.py` the same way.
`./scripts/audit-orphaned-sources.sh` then confirms every Swift file is in its
target's Sources phase exactly once, and `make test` confirms it compiles.

## Parallel work / merge conflicts

If other agents or branches are active, avoid editing these areas unless you
own that slice:

- `Spotiglass/CommandPalette/`
- `Spotiglass/Views/`
- `Spotiglass/Playback/Session/`
- `Spotiglass/Playback/QueueViewModel.swift`
- `Spotiglass/Auth/`
- `Spotiglass/Browsing/`
- `Spotiglass/Services/`
- `SpotiglassTests/` (when a test rework is in flight)

Coordinate before editing `Spotiglass.xcodeproj/project.pbxproj`.

## Pull requests

1. Keep changes focused; one concern per PR when possible.
2. Update the narrowest doc in `docs/` if behavior or setup changes (start
   from [docs/README.md](docs/README.md), the doc index).
3. Do not commit secrets, `.env` files, or Keychain exports.
4. Confirm `make build` (and `make test` when you change testable logic).
5. Fill in the [pull request template](.github/pull_request_template.md): the
   issue it fixes, what changed for the user, how you tested it, and before and
   after screenshots in light and dark mode for anything visible.
6. Keep VoiceOver labels, keyboard access and Reduce Motion working when you
   touch the UI. [ACCESSIBILITY.md](ACCESSIBILITY.md) says what the app
   supports today.

## Accessibility

See [ACCESSIBILITY.md](ACCESSIBILITY.md) for what Wax supports, what doesn't
work yet, and how to report a barrier.

## Security

See [SECURITY.md](SECURITY.md) for vulnerability reporting.
