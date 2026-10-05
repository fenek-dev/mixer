# App Volume Mixer — Design

Date: 2026-10-02

## Goal

Menu bar app for macOS that sets volume per application. Personal use, not App Store.

Success: play audio in two apps, lower one from the menu bar, the other stays unchanged. Setting survives relaunch of either the app or the mixer.

## Scope

In:
- Per-app volume slider (0–150%) and mute. Above 100% is boost, through a soft limiter.
- Volumes remembered per bundle ID.
- Solo: silence every other listed app until ended. Transient; saved volumes unchanged.
- Hide an app from the list; hidden apps keep their volume and can be shown again.
- Keyboard and scroll-wheel control.
- Launch at login toggle.
- Polished native UI.

Out:
- Frequency EQ, per-app output device routing, level meters.
- macOS below 15 (process taps need 14.2; `Synchronization.Atomic` needs 15).

## Approach

Core Audio process taps (`AudioHardwareCreateProcessTap`, macOS 14.2+). For an app whose volume is not 100%:

1. Create a `CATapDescription` (stereo mixdown of the app's process objects, `muteBehavior = .mutedWhenTapped`, private).
2. Create a private aggregate device: current default output as sub-device, the tap in its tap list.
3. IOProc copies tap input to output, multiplied by gain.

At 100% and unmuted, the tap and aggregate device are destroyed, so the app's audio path is untouched.

Rejected: virtual HAL driver (admin install, much more code), per-app scripting (works for a handful of apps only).

## Units

| Unit | Purpose | Depends on |
|---|---|---|
| `AudioProcessMonitor` | Lists Core Audio process objects, resolves each to an owning app, groups helpers under the parent, publishes the app list and per-app "is playing" state. | Core Audio, `NSRunningApplication` |
| `AppGrouping` | Pure function: (pid, bundle ID, parent chain) → owning app bundle ID. | none |
| `AppVolumeController` | Owns tap + aggregate device + IOProc for one app. API: `setGain(Float)`, `invalidate()`. | Core Audio |
| `MixerEngine` | Maps bundle ID → controller. Creates or destroys controllers as volumes and the process list change. Rebuilds on default output change. | monitor, store, controller |
| `VolumeStore` | Persists `{bundleID: {volume, muted}}` in UserDefaults. | Foundation |
| `LoginItem` | Wraps `SMAppService.mainApp` register / unregister / status. | ServiceManagement |
| `MixerView` | SwiftUI popover. | engine, login item |

### Process grouping

Helper processes (for example `com.google.Chrome.helper`) play the audio for many apps. Resolution order:

1. The process itself is a regular `NSRunningApplication` (activation policy `.regular`).
2. Its responsible pid is a regular app (covers Safari's WebKit processes, whose parent is launchd). Private call `responsibility_get_pid_responsible_for_pid`.
3. Walk the parent pid chain to the first regular app.
4. Fall back to bundle ID prefix match against running regular apps.
5. Otherwise group under its own bundle ID, shown only while it is playing. Processes with no bundle ID and no owner are skipped.

One row per owning app; its tap covers all of its process objects. The tap is rebuilt when that set changes.

### Gain

Slider position `p` in 0…1.5 maps to gain `p²` (up to 2.25), so the slider feels even to the ear. When gain is above 1, samples pass through a soft limiter (transparent to 0.8 of full scale, then a tanh bend that never reaches 1); at or below 100% samples are untouched. The slider snaps to 100% within 3%, because exactly 100% is what removes the tap. Mute forces gain 0 without changing the stored volume. Gain changes ramp over ~10 ms inside the IOProc to avoid clicks. Gain is passed to the audio thread through an atomic; no locks or allocation in the IOProc.

## UI

`MenuBarExtra` with `.window` style, about 320 pt wide. No Dock icon (`LSUIElement`).

- Menu bar icon: SF Symbol `slider.vertical.3`.
- Header: "Volume Mixer".
- One row per app: 28 pt app icon, name, slider, percent readout in monospaced digits, mute button (`speaker.wave.2.fill` / `speaker.slash.fill`).
- Apps currently producing audio sort first and show a small accent dot. Idle apps with a saved non-default volume stay listed, dimmed.
- Reset to 100%: click the percent readout, or option-click the slider.
- List scrolls past eight rows. Row order is frozen while the pointer is inside the list.
- Keyboard: up/down select a row, left/right change it by 5% (1% with shift), `m` mute, `s` solo, `0` silence, `1` reset.
- Scroll wheel over a slider changes that app's volume.
- Row context menu: Solo, Reset to 100%, Hide from List.
- Solo banner with "End Solo" while a solo is active.
- VoiceOver labels on sliders and buttons.
- Popover state refreshes each time its window becomes key.
- Empty state: "No apps playing audio".
- Footer: "Launch at login" toggle, "Show N hidden" link when apps are hidden, Quit button.
- Standard system materials, accent color and fonts. Dark appearance only, regardless of system setting. Row insert and remove animated.

## Launch at login

`SMAppService.mainApp`. Toggle reflects the live status on every popover open, because the user can change it in System Settings. Registration failure shows an inline message under the toggle.

## Permissions

`NSAudioCaptureUsageDescription` in Info.plist. No public API reports this permission, so state is read through TCC's private preflight call (falls back to "granted" and the system's own prompt if the symbol is missing). The app requests access the first time a volume leaves 100%. If denied, the popover shows a banner with a button that opens Privacy & Security settings; sliders are disabled until granted.

## Errors

- Tap or aggregate device creation fails for one app: that row shows a warning icon; moving its slider retries. Other rows keep working.
- Default output device changes: all active controllers are rebuilt on the new device.
- Audio server restart, wake from sleep, output sample-rate change: same rebuild. A replacement tap starts before the old one stops.
- Output device with its own inputs (headset): those input streams are switched off for the IOProc so the mic is not opened; the tap is read as the last two input channels.
- App quits: its controller is invalidated; saved volume stays in the store.
- Mixer quits: all taps destroyed, so every app returns to full volume.

## Build

SwiftPM package, two targets: `MixerCore` (library, everything except UI) and `VolumeMixer` (executable, SwiftUI). `scripts/build.sh` builds release, assembles `VolumeMixer.app` with Info.plist, signs it (Apple Development identity if one exists, otherwise ad-hoc, which resets the permission grant on each rebuild), and prints a short summary. `scripts/install.sh` copies it to `/Applications` (needed for a stable login item and a stable permission grant).

## Testing

Unit tests (`MixerCoreTests`):
- `VolumeStore`: round trip, defaults, mute independent of volume.
- `AppGrouping`: helper under parent, prefix fallback, unknown process.
- Gain curve and ramp.
- `MixerEngine` with a fake controller factory: controller created when volume leaves 100%, destroyed when it returns, rebuilt on device change.

Manual: play audio in two apps, move one slider, mute, switch output device, relaunch both the app and the mixer, toggle launch at login and check System Settings.
