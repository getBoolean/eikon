# 02 · App shell

## Purpose

The app the user sees: a game library, detection of each game's engine and architecture, a hash-based identity for every game, the choice of route (and why) given the current build, device, and install method, per-game settings, a capability screen, and in-app credits. It also defines the interfaces that every runtime (native engines, Wine, Linux) plugs into.

## Read first

- `planning/requirements.md`: "Games to support", "App", "Builds and JIT" (route display), "Constraints" (no program titles, games run in the app process), "Test data".
- `planning/deep_project_interview.md`.
- `planning/01-build-packaging-jit/spec.md` for what 01 provides.

## Scope

**In:**
- **Import:** bring game folders into the app, or reference them (Files app, document picker, and direct paths where the unsandboxed builds allow). Decide where game data lives per install method.
- **Identity:** a hash of the main executable or main archive (such as `Game.exe` or `data.xp3`) keys everything: settings, saves, FEX overrides, the glossary. The display name is whatever the user chooses. Nothing logs or exports titles.
- **Detection:**
  - Unity (`UnityPlayer.dll`, plus `GameAssembly.dll` for IL2CPP)
  - Kirikiri (`.xp3`, plus `.tpm` plugins)
  - Ren'Py (its directory layout and version)
  - GameMaker (`data.win`)
  - BGI (`BGI.exe`)
  - Also: the PE machine type (i386 or amd64), and Linux ELF x86-64.
- **Route picker:** given the engine, architecture, build flavor, JIT state (from 01), and device gate results (recorded later by 05 and 07), choose a route: native Kirikiri, native Ren'Py, Wine+FEX, Wine+Box64, Linux+FEX, or unavailable. Every choice comes with a human-readable reason. Native routes are tried first, with the Wine route as fallback. The user can override the choice per game.
- **Runtime interface:** a protocol each route implements (a can-run verdict with a reason, launch into a host view, pause/resume, stop). It also includes a game-session host view controller that owns app lifecycle: going to the background pauses the game and stops Metal drawing. Since games run in-process, a crash in a game ends the app; decide what the app records so it can report that on the next launch.
- **Per-game settings,** stored in a **CRDT-ready shape** (value, timestamp, and device id per field) so 12 can sync them without a migration. Settings include route override, FEX overrides (filled by 05), controls (04), and code page (09).
- **Capability screen:** what this build, device, and install method can run, and why anything is unavailable.
- **Credits screen,** fed by 01's pipeline.
- App text externalized from the start, so 09 can localize it.
- A **collection scanner** for `/Volumes/Games` (dev Mac only, read-only). It tests detection against the real collection and prints only counts, engine names, plugin file names, and hashes. It's skipped when the mount is absent.

**Out:** running any game (03 onward), and input mapping (04).

## Needs

- 01: the build, the JIT detection API, the device-report format, the credits data.

## Provides

- The runtime interface and session host (03, 06–08, 10, 13, 14).
- Game identity by hash (every split).
- The per-game settings store (04, 05, 09, 11, 12).
- The route picker, which later splits register with.

## Done when

- Original test game folders for each engine type are detected correctly, and each shows a route and a reason that fit the build and JIT state.
- The scanner run against the mount reproduces the requirements table's counts (by engine, not by title).
- Settings persist per hash, and the capability and credits screens show real data.
