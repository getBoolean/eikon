# 03 · Native Kirikiri

## Purpose

Run Kirikiri games natively on iOS, with no x86 emulation, through a port of Kirikiroid2 (https://github.com/zeas2/Kirikiroid2, by zeas2 and contributors). This is the owner's chosen first route to a real game on a device. It needs no JIT and no device gate, so it works in both builds, and it covers 21 folders in the collection.

## Read first

- `planning/requirements.md`: Goal 3. "Native engines", "Games to support" (Kirikiri row), "Licensing", "Constraints" (upstream code stays clean, no titles), "Test data".
- `planning/deep_project_interview.md`.
- `planning/02-app-shell/spec.md` for the runtime interface and session host.

## Scope

**In:**
- Kirikiroid2 as a submodule pinned at a commit, with iOS changes as patch files. Build it for iOS arm64 with 01's build system.
- Audit its dependency tree and licenses (Kirikiri 2 / KirikiriZ, and the bundled libraries). Kirikiroid2 is BSD-style. Its Kodi-derived video player may ship (Eikon is GPL-3.0-or-later). The Android-only AmazeFileManager storage code (GPL-3.0) is left out. Credit everything.
- iOS host layer: rendering (Kirikiroid2's Android renderer is GL-based. **Open decision:** OpenGL ES on iOS, which is deprecated but present, vs a Metal backend or a translation layer), audio, video playback, file access to the game folder, and lifecycle (pause on background).
- Implement 02's runtime interface for this route.
- Work out what the native route can't handle, and report it to the route picker with a reason: games that need x86 `.tpm` plugins, and archives whose encryption lives in a plugin. Those fall back to Wine (a later split). Record which plugin file names appear in the collection by name only, using 02's scanner.
- Minimal direct touch (tap = click, and advancing text) so a game can be played. 04 replaces it with the shared input layer.
- Leave hooks for later splits, even if unused yet: where message text is drawn (capture point for 11), where save data is written (save location for 12), and how text encoding is chosen (Shift-JIS by default, for 09).

**Out:** full input mapping (04), translation (11), sync (12), and the Wine fallback itself.

## Needs

- 01 (build and credits) and 02 (runtime interface, identity, settings).

## Provides

- The first working route, and the first consumer of 04's input interface.
- A text-capture point (11), a save location (12), and an encoding hook (09).

## Constraints to carry

- Test content is original. Build an original `.xp3` test game (KAG scenario, image, sound, a save) as the acceptance fixture. Real games from `/Volumes/Games` are extra evidence only, reported by hash.
- Must run in the no-JIT build: no generated code.

## Done when

- The original `.xp3` test game runs on a device from the library: it shows text and images, plays sound, takes taps, and saves and loads.
- Games needing `.tpm` plugins or plugin-based encryption show "falls back to Wine" with the reason.
- The license audit is written and every component is credited in the app.
