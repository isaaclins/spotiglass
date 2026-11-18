<!--
Thanks for the pull request. Fill in what applies and delete what doesn't.
If nothing on screen changes, delete the "How it looks" section.
-->

## How it looks

<!-- Anything visible: before and after, in light and dark mode.
Use screenshot mode (docs/screenshots.md) so no real library shows up. -->

| | Before | After |
|---|---|---|
| Light | | |
| Dark | | |

## What it fixes

Fixes #

## What changed for the user

<!-- One or two sentences, in the words someone using Wax would use. -->

## How I tested it

- [ ] `make build` and `make test` pass
- [ ] A test replays the real failure (not only that the code runs)
- [ ] Tried in the real app with: Spotify / Apple Music / both / not needed (say why)
- [ ] VoiceOver, keyboard and Reduce Motion still work where this changes the UI ([ACCESSIBILITY.md](https://github.com/isaaclins/wax/blob/main/ACCESSIBILITY.md))

<!-- What you did in the app and what you saw. -->

## Security

<!-- Only when it applies; delete the rest. -->

- [ ] Privileged code (the equalizer helper, driver or install path): who can call it, how that is checked, and what it writes as root
- [ ] Data from outside (Spotify, Apple Music, lyrics, the update feed, the sign-in callback) is checked before it is used
- [ ] No tokens, codes, search text or library contents in the log or in files outside the Keychain
- [ ] Dependency updates name the version's security advisories
