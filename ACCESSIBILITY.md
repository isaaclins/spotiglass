# Accessibility

I want Wax to work for people who use VoiceOver, the keyboard, or the macOS accessibility display settings. This page says what works today, what doesn't yet, and how to tell me when something gets in your way.

It covers Wax on macOS **26** or newer, the only version it runs on. Everything here applies to both Spotify and Apple Music unless it says otherwise.

## What works

### VoiceOver

- Buttons, rows and controls have spoken labels, and many have a hint that says what they do. Icon-only buttons (play, skip, shuffle, repeat, queue, lyrics) are labelled too.
- The track list is a standard macOS list: select a row and press Return to play it. Queue rows, album cards on artist pages, breadcrumb segments and command palette results have labels and an action that plays or opens them, so they aren't read as plain text.
- Sliders you can change with VoiceOver's adjust gesture: the seek bar, the volume slider and every equalizer band. Each speaks its own value, and each equalizer band says which frequency it is.
- A track's Explicit and Unavailable badges are spoken, not only shown.
- Right-click menus on playlists, albums and artists are also offered as VoiceOver actions.
- Decorative images and animations are hidden from VoiceOver so they don't add noise.

### Keyboard

- The app's commands live in the View, Playback and Help menus, so the usual macOS ways of reaching the menu bar from the keyboard work, and most of them have a shortcut.
- The command palette (⌘K by default) runs any command by name: type `>` and then part of its name, for example `> lyrics`. Without `>` it searches the service on screen. Use the up and down arrows to move, Return to choose, Tab and Shift+Tab to switch the search category, and Esc to close.
- You can change every shortcut in **Settings → Keyboard**: search for a command, click its field and press the keys you want. If another command already has those keys, it tells you which one and lets you move them. Space plays and pauses by default, but never while you are typing in a text field.
- Equalizer bands take the keyboard when focused: the arrow keys move a band up or down.
- On the Spotify sign-in screen, Return connects and Esc cancels, the way Mac dialogs do.

[docs/getting-started.md](docs/getting-started.md) lists the default shortcuts and how the palette searches.

### Display settings

- **Reduce Motion**: the playing-track waveform, the scrolling of long titles in the player bar, the lyrics scroll and fades, the command palette transitions and the artwork loading spinner stop animating.
- **Reduce Transparency**: the app's panels and full-window backgrounds become solid, and the lyrics edge fades turn off.
- **Increase Contrast**: the seek bar track and the outlines of the app's panels get stronger.
- **Appearance**: Wax follows Light and Dark mode, or you can pick one in **Settings → Appearance**.
- **Language**: English, Spanish and German. Wax follows your macOS language when it is one of those, or you can choose in **Settings → Appearance**.

### Text size

macOS has no Dynamic Type for Mac apps, so Wax has none either. Most text uses the standard macOS text styles, so it stays as large as the rest of your Mac. Lyrics have their own text size in **Settings → Appearance**, with a preview.

## What doesn't work yet

- Many surfaces outside Settings and the track list are custom-built rather than standard Mac controls. They have labels and actions, but VoiceOver and Full Keyboard Access may not move through them as smoothly as through a native app ([#173](https://github.com/isaaclins/wax/issues/173)).
- Error messages show up in different ways in different places, so one can appear without being announced the same way as another ([#608](https://github.com/isaaclins/wax/issues/608)).
- Lyrics don't follow the macOS text size; they only follow their own setting in **Settings → Appearance**.
- I haven't checked Wax with Voice Control or Switch Control.

Open accessibility issues are under the [accessibility label](https://github.com/isaaclins/wax/issues?q=is%3Aissue+is%3Aopen+label%3Aaccessibility).

## Reporting a barrier

If something in Wax stops you from doing what you wanted, please [open an issue](https://github.com/isaaclins/wax/issues/new?template=bug_report.yml) and include:

- what you were trying to do,
- what you use (VoiceOver, keyboard only, Reduce Motion, a larger text size, and so on),
- what happened, and what you expected,
- your Wax version (**Wax → About Wax**) and your macOS version.

I treat an accessibility barrier as a bug, not a feature request.
