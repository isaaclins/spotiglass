# Spotiglass EQ — manual QA

Run `scripts/eq-qa.sh` to walk the success-criterion-5 checklist.

Each PASS/FAIL/SKIP is appended to `manual-qa-<timestamp>.log` along with a
UTC timestamp.

The install checks require a signed build on a real Mac. The first enable must
show macOS's standard authorization prompt for the Spotiglass LaunchDaemon.
The app should not show Terminal instructions or a repair button.

| # | Step | What you confirm |
|---|---|---|
| 1 | authorization + install | Enable Equalizer. macOS presents its standard authorization dialog once, then the helper copies `SpotiglassEQDriver.driver` into `/Library/Audio/Plug-Ins/HAL/`. |
| 2 | coreaudiod restart | The helper restarts `coreaudiod`; no command or log-out is required. |
| 3 | device-visible | `system_profiler SPAudioDataType` shows "Spotiglass EQ"; System Settings → Sound → Output lists it. |
| 4 | default-route | The default output device switches to Spotiglass EQ on enable. |
| 5 | preset:Flat … preset:Loudness | Each of the 7 built-ins applies; listen for the expected tonality shift. |
| 6 | save-preset | "Save preset…" with name "MyTest" lands in the Saved section + `~/.config/spotiglass/settings.json`. |
| 7 | reload-preset | After relaunch, "MyTest" is still in the picker. |
| 8 | delete-preset | Delete removes "MyTest" from both UI and settings.json. |
| 9 | disable-route | Disable restores the previous default output device. |
| 10 | silent upgrade + repair | Install an older driver, then enable with a newer app or a damaged bundle. The helper replaces it without another authorization prompt or user-facing error. |
| 11 | default-restored | Original default output is back. |
