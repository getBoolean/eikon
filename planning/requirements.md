# Eikon requirements

Eikon (said "AY-kon", from Greek *eikon*, a likeness) is an iPhone and iPad app that runs Windows and Linux x86 games. The app repo is https://github.com/getBoolean/eikon. The Sileo package source is https://github.com/getBoolean/eikon-source.

Today Eikon is an unfinished prototype and nothing runs a game. The repo holds the README, the handoff (`planning/handoff.md`), and, in `planning/old-stages/`, the earlier stage overview (`stages.md`) and fourteen stage plans. Those plans are earlier work, written before most of the decisions below. Where they disagree with this file, this file wins.

## Who it is for

The owner, playing their own collection of Windows games on their own jailbroken or sideloaded devices. Other people may install it from the Sileo source later. It is not a store app.

## Goals

1. Run Windows x86 games (i386 and amd64) on iOS and iPadOS.
2. Run Linux x86-64 games on iOS and iPadOS.
3. Run Kirikiri and Ren'Py games natively, with no x86 emulation, where the game allows it.
4. One build that turns JIT on automatically on Dopamine and TrollStore, uses JIT wherever the process has it, and falls back to routes that need no JIT (AltStore, or any install where JIT is missing).
5. Show game text correctly in any language the game was written for.
6. Translate game text while the game runs, into the user's language.
7. Install as a Dopamine rootless package from the Sileo source.
8. Install on devices that are not jailbroken: a single `.ipa` that installs with AltStore, and the same `.ipa` installed with TrollStore. (The separate `.tipa` was dropped on 2026-09-28; TrollStore installs the `.ipa` directly.)
9. Sync game saves and settings across the owner's devices through their own WebDAV server.

## Games to support, in priority order

Counts are folders in the owner's collection. They are a priority signal, not a contents list. No program titles are recorded anywhere in the project.

| Engine | Folders | How it is recognized | Notes |
|---|---|---|---|
| Unity | 29 | `UnityPlayer.dll` (4 also have `GameAssembly.dll`, meaning IL2CPP) | Needs amd64 and Direct3D 11 |
| Kirikiri | 21 | `.xp3` archives (3 also have a `.tpm` plugin) | Native route first. The Wine route covers the rest |
| Ren'Py | 4 | Ren'Py layout | Native route first: the game's scripts on a native Ren'Py of the matching version. The Wine route covers the rest |
| GameMaker | 3 | `data.win` | Windows build under Wine |
| BGI | 2 | `BGI.exe` | Same needs as Kirikiri on Wine |

The collection's `Game.exe` files are 11 i386 and 5 amd64. Most games are Japanese.

## Functional requirements

### Builds and JIT
- **One build.** One app binary, built once, ships as two artifacts: the Dopamine deb and the `.ipa` (for AltStore and TrollStore). They differ only in entitlements, one Info.plist stamp, the bundle id and packaging. The app decides at run time, from whether the process has usable JIT, which routes it offers. (Two artifacts, not three, since 2026-09-28.)
- **Turning JIT on.** The app turns JIT on automatically where the install method allows it:
  - on Dopamine, using what Dopamine provides, with no setup or extra tool for the user
  - on TrollStore, through TrollStore's "launch with JIT" URL scheme (`apple-magnifier://enable-jit?bundle-id=<id>`, TrollStore 2.0.12 and later), the way UTM and PojavLauncher do. It does not use the `dynamic-codesigning` entitlement: iOS 15 and later on A12 and newer chips ban it, and apps signed with it crash on launch.
  - on AltStore it never requests JIT. It uses JIT if a JIT enabler such as StikDebug has given it to the process.
  - inside **LiveContainer** (a guest app run by LiveContainer, installed via AltStore/SideStore/TrollStore), it uses whatever JIT LiveContainer's own source provides, the same as any sideloaded install. LiveContainer runs the guest under its own process, so the runtime bundle id and bundle path differ from a normal install; the app reads the bundle id at run time and never assumes `com.getboolean.eikon`. Explicit detection of LiveContainer (a dedicated install method and JIT source) is a possible follow-up once a device report shows how it maps the guest bundle. (Added 2026-09-27.)
- **With JIT:** FEX-Emu is the x86 translator, for both Windows and Linux games.
- **Without JIT:** the app runs:
  - the native engines (Kirikiri and Ren'Py)
  - 32-bit Windows games through Box64's interpreter, loaded into Wine as Box64's WoW64 DLL. Box64 has no ARM64EC DLL, so 64-bit Windows games (including Unity) and Linux games need JIT. Wine's own code and Box64's DLL are built into signed Mach-O files, which are signed with the rest of the app. This route is slow, and is aimed at 2D visual novels.
- JIT that the process has but cannot use counts as no JIT. An example is a device with Apple's Trusted Execution Monitor (iOS 26 and later), where JIT memory also has to be approved by an attached debugger.
- Every install method runs the native engines.
- For each game, the app shows which route it will use and why, including when a route is unavailable because the process has no JIT.

### Running Windows games
- Runs 32-bit and 64-bit Windows x86 games using Wine, with FEX-Emu translating the games' x86 code to ARM64 when the process has JIT, and Box64's interpreter for 32-bit games when it does not.
- Supports the graphics, audio, video, and file features the target engines use, drawing through Metal.
- Supports plugins and DLLs that games ship alongside their executable.

### Running Linux games
- Runs Linux x86-64 games using FEX-Emu, only when the process has JIT.
- Covers what Linux games need on iOS: graphics, audio, and input.

### Native engines
- Runs Kirikiri games natively, without emulation, based on Kirikiroid2 (https://github.com/zeas2/Kirikiroid2, by zeas2 and contributors).
- Runs Ren'Py games natively on an iOS build of Ren'Py, matching each game's Ren'Py version.
- Games a native route cannot handle fall back to running under Wine.

### Input
- Touch controls that cover what the games expect from a mouse and keyboard.
- Hardware keyboards and game controllers.
- Text entry, including Japanese.

### Languages
- Games written for Japanese, Chinese, Korean, and other non-English versions of Windows show their text and open their files correctly.
- The app's own interface can be translated.

### Translation
- Captures the text a game shows, translates it into the user's language, and shows the translation over the game while it runs.
- The user chooses between online translation services (with their own key, including LLMs through the Anthropic API) and translation on the device.
- Users can correct recurring terms, such as character names.

### App
- A game library, with settings for each game.
- Shows what the current build, device, and install method can run, and why anything is unavailable.
- Credits every third-party component, with its license, inside the app.

### Cloud saves
- Syncs through a WebDAV server the user runs and configures (for example Nextcloud or a NAS). There is no Eikon-run service, and no iCloud or CloudKit, which need an Apple developer signature that none of the install methods have.
- Syncs, per game and keyed by the game's hash:
  - game saves, wherever the route keeps them: save paths in the Wine prefix (such as AppData and Documents), registry keys that games save to, Kirikiri `savedata`, and Ren'Py saves
  - the game's settings in Eikon (route, FEX overrides, controls, code page)
  - the translation glossary (the user's corrections for recurring terms)
- Never syncs game files.
- Sync state uses CRDTs (conflict-free replicated data types) wherever the data allows:
  - Settings and the glossary are CRDTs, so concurrent edits on two devices merge without asking.
  - Each game's set of save files is tracked as a CRDT with per-file version vectors, so changes to different files merge without asking.
  - A save file's contents are opaque and cannot be merged. Only when two devices changed the same file does the app show both versions with device and time and let the user pick. The version not picked is kept as a backup.
  - Each device writes only its own state files on the server and merges the others', so sync does not rely on WebDAV locking.
- Stores server credentials in the Keychain.
- Works on every build and install method.

### Packaging
- A Dopamine rootless deb, package id `com.getboolean.eikon.rootless`, published on the `eikon-source` Sileo repo through GitHub Pages. Only package files go there, never app source. (Its own id, distinct from the ipa, so a Dopamine install and a TrollStore-installed ipa can coexist.)
- One `Eikon.ipa`, installed with either AltStore or TrollStore, with bundle id `com.getboolean.eikon`. AltStore rewrites the id per account and re-signs, replacing the ipa's entitlements; TrollStore installs it as-is and keeps them. Both packages carry the same app binary at the same version, and differ only in entitlements, the bundle id and packaging.
- Both packages run sandboxed, in their data container. Neither carries `com.apple.private.security.no-sandbox` (removed 2026-09-28): nothing needs it, and a TrollStore install on iPadOS 17.0 carrying it was SIGKILL'd at exec for being outside a container. The deb carries `com.apple.private.security.container-required` for its own bundle id; without it, the sandbox under `/var/jb` denied writes to the data container and the GPU. TrollStore adds that key to the ipa itself. AltStore re-signs the ipa and drops its private keys. Neither uses root helpers (`com.apple.private.persona-mgmt`) or any entitlement TrollStore lists as banned. Neither uses `platform-application` (decided 2026-09-27). It moves the app to a stricter IOKit sandbox profile, so Metal would need GPU exceptions. It can also cost the data container unless `com.apple.private.security.storage.AppDataContainers` is added. No planned feature needs it.

## Constraints

- **No exploit and no JIT bypass of Eikon's own.** Eikon uses only what its install method already provides: Dopamine's jailbreak, TrollStore's installation and JIT launch, or a JIT enabler the user runs. Relying on Dopamine's and TrollStore's mechanisms is intended. Eikon itself does not attach a debugger or call `ptrace` or task-for-pid.
- **No program titles** in the repo, logs, tests, or depictions. Game data is keyed by a hash of the main executable or archive. Test content is original.
- **Target devices.** Dopamine: verified on iPadOS 17.0 (the Dopamine version was not recorded). TrollStore reaches iOS 17.0. AltStore runs on current iOS. Newer devices with TXM handle debugger-based JIT differently. Record device, iOS version, chip, install method, and build with every device result.
- **Games run inside the app process on every install method.** There are no helper processes. One design serves all three installs, and TrollStore's JIT, which applies only to the process it launched, reaches the game. What that means:
  - 32-bit games get their address space from a "guest window" (see the Low-memory constraint below), not from the bottom 4 GB.
  - Wine's server runs as a thread in the app, and any process a game starts runs as a pseudo-process inside the same app process, as Madeira does.
  - A crash in a game takes the app down with it.
- **What each install method allows:**

  (TrollStore and AltStore install the same `.ipa`; they differ only in runtime JIT behaviour.)

  | | Dopamine deb | TrollStore `.ipa` | AltStore `.ipa` |
  |---|---|---|---|
  | JIT | Automatic, through Dopamine | Automatic, through TrollStore's JIT launch | Never requested. Used if a JIT enabler provides it |
  | x86 translation, usual case | FEX JIT | FEX JIT | Box64 interpreter (FEX if an enabler gave usable JIT) |
  | x86 translation, without JIT | Box64 interpreter | Box64 interpreter | Box64 interpreter |
  | Wine's own code | Loaded normally under JIT, signed Mach-O without | Loaded normally under JIT, signed Mach-O without | Signed Mach-O, signed at install |
  | 32-bit address space | Guest window | Guest window | Guest window |
  | Native engines | Yes | Yes | Yes |
- **Hardware facts to design around:**
  - iOS pages are 16 KB.
  - Darwin clears register x18, which Windows ARM64 code uses for its thread pointer (TEB). Madeira shows a working approach: patch x18 reads in loaded Windows modules into trampolines that fetch the TEB from thread-local storage (`TPIDRRO_EL0`), catch any reads the patching misses with a fault handler, and have the Wine dispatcher restore x18 on entry.
  - The kernel refuses to launch any 64-bit ARM executable whose `__PAGEZERO` is smaller than 4 GB (`xnu/bsd/kern/mach_loader.c`: "64 bit ARM binary must have 'hard page zero' of 4GB"). Once a process has launched, its lowest usable address can only be raised (`vm_map_raise_min_offset`). No install method can give an iOS app memory below 4 GB.
  - Writing to JIT memory needs a second, writable address on A12 and later chips.
  - iOS runs only signed code unless the process has JIT. Wine's own ARM64 DLLs, which Wine loads itself, count as unsigned code, so the no-JIT route needs them delivered as signed code.
- **Low memory for 32-bit games: a guest window.** Every 32-bit Windows program gets a 4 GB window [B, B+4 GB) somewhere in the address space, and its address `a` lives at real address `B+a`. What that takes:
  - FEX adds B to every memory access in translated 32-bit code, and so does Box64's interpreter on the no-JIT route.
  - Wine's WoW64 layer adds or removes B wherever a pointer crosses between the 32-bit program and 64-bit Wine.
  - Wine's memory manager places everything a 32-bit program sees inside its window: the 32-bit TEB and PEB, stacks, relocated 32-bit DLLs, and `KUSER_SHARED_DATA` at B+`0x7ffe0000`. Any address limit a program asks for (addresses below L) becomes [B, B+L).
  - GPU memory that a 32-bit game maps also has to land inside its window.

  This is the design in Madeira's WoW64 work (PR #26), and QEMU's user-mode emulation uses the same idea. It works on every install method.
- **Guest-running work is gated on device measurements:** whether the process has JIT, and whether the x18 workaround and the guest window hold up on that device. A stage that fails a gate builds and passes its desktop check, but makes no device claim.
- **Upstream libraries come from fork releases, not submodules** (owner decisions, 2026-09-27; submodules are a pain to work with). Each upstream is forked on the owner's GitHub, with Eikon's changes as commits on the fork's `eikon` branch. For development, the fork is cloned next to this repo. The fork builds its library for iOS and publishes it as a GitHub release. Eikon doesn't build upstream source: `third_party/deps.toml` pins each release (fork, tag, asset, SHA-256), and the build downloads it into `build/deps/`. A release's tag records the fork commit and serves as the GPL corresponding source. The starting points are FEX `FEX-2609`, Box64 at a tag for the no-JIT route, Wine `wine-11.0` (or bylaws' `upstream-arm64ec` branch if needed), and Kirikiroid2 at a commit.
- **Licensing:**
  - Eikon is GPL-3.0-or-later. That is compatible with Wine (LGPL-2.1-or-later), FEX and Box64 (MIT), Kirikiroid2 (BSD-style), and GPL code.
  - Kirikiroid2's Kodi-derived video player may ship. Its Android-only storage code (from AmazeFileManager, GPL-3.0) is not needed on iOS.
  - Keep every upstream copyright header, and credit every component.
- **Privacy:** game text leaves the device only through an online backend the user turned on. Saves, settings, and the glossary leave the device only for the WebDAV server the user configured. Remote paths use game hashes, never titles.
- **Stay on iOS:**
  - The iOS host layer is new.
  - Autorun's Horizon server, libnx, NRO packaging, and Switch drivers are not copied.
  - QEMU and v86 are not used. Linux games use FEX only; Box64 is used only for 32-bit Windows games, and only when the process has no usable JIT.

## Test data

The owner's game collection is on the SMB share `smb://desktop-boolean/Games`. It is mounted on the development Mac at `/Volumes/Games`. It is for inspection and for manual device testing: finding which engines and plugins games use, checking which games a stage can open, and trying real games after an original test guest passes.

- Treat the share as read-only. Never write to it.
- Nothing from it enters the repo, commits, plans, logs, test names, or issue text: no titles, folder names, file paths, screenshots, or game text. Scripts that scan it print only counts, engine names, plugin file names, and hashes.
- No game file is bundled in the deb or IPA, uploaded anywhere, or committed. A test that needs real game data reads it from the mount at run time, is skipped when the mount is absent, and reports results by hash.
- Automated acceptance checks still use original test content. A result on a real game is extra evidence, recorded by engine and hash only.
- Game text sent to an online translation backend during testing is the owner's own choice for their own data, and it happens only through a backend they have turned on.

## Prior art

Two projects run Windows games with Wine and FEX on ARM64. Eikon takes design decisions from both. It does not build on their code.

**Valve's Proton on Steam Frame (Snapdragon 8 Gen 3, SteamOS).** From Proton's `Makefile.in`, `proton` launcher script, and `FEX_Config.json` on the `proton_11.0` branch:
- **Native Wine, FEX as the CPU.** Wine is built native, with `--enable-archs=arm64ec,aarch64,i386,x86_64`. FEX ships as two Windows DLLs: `aarch64-w64-mingw32` for 32-bit games (WoW64) and `arm64ec-w64-mingw32` for 64-bit games. A small FEX Unix library switches the chip's hardware x86-style memory ordering on and off through a Linux `prctl`.
- **Graphics layers are native in 64-bit games.** DXVK, vkd3d-proton, and dxvk-nvapi are built as ARM64EC, so in 64-bit games they run as native ARM code. They are built as i386 for 32-bit games. Wine Mono ships an ARM64 build.
- **Default FEX config:** `TSOEnabled=1`, `HalfBarrierTSOEnabled=1`, `VectorTSOEnabled=0`, `MemcpySetTSOEnabled=0`, `X87ReducedPrecision=1`, `Multiblock=1`, `MaxInst=500`.
- **Per-game FEX settings.** The launcher writes a per-game FEX config, with overrides keyed by app id. For example, one game's setup program needs `X87ReducedPrecision=0`.
- **Build:** a separate default Wine prefix for ARM64, compiled for `-march=armv8.2-a`.
- **Results:** about 160 titles are verified for standalone play.

For Eikon, that means: build the graphics layers as ARM64EC for 64-bit games; start from Valve's FEX config; and keep per-game FEX settings keyed by game hash, not by app id. Apple chips have a hardware x86 memory-ordering mode, but iOS offers no public way to turn it on.

**Madeira (https://github.com/willfaust/Madeira, GPL-3.0).** An iOS research prototype that runs Windows x86-64 games on non-jailbroken iPhones with Wine (ARM64EC), FEX, and DXMT. It is sideloaded, gets JIT from StikDebug, and has a few playable games. Its design decisions to adopt:
- **One process:** a single Mach process, with `wineserver` as a thread.
- **x18:** x18 reads patched to fetch the TEB from thread-local storage, with a fault handler for the rest (see Constraints).
- **JIT memory:** double-mapped, with a writable alias kept outside any guest window. It also has a breakpoint-based JIT path for iOS 26's Trusted Execution Monitor (TXM).
- **32-bit games:** the guest window (see Constraints).
- **Graphics:** DXMT for Direct3D 11. Its analysis found DXVK blocked by geometry shaders missing from MoltenVK.

## Operational requirements

- Sign every binary and dylib in each package so it loads under its install method: ad-hoc with `ldid` for Dopamine, and for the `.ipa` either TrollStore's signing or AltStore's signing at install.
- Run Wine's server as a thread inside the app process, and replace its use of Mach task ports, which iOS restricts.
- Survive iOS memory limits for the app process. Unity games need gigabytes.
- Handle the app going to the background while a game runs: pause the game, and stop Metal drawing, since using Metal in the background crashes the process.
- Build Wine as a cross-compile from macOS for iOS, with Wine's build tools built for the Mac first. Build the Windows DLLs with llvm-mingw.

## Decisions

Made by the owner on 2026-09-27:

- **License:** GPL-3.0-or-later. Kirikiroid2's GPL-derived video player may ship.
- **Builds:** one build, shipped as the Dopamine deb and the `.ipa` (AltStore or TrollStore). The app picks routes at run time from whether it has usable JIT. This replaced the earlier two-build plan (main and no-JIT) on 2026-09-27, so that installs without JIT still run the no-JIT routes, and AltStore installs with JIT from an enabler can use FEX.
- **JIT:** automatic on Dopamine and TrollStore. Relying on Dopamine's and TrollStore's mechanisms is acceptable.
- **Entitlements:** no build is unsandboxed; `no-sandbox` was dropped from both on 2026-09-28. The `.ipa` keeps `get-task-allow` for TrollStore's JIT launch (AltStore drops private keys when it re-signs). Sideloaded apps already need Developer Mode. No root helpers, and no `platform-application`.
- **Process model:** games run inside the app process on every install method.
- **32-bit address space:** a guest window, not a small `__PAGEZERO`, which the iOS kernel rejects.
- **Madeira:** take its design decisions, but do not build on its code or forks. It is a research prototype, far from complete.
- **Translators:** FEX when the process has usable JIT, for Windows and Linux games. Box64's interpreter only when it does not, and only for 32-bit Windows games.
- **No pre-translated signed route.** It is not needed while JIT installs have FEX and the no-JIT route has an interpreter.

## Known risks

- The x18 workaround patches code in every loaded Windows module and catches the rest with a fault handler. Code patching can miss cases, and each fault costs time.
- 16 KB pages: on Asahi Linux, which also uses 16 KB pages, FEX and Wine run only inside a 4 KB-page virtual machine. iOS has no VM for that.
- Upstream Wine lacks pieces FEX's DLLs need.
- MoltenVK lacks Vulkan features that DXVK expects.
- Speed: FEX follows x86's strict memory ordering by default, which costs speed on these chips.
- Box64's interpreter is typically ten or more times slower than a JIT. Expect the no-JIT route to suit 2D visual novels, not Unity.
- Wine's DLLs normally load as PE files. The no-JIT route needs them, and Box64's DLL, as signed Mach-O files, which neither project builds today.
- Box64 would need to add the guest-window base to every memory access. Its 32-bit support assumes the low 4 GB today.
- A native Ren'Py must match each game's Ren'Py version closely, and some games ship native Python extensions built for x86.
- Running everything in one process:
  - The guest window touches every pointer that crosses between 32-bit code and 64-bit Wine. Any conversion that is missed corrupts memory.
  - Wine expects `wineserver` to be a separate process, and games that start other programs expect separate processes. Making them threads and pseudo-processes is invasive work in Wine.
  - One game's crash ends the app.
