# 07 · 32-bit Windows programs in a guest window

## Purpose

Run 32-bit (i386) Windows programs, which are most of the collection's `Game.exe` files (11 of 16) and most Kirikiri and BGI games on the Wine route. iOS can't give an app memory below 4 GB, so every 32-bit program lives in a 4 GB **guest window** [B, B+4 GB), and its address `a` is real address `B+a`.

## Read first

- `planning/requirements.md`: "Constraints" (the low-memory section in full, and games running inside the app process), "Prior art" (Madeira's WoW64 work, PR #26, and QEMU's user-mode guest base), "Known risks" (missed pointer conversions corrupt memory).
- `planning/deep_project_interview.md`.
- `planning/05-fexcore-ios/spec.md` (guest window gate, FEX hooks) and `planning/06-wine-core/spec.md`.

## Scope

**In:**
- **FEX:** translated 32-bit code adds B to every memory access. That includes loads, stores, string ops, the stack, and segment-based accesses (the FS-based TEB), and any address FEX computes on the guest's behalf.
- **Wine WoW64:** every pointer that crosses between the 32-bit program and 64-bit Wine gets B added or removed. That covers syscall thunks, structure conversions, callbacks, exceptions, and APCs. Build an audit method so missed conversions are found, not guessed at: tests, and assertions that a pointer lies inside its window.
- **Wine's memory manager** places everything a 32-bit program sees inside its window: the 32-bit TEB and PEB, stacks, relocated 32-bit DLLs, and `KUSER_SHARED_DATA` at B+`0x7ffe0000`. An address limit L that a program asks for becomes [B, B+L).
- The GPU memory interface: define how 08 maps GPU memory into the window for a 32-bit game.
- `libwow64fex.dll` (FEX's aarch64 WoW64 DLL) built with llvm-mingw.
- Pseudo-processes (from 06): each 32-bit pseudo-process gets its own window. Decide the window layout and whether B is fixed or chosen per process, using 05's measured limits.
- Keep the contract route-neutral so Box64's interpreter (14) can use the same one.

**Out:** graphics and audio (08), and the no-JIT interpreter (14).

## Needs

- 06 (Wine build, `wineserver`, pseudo-processes, x18), and 05 (FEX hooks, window feasibility per device).

## Provides

- The guest-window contract and WoW64 pointer conversion (08, 14).

## Done when

- An original i386 Windows test program exercises pointers that cross the boundary (structures, callbacks, exceptions, threads, file I/O, a child process). It runs correctly in its window through FEX on a Mac and on a device that passes the guest-window gate.
- A boundary-check mode catches a deliberately broken conversion in a test.
