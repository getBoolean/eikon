# 10 · Native Ren'Py

## Purpose

Run Ren'Py games natively on iOS: the game's own scripts on an iOS build of Ren'Py that matches the game's Ren'Py version, with no x86 emulation. Games this route can't handle fall back to Wine. It works in both builds.

## Read first

- `planning/requirements.md`: Goal 3. "Native engines", "Games to support" (Ren'Py row), "Known risks" (version matching, x86 native extensions), "Licensing".
- `planning/deep_project_interview.md`.
- `planning/02-app-shell/spec.md` (runtime interface) and `planning/04-input/spec.md`.

## Scope

**In:**
- **Version detection** from a game's files (the bundled `renpy/` sources, or `.rpyc`/`.rpa` markers). Ren'Py 6 and 7 use Python 2.7. Ren'Py 8 uses Python 3.
- **Runtime strategy.** **Open decision:** which version families to ship, how closely a runtime must match a game, and how several runtimes (separate libpython builds) coexist in one app. Only one Python interpreter can run in a process at a time, so switching may need a relaunch. Ren'Py's own iOS support (renios) is the starting point.
- All native modules are compiled into the app and signed. Nothing is generated at run time, so it works without JIT.
- Detect games that ship native Python extensions built for x86 (`.pyd`/`.so`) or depend on anything else the native route can't provide, and route them to Wine with a reason.
- An iOS host through 02's runtime interface: SDL on the session view, audio, lifecycle, and input from 04 (touch, keyboard, controller, and text entry).
- Hooks for later splits: say/dialogue text (a capture point for 11), save directory (for 12), and fonts (from 09).
- Credits: Ren'Py (MIT), Python (PSF), SDL (zlib), and every other bundled library.

**Out:** the Wine fallback itself (it needs 08), and translation.

## Needs

- 02, 04, and 01's build.

## Provides

- A native route for Ren'Py, and its capture point, save location, and font needs.

## Done when

- Original Ren'Py test games, one per supported version family, run on a device: dialogue, images, sound, a menu choice, save and load.
- A test game with an x86 extension is routed to Wine with a reason.
