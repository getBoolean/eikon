# Eikon stages

Each stage has its own plan and ends with something that can be tested on its own. Later stages assume the earlier acceptance checks passed. Plans live next to this file.

The personal library that motivated the engine list is not recorded here, and neither are program titles. The README does not mention that library.

## Engine order

Counts are folders in a local collection. They are a priority signal, not a contents list.

| Engine | Folders | When it can run |
|---|---|---|
| Unity (`UnityPlayer.dll`; 4 of them also have `GameAssembly.dll`) | 29 | After the amd64 CPU path and a Direct3D 11 frame |
| Kirikiri (`.xp3` archives; 3 also have a `.tpm` plugin) | 21 | Natively after stage 11, for unencrypted archives without a `.tpm` plugin. Otherwise after a 32-bit process gets memory below 4 GB, reads a file, opens a window, takes a click, draws Direct3D 9, and plays audio |
| Ren'Py | 4 | After the window, file, and audio stages |
| GameMaker (`data.win`) | 3 | After the window, file, and audio stages |
| BGI (`BGI.exe`) | 2 | Same stage as Kirikiri |

`Game.exe` in that collection is 11 i386 and 5 amd64. i386 is the first guest. amd64 waits, unless stage 2 shows that i386 cannot get memory below 4 GB on the device (see below).

Siglus and CatSystem2 were not present.

## Architecture

FEX-Emu, tag `FEX-2609`, is the primary x86 translator. Linux guests use its Linux front end. Windows guests use its two Windows CPU DLLs inside Wine: `libwow64fex.dll` for i386 and `libarm64ecfex.dll` for amd64. All three share FEXCore, and stage 3 ports FEXCore to Darwin once for all of them. Box64 is the fallback translator for Windows games that FEX cannot run, or cannot run well enough; its i386 WoW64 DLL (`wowbox64.dll`) goes in the same place in Wine. No stage builds it yet. QEMU and v86 are not used.

FEX was chosen over Box64 because it gives one translator to port, patch, and audit for x18 and page size, and because it has upstream DLLs for both i386 and amd64 Windows guests. Speed was not the deciding factor: FEX keeps x86's stricter memory ordering by default, which can cost speed on ARM chips without a hardware mode for it, and Box64 relaxes it. Compare speed with FEX's per-program settings once guests run, rather than assuming it. FEX expects a Linux kernel and 4 KB pages, and iOS has neither. Stage 14 adds a Linux system-call layer for Darwin and runs FEX in the `eikon-linux` helper, first for a console program. General 4 KB page support and a display layer for Linux graphics are later stages.

Kirikiri also has a native route (stage 11): an iOS port of Kirikiroid2 (by zeas2 and contributors, built from Kirikiri 2 and KirikiriZ) reads `.xp3` archives directly, with no emulation. It cannot load x86 `.tpm` plugins, and cannot open archives whose encryption lives in one. Those games stay on the Wine route.

Windows follows Autorun's shape, not Wine-under-FEX. Wine is built as native ARM64, and FEX's DLLs translate only the guest program. Autorun uses Box64 in that role; Eikon uses FEX. FEX's wiki says upstream Wine still lacks some pieces for its DLLs, and recommends bylaws' `upstream-arm64ec` branch. Stage 4 starts on `wine-11.0` and moves the pin to that branch if a missing piece blocks it. Autorun's Horizon server, libnx, NRO packaging, and Mesa-switch NVIDIA drivers are not copied. Wine's own `wineserver` and its Unix side, built for iOS, take their place. Wine's macOS port is x86_64 only, so the ARM64 Darwin CPU layer is written new (stage 4). Guests run in `eikon-wine`, a helper process the app spawns. Drawing goes through Metal. Direct3D 9 goes through DXVK on MoltenVK after a software window blit already works. Direct3D 11 does the same if MoltenVK has the features DXVK needs; otherwise it goes through DXMT.

## Device gates

Stage 2's helper, `eikon-probe`, is linked with a 16 KB `__PAGEZERO` the way `eikon-wine` will be. It records four results that decide which stages can make a device claim on a given device:

| Result | Needed by | If it fails |
|---|---|---|
| `spawn=ok`: the app can start a helper | every guest stage (3 to 8, 14) | Blocked until the app's entitlements change (see below) |
| `helper.jit_run=42`: the helper can run generated code | 3 to 8, 14. Wine's own ARM64 DLLs need it too | Stops at "unsupported" |
| `helper.x18_*=kept`: x18 survives syscalls, switches, and signals | 4 to 8 (Windows ARM64 code keeps its TEB in x18) | The Wine route is blocked on that device. Stages 11 and 14 are unaffected |
| `helper.low4g_page=ok`: memory below 4 GB | 4 to 6 (every i386 guest) | Stage 7 (amd64) moves ahead of stage 4, and Unity becomes the first Windows class |

Stage 11 (native Kirikiri) needs none of these.

## Languages and translation

Stage 12 gives each game its own Windows code page (Japanese, Chinese, Korean, Cyrillic, Western), maps Windows font names to bundled OFL CJK fonts, and moves the app's text into `Localizable.strings`. Stage 13 captures the text a game draws: from the native Kirikiri engine, from Eikon's Wine text calls, or by OCR. It translates the text with the backend the user picks, either online with their own key (DeepL, or an LLM through the Anthropic API) or on the device (Apple's Translation framework on iOS 18 and later, or a downloaded model). Translation is off until the user turns it on for a game. The screen names any service that would receive game text.

## Open decisions

- **JIT entitlement.** Stage 2 does not sign Eikon or its helpers with `dynamic-codesigning`. TrollStore and Dopamine usually grant JIT through that entitlement. Whether adding it counts as the JIT bypass this project rules out is the owner's call, made after stage 2 records the results and the binaries' entitlements.
- **Helper entitlements.** Starting helpers may need the app to run unsandboxed (`com.apple.private.security.no-sandbox`) or with other private entitlements. Stage 2's `spawn` result says whether it does.
- **GPL code from Kirikiroid2.** Its video player is adapted from Kodi (GPL-2.0-or-later), and its Android storage code from AmazeFileManager (GPL-3.0). Stage 11 leaves both out by default. Shipping the Kodi-derived player would put the whole app under the GPL.
- **Eikon's own license.** The repo has no `LICENSE`. It must be compatible with everything the app bundles: Wine (LGPL-2.1-or-later), FEX (MIT), Kirikiroid2 (BSD-style), and GPL code if any is kept.

## Credits

Stage 1 creates `THIRD_PARTY_NOTICES.md`, `Resources/licenses/`, and an in-app Acknowledgements screen, plus a test that fails if any submodule lacks an entry and a license file. Every stage that adds third-party code or data adds its credit in the same commit. Upstream copyright headers are never removed, and files adapted from upstream say what Eikon changed.

There is no JIT bypass. A stage that emits code runs only when the process already has JIT from TrollStore, AltStore, or Dopamine.

## Order

| Stage | Plan | Produces | Depends on |
|---|---|---|---|
| 1 | `2026-09-26-stage-1-device-shell.md` | Installable shell that does not claim to run a guest, with the credits setup | None |
| 2 | `2026-09-26-stage-2-probes.md` | The four device gates, measured in a spawned small-`__PAGEZERO` helper | 1 |
| 3 | `2026-09-26-stage-3-fexcore.md` | FEXCore, ported to Darwin, runs one x86 function that returns 42 on a Mac and on the device | 2 |
| 4 | `2026-09-26-stage-4-console-pe.md` | A 32-bit Windows program prints a line and reads one byte, through `libwow64fex.dll` | 3 |
| 5 | `2026-09-26-stage-5-one-window.md` | That program opens a window and sees a tap | 4 |
| 6 | `2026-09-26-stage-6-kirikiri-class.md` | Direct3D 9 presents and a wave plays. Kirikiri and BGI class | 5 |
| 7 | `2026-09-26-stage-7-amd64.md` | A 64-bit Windows program returns 42, through `libarm64ecfex.dll` | 3, and stage 4 Task 3's Wine build (not stage 4's device run) |
| 8 | `2026-09-26-stage-8-unity-class.md` | Direct3D 11 presents one frame. Unity, Ren'Py, and GameMaker can start being tried | 6's surface code, and 7 |
| 9 | `2026-09-26-stage-9-fex-linux.md` | Signal Drift runs under FEX on a Linux machine, then exits | None |
| 10 | `2026-09-26-stage-10-sileo.md` | The stage 1 deb is what `eikon-source` serves | 1 |
| 11 | `2026-09-27-stage-11-native-kirikiri.md` | An original `.xp3` runs on device through Kirikiroid2, with no emulation, audited and credited | 1 |
| 12 | `2026-09-27-stage-12-languages.md` | Per-game code pages, CJK fonts, and localizable app text | 1. Wine tasks need 5, and the Kirikiri task needs 11 |
| 13 | `2026-09-27-stage-13-translation.md` | Captured game text is translated by the user's chosen backend and shown over the game | 12. Capture tasks need 5 or 11 |
| 14 | `2026-09-27-stage-14-fex-darwin.md` | Signal Drift runs under FEX on macOS, then in `eikon-linux` on device | 3 and 9 |

Stage 11 needs no device gate, so it is the earliest route to a real game on the device, and can start right after stage 1. Stage 9 can proceed beside anything. Stage 14 starts once stage 3's Mac task and stage 9 pass. Stage 7 can proceed beside 5 and 6 once stage 4's Wine build exists. Stage 8 cannot run before 7. Stage 10 publishes the shell only, and it waits until that deb exists in this tree. The hashes in the handoff belong to a package that is not in this checkout.
