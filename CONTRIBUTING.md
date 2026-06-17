# Contributing to Spotiglass

Thank you for your interest in improving Spotiglass. This project is a personal
macOS Spotify client; contributions are welcome within the scope below.

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

Then run `make test` to confirm the file is in the test target.

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

## Security

See [SECURITY.md](SECURITY.md) for vulnerability reporting.
