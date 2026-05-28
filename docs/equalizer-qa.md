# Spotiglass EQ — manual QA

Run `scripts/eq-qa.sh` to walk the success-criterion-5 checklist.

Each PASS/FAIL/SKIP is appended to `manual-qa-<timestamp>.log` along with a
UTC timestamp.

Steps:

| # | Step | What you confirm |
|---|---|---|
| 1 | install | Enable toggle copies `SpotiglassEQDriver.driver` into `~/Library/Audio/Plug-Ins/HAL/`. |
| 2 | coreaudiod kickstart | `sudo launchctl kickstart -k system/com.apple.audio.coreaudiod` (or log-out/in) makes the driver visible. |
| 3 | device-visible | `system_profiler SPAudioDataType` shows "Spotiglass EQ"; System Settings → Sound → Output lists it. |
| 4 | default-route | Default output device switches to Spotiglass EQ on enable. |
| 5 | preset:Flat … preset:Loudness | Each of the 7 built-ins applies; listen for the expected tonality shift. |
| 6 | save-preset | "Save preset…" with name "MyTest" lands in the Saved section + `~/.config/spotiglass/settings.json`. |
| 7 | reload-preset | After relaunch, "MyTest" is still in the picker. |
| 8 | delete-preset | Delete removes "MyTest" from both UI and settings.json. |
| 9 | disable-route | Disable restores the previous default output device. |
| 10 | uninstall | Removing the `.driver` makes the device disappear after the next coreaudiod refresh. |
| 11 | default-restored | Original default output is back. |
