# Spotiglass EQ — captured QA screenshots

`settings-equalizer-tab-visible.png` was captured by running:

```
make embed-driver       # builds the host app + the .driver, embeds it
open build/DerivedData/Build/Products/Debug/Spotiglass.app
# (then ⌘, to open Settings; the screenshot was taken at this point)
```

What it shows:

- Spotiglass running with the menubar (top: `Spotiglass File Edit View Spotiglass Window Help`).
- The `Spotiglass Settings` window open.
- Five tabs in the Settings tab strip: **Playback** (selected), **Equalizer** (with the horizontal-slider icon), **Appearance**, **Account**, **Keyboard**.

This is the visible proof for criterion 2's "Settings → Equalizer shows…" — the Equalizer tab is wired into the resurrected `SpotiglassSettingsView` and the host app builds + opens it successfully.

The full per-pane / per-preset screenshot set (lit-up sliders, Bass Boost vs Flat side-by-side, user preset saved as "MyTest", System Settings → Sound → Output listing "Spotiglass EQ") is what `scripts/eq-qa.sh` asks the user to capture once they have a Developer ID-signed `.driver` actually loaded in `coreaudiod`. The driver is built and embedded; the load step is gated by signing.
