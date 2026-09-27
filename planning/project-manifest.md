<!-- SPLIT_MANIFEST
01-build-packaging-jit
02-app-shell
03-native-kirikiri
04-input
05-fexcore-ios
06-wine-core
07-wine-wow64-guest-window
08-wine-media
09-languages
10-native-renpy
11-translation
12-cloud-saves
13-linux-games
14-nojit-box64
END_MANIFEST -->

# Eikon project manifest

Source: `planning/requirements.md` (which wins over everything else) and `planning/deep_project_interview.md`. The old stage plans in `planning/old-stages/` are not inputs.

The repo has no app code yet. Split 01 creates the project.

## Splits

| # | Split | Purpose | Ends with |
|---|---|---|---|
| 01 | build-packaging-jit | Build system, the three builds (deb, `.tipa`, `.ipa`), signing and entitlements, automatic JIT on Dopamine and TrollStore, JIT detection, license, credits pipeline, publishing to `eikon-source` | An empty app that installs on all three methods and reports whether it has JIT |
| 02 | app-shell | Game library, import, engine detection and hashing by main executable or archive, the route picker (with its reasons), per-game settings, the capability screen, the in-app credits | The library recognizes an engine and shows a route for original test content |
| 03 | native-kirikiri | An iOS port of Kirikiroid2 (xp3, KAG, audio, video), with a license audit, and a hand-off to Wine for games it can't run (`.tpm` plugins, encryption) | An original `.xp3` test game runs on a device |
| 04 | input | A shared input layer: touch controls that act as mouse and keyboard, hardware keyboards, controllers, Japanese text entry | Input reaches native Kirikiri, and there's an interface ready for Wine and Linux |
| 05 | fexcore-ios | FEXCore on Darwin/iOS: 16 KB pages, double-mapped JIT memory, a writable alias outside guest windows, Valve's config defaults, per-game settings keyed by hash, and the device gates (JIT, x18, guest window) | An x86 function returns 42 on a Mac and on a device, and each device's gates are recorded |
| 06 | wine-core | Wine cross-compiled for iOS (arm64ec/aarch64, llvm-mingw), `wineserver` as a thread, replacements for Mach task ports, pseudo-processes, the x18 trampolines and fault handler, `libarm64ecfex` | A 64-bit Windows console program runs in the app process through FEX |
| 07 | wine-wow64-guest-window | 32-bit games: the guest window [B, B+4 GB) in FEX, Wine's WoW64 pointer conversion, Wine's memory manager placing everything inside the window, `libwow64fex` | A 32-bit Windows console program runs in its guest window |
| 08 | wine-media | Windows, Metal drawing (DXMT for D3D11, and a D3D9 path), ARM64EC graphics layers, audio, video, stopping Metal in the background, memory limits | Original D3D9 and D3D11 test programs draw and play sound. Kirikiri/BGI-class and Unity-class games can be tried |
| 09 | languages | Per-game code pages and locale, CJK fonts and font mapping, the app's own localization. Covers Wine and the native engines | Japanese/Chinese/Korean test content shows correctly on each route |
| 10 | native-renpy | Ren'Py on iOS, runtimes matched to each game's version, detecting x86 native extensions, falling back to Wine | An original Ren'Py test game runs on a device |
| 11 | translation | Text capture from each route (native hooks, Wine text calls, OCR), backends (online with the user's key, including Anthropic, or on the device), the glossary, the overlay | Captured test text is translated and shown over the game |
| 12 | cloud-saves | A WebDAV client, CRDT sync state (settings and glossary as CRDTs, save-file sets with per-file version vectors, per-device state files on the server), a save-location interface that each route fills in (Wine prefix paths and registry, Kirikiri `savedata`, Ren'Py saves), a conflict prompt only for the same file changed on two devices (pick one, keep both), backups, Keychain credentials | Saves from an original test game round-trip between two devices, with a conflict resolved |
| 13 | linux-games | The FEX Linux front end on Darwin: a Linux syscall layer, ELF loading in the app process, graphics, audio, and input for Linux games (main build only) | An original Linux x86-64 test game runs on a device |
| 14 | nojit-box64 | The AltStore build: Box64's interpreter as the WoW64 DLL with the guest window, Wine and Box64 as signed Mach-O, JIT use when an enabler provides it | A 32-bit test program runs in the `.ipa` with no JIT |

## Dependencies

```
01 ──► 02 ──► 03 ──► 04
 │      │      │      │
 │      │      └──────┼──────────────► 09 ──► 11 ──► 12
 │      └────► 10 ◄───┘                 ▲             ▲
 └──► 05 ──► 06 ──► 07 ──► 08 ──────────┘             │
       │                    │                         │
       └──► 13 ◄── 04       └──► 14 ◄── 07            │
                                                      │
       (12 also takes save locations from 03, 08, 10)─┘
```

| Split | Needs | Kind of dependency |
|---|---|---|
| 01 | none | |
| 02 | 01 | patterns: project layout, build, credits pipeline |
| 03 | 02 | APIs: library entry, game hash, route interface |
| 04 | 02, 03 | APIs: game session / render view. 03 is its first consumer |
| 05 | 01 | APIs: JIT enablement and detection |
| 06 | 05 | APIs: FEXCore library, JIT memory allocator, device gates |
| 07 | 06 | APIs: Wine build, x18 handling, FEX Windows glue |
| 08 | 07, 04 | APIs: the i386 guest (D3D9 class) and input events. 06 is enough for the D3D11/ARM64EC pieces |
| 09 | 03, 08 | APIs: text rendering on the native route and in Wine |
| 10 | 02, 04 | APIs: route interface, input. The Wine fallback needs 08 |
| 11 | 09 | APIs: capture points in 03 and 08, the text shaping and fonts from 09 |
| 12 | 02, 11 | APIs: per-game settings store (02), glossary (11), save locations from 03, 08, 10 |
| 13 | 05, 04 | APIs: FEXCore, input. Reuses the Metal work from 08 where it can |
| 14 | 07, 08 | APIs: guest-window WoW64 contract, Wine build. Adds a signed Mach-O build of Wine |

## Suggested order and parallel work

- **Track A (device-visible first):** 01 → 02 → 03 → 04 → 10.
- **Track B (x86):** 05 can start once 01's JIT enablement exists, and runs beside 02–04. Then 06 → 07 → 08.
- **After both tracks:** 09 → 11 → 12.
- **Late, by owner's choice:** 13 and 14, after the Windows main-build path works. They can run in parallel with each other.

02 stores per-game settings in a CRDT-ready shape (per-field value, timestamp, device id), and 11 does the same for the glossary, so 12 can sync them without a migration. 12's save-location interface can be planned as soon as 02 exists. Each route fills it in later. It is placed late so it can cover every route and the glossary in one pass.

## Cross-cutting rules (every spec carries these)

- No program titles in the repo, logs, tests, commits, or remote paths. Key everything by hash. Test content is original.
- `/Volumes/Games` is read-only. Scans print only counts, engine names, plugin file names, and hashes.
- Upstream code is pinned as submodules and changed only through patch files. Keep copyright headers, and credit every component in the same commit that adds it.
- Everything runs in the app process. No helper processes, and no exploit, `ptrace`, or task-for-pid.
- A split whose device gate fails still builds and passes its desktop check, but makes no device claim. Record device, iOS version, chip, install method, and build with every device result.
- Privacy: game text leaves the device only through a translation backend the user turned on. Saves go only to the user's own WebDAV server.

## /deep-plan commands

```
/deep-plan @planning/01-build-packaging-jit/spec.md
/deep-plan @planning/02-app-shell/spec.md
/deep-plan @planning/03-native-kirikiri/spec.md
/deep-plan @planning/04-input/spec.md
/deep-plan @planning/05-fexcore-ios/spec.md
/deep-plan @planning/06-wine-core/spec.md
/deep-plan @planning/07-wine-wow64-guest-window/spec.md
/deep-plan @planning/08-wine-media/spec.md
/deep-plan @planning/09-languages/spec.md
/deep-plan @planning/10-native-renpy/spec.md
/deep-plan @planning/11-translation/spec.md
/deep-plan @planning/12-cloud-saves/spec.md
/deep-plan @planning/13-linux-games/spec.md
/deep-plan @planning/14-nojit-box64/spec.md
```
