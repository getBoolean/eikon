# Deep-project interview: Eikon

Date: 2026-09-27
Requirements: `planning/requirements.md`

## Context gathered before the interview

- The repo holds only `README.md`, `.gitignore`, and `planning/` (requirements, handoff, old stage plans). There is no app source, no build system, and no submodules yet. Every split starts from nothing.
- `planning/handoff.md` records the state of the `eikon-source` Sileo repo: text files landed, but the deb, `Packages.bz2`/`.gz`, the icon, and the Pages workflow are missing, and GitHub Pages is off. Pushing through `git push` failed in that earlier environment; the GitHub API was used instead.
- The old stage plans (`planning/old-stages/`) assume helper processes, a small `__PAGEZERO`, and Box64 as a main-build fallback. `requirements.md` rejects all three.

## Round 1

**Q: What should the first split deliver, so there's something testable on a device early?**
A: Shell + native Kirikiri. App shell, packaging, and JIT enablement first, then native Kirikiri as the first real game route. It needs no x86 work or device gates, and covers 21 folders.

**Q: How finely should the Wine work be split?**
A: Three splits:
(a) Wine on iOS in one process, running a 64-bit console program.
(b) 32-bit WoW64 with the guest window.
(c) Graphics, audio, and window/input through Metal (DXMT, D3D9 and D3D11).

**Q: Where do Linux games and the no-JIT Box64 build fall in priority?**
A: Both late. Each is its own split, sequenced after the Windows main-build path works.

**Q: Should the old stage plans be fed to /deep-plan as reference?**
A: Ignore them. Plan fresh from `requirements.md` only. Specs must not point at `planning/old-stages/`.

## Round 2

**Q: Where should the FEXCore Darwin port go?**
A: Its own split, before Wine. FEXCore on iOS runs x86 code on a Mac and on a device, with the device gates (JIT present, x18, guest window feasibility) measured there. The Wine and Linux routes both depend on it.

**Q: Native Kirikiri and native Ren'Py: one split or two?**
A: Two splits. Kirikiroid2 (C++, xp3, audit and credits) and Ren'Py (Python, SDL, per-version runtimes, x86 extension detection) share little code.

**Q: Languages and translation: one split or two?**
A: Two. Languages (code pages, CJK fonts, app localization) comes earlier. Translation (capture, backends, glossary, overlay) builds on it.

**Q: Where does input go?**
A: Its own split. A shared input layer (touch-to-mouse/keyboard, hardware keyboards, controllers, Japanese text entry) that feeds Wine, the native engines, and Linux games. Planned after the first native engine exists.

## Round 3

**Q: App shell and packaging/JIT: one split or two?**
A: Two. First, builds, packaging, and JIT enablement: installable on all three methods, and reports its JIT state. Second, the app itself: library, game detection by hash, route display, settings, and credits.

**Q: Preferred UI stack and build system?**
A: Let /deep-plan decide. Record it as an open question for the first split. (The handoff mentions an earlier UIKit + Theos layout, which is not in this checkout.)

## Shape after round 3

1. Build, packaging, JIT enablement
2. App shell (library, detection, routes, settings, credits)
3. Native Kirikiri
4. Input layer
5. FEXCore on iOS (plus device gates)
6. Wine core, one process, 64-bit console
7. Wine WoW64 + guest window (32-bit)
8. Wine media: Metal graphics (DXMT, D3D9/D3D11), audio, windows
9. Languages
10. Native Ren'Py
11. Translation
12. Linux games (FEX Linux front end)
13. No-JIT build (Box64 interpreter, signed Mach-O Wine)

## Round 4 (added by the owner after round 3: cloud saves for cross-device sync)

Background given: CloudKit and iCloud entitlements need an Apple developer signature, which ad-hoc (Dopamine), TrollStore, and AltStore signing cannot provide.

**Q: Which sync backend(s)?**
A: WebDAV / self-hosted only. Eikon talks to a server the user runs (Nextcloud, a NAS, and so on), and handles the sync and conflicts itself. No Files-folder mode and no Dropbox or Google Drive APIs.

**Q: What should sync?**
A: Game saves, per-game settings, and the translation glossary. Not the game files.

**Q: Conflicts?**
A: Ask, and keep both. Show both versions with device and time, and let the user pick. The other version is kept as a backup.

**Q: Add to requirements.md?**
A: Yes. Goal 9, a "Cloud saves" functional section, and a privacy line were added to `requirements.md` on 2026-09-27.

Planning note: finding where each route keeps saves (Wine prefix paths, registry, Kirikiri `savedata`, Ren'Py save dirs) is a per-route job. The sync split defines a save-location interface that each route fills in, and it owns the sync engine, WebDAV client, conflict UI, and backups.

## Final shape

1. Build, packaging, JIT enablement
2. App shell (library, detection, routes, settings, credits)
3. Native Kirikiri
4. Input layer
5. FEXCore on iOS (plus device gates)
6. Wine core, one process, 64-bit console
7. Wine WoW64 + guest window (32-bit)
8. Wine media: Metal graphics (DXMT, D3D9/D3D11), audio, windows
9. Languages
10. Native Ren'Py
11. Translation
12. Cloud saves (WebDAV)
13. Linux games (FEX Linux front end)
14. No-JIT build (Box64 interpreter, signed Mach-O Wine)

## Round 5 (manifest review)

**Owner:** "For sync, we should use CRDT (Conflict-free Replicated Data Type) if possible."

Claude's reading, recorded in `requirements.md`:
- Settings and the glossary are structured data Eikon owns, so they can be true CRDTs (for example LWW registers per setting, an add-wins map for glossary entries). Concurrent edits merge without prompting.
- Save file contents are opaque bytes rewritten whole by the game, so they cannot be merged. The per-game *set* of save files is a CRDT with per-file version vectors: edits to different files merge automatically, and the "pick one, keep both" prompt appears only when the same file changed on two devices.
- On WebDAV, each device writes only its own state/op-log files and merges the others', which avoids relying on WebDAV locking.
