# Eikon stages

Each stage has its own plan and ends with something that can be tested on its own. Later stages assume the earlier acceptance checks passed. Plans live next to this file.

The personal library that motivated the engine list is not recorded here, and neither are program titles. The README does not mention that library.

## Engine order

Counts are folders in a local collection. They are a priority signal, not a contents list.

| Engine | Folders | When it can run |
|---|---|---|
| Unity (`UnityPlayer.dll`; 4 of them also have `GameAssembly.dll`) | 29 | After the amd64 CPU path and a Direct3D 11 frame |
| Kirikiri (`.xp3` archives; 3 also have a `.tpm` plugin) | 21 | After a 32-bit process can read a file, open a window, take a click, draw Direct3D 9, and play audio |
| Ren'Py | 4 | After the window, file, and audio stages |
| GameMaker (`data.win`) | 3 | After the window, file, and audio stages |
| BGI (`BGI.exe`) | 2 | Same stage as Kirikiri |

`Game.exe` in that collection is 11 i386 and 5 amd64. i386 is the first guest. amd64 waits.

Siglus and CatSystem2 were not present.

## Architecture

Linux x86-64 stays on FEX-Emu, tag `FEX-2609`, run directly. That guest is not Box64, QEMU, or v86.

Windows follows Autorun's shape, not Wine-under-FEX. Wine is built as native ARM64. Box64, tag `v0.3.6`, translates only the guest program (`-DWOW64=ON`, producing `wowbox64.dll` for i386 and the amd64 path in the later stage). Autorun's Horizon server, libnx, NRO packaging, and Mesa-switch NVIDIA drivers are not copied. The iOS host layer is new. Drawing goes through Metal. Direct3D 9 and 11 go through DXVK on MoltenVK after a software window blit already works.

There is no JIT bypass. A stage that emits code runs only when the process already has JIT from TrollStore, AltStore, or Dopamine.

## Order

| Stage | Plan | Produces | Depends on |
|---|---|---|---|
| 1 | `2026-09-26-stage-1-device-shell.md` | Installable shell that does not claim to run a guest | None |
| 2 | `2026-09-26-stage-2-probes.md` | A log of code-memory and the low 4 GB | 1 |
| 3 | `2026-09-26-stage-3-box64.md` | One x86 function returns 42 on device | 2 |
| 4 | `2026-09-26-stage-4-console-pe.md` | A 32-bit Windows program prints a line and reads one byte | 3 |
| 5 | `2026-09-26-stage-5-one-window.md` | That program opens a window and sees a tap | 4 |
| 6 | `2026-09-26-stage-6-kirikiri-class.md` | Direct3D 9 presents and a wave plays. Kirikiri and BGI class | 5 |
| 7 | `2026-09-26-stage-7-amd64.md` | A 64-bit Windows program returns 42 | 3 |
| 8 | `2026-09-26-stage-8-unity-class.md` | Direct3D 11 presents one frame. Unity, Ren'Py, and GameMaker can start being tried | 6 and 7 |
| 9 | `2026-09-26-stage-9-fex-linux.md` | Signal Drift runs under FEX on a Linux machine, then exits | None |
| 10 | `2026-09-26-stage-10-sileo.md` | The stage 1 deb is what `eikon-source` serves | 1 |

Stages 7 and 9 can proceed beside 4–6. Stage 8 cannot. Stage 10 publishes the shell only, and it waits until that deb exists in this tree. The hashes in the handoff belong to a package that is not in this checkout.
