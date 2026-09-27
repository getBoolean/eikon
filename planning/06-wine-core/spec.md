# 06 · Wine core, in one process

## Purpose

Bring Wine up on iOS inside the Eikon app process, and run a 64-bit Windows x86 console program through FEX's ARM64EC DLL. This is the foundation for every Windows route: the cross-build, `wineserver` as a thread, pseudo-processes, and the x18 workaround.

## Read first

- `planning/requirements.md`: "Running Windows games", "Constraints" (games run inside the app process, hardware facts, especially x18, upstream code stays clean), "Prior art" (Proton's build flags and FEX DLLs, Madeira's one-process design and x18 approach), "Operational requirements" (Wine cross-compile, `wineserver` thread, Mach task ports), "Known risks" (one process, upstream Wine gaps).
- `planning/deep_project_interview.md`.
- `planning/05-fexcore-ios/spec.md` (FEXCore API, x18 gate results).

## Scope

**In:**
- Wine as a submodule at `wine-11.0`, switched to bylaws' `upstream-arm64ec` branch only if a missing piece that FEX's DLLs need blocks progress (record which one). iOS changes as patch files.
- Cross-build: Wine's build tools built for the Mac first, then Wine's Unix side cross-compiled for iOS arm64 (a new host target). PE DLLs built with llvm-mingw (`--enable-archs` including arm64ec and aarch64, following Proton). Mach-O Unix libraries linked or loaded into the app.
- The Darwin ARM64 CPU layer for Wine's ntdll Unix side (Wine's macOS port is x86_64 only, so this is new): signals, contexts, and exception dispatch.
- **`wineserver` as a thread** in the app process. Replace its use of Mach task ports for thread state and memory access with in-process equivalents.
- **Pseudo-processes:** a program that starts another program gets a pseudo-process in the same Mach process (as in Madeira). Design how handles, the address space, and PE image bases are kept apart or shared, and what a child exit or crash does.
- **x18:** patch x18 reads in each loaded Windows ARM64/ARM64EC module into trampolines that fetch the TEB from `TPIDRRO_EL0`. Add a fault handler for reads that were missed, and have the Wine dispatcher restore x18 on entry to PE code. Measure the cost of faults.
- `libarm64ecfex.dll` (FEX's ARM64EC DLL) built with llvm-mingw, wired to 05's FEXCore.
- Loading Wine's own ARM64 PE DLLs needs executable mappings of unsigned code, so it needs JIT. Record exactly where, for 14's no-JIT route.
- A Wine prefix per game (keyed by hash) inside the app's data: creation, and its location under each install method.
- Crash containment within limits: a game's crash takes the app down, but the next launch reports what happened.

**Out:** 32-bit programs and the guest window (07), windows, graphics, and audio (08), and the no-JIT route (14).

## Needs

- 05 (FEXCore, embedding API, gate results), 02 (runtime interface), 01 (build).

## Provides

- A Wine build for iOS and macOS, the in-process `wineserver`, pseudo-processes, and the x18 handling (07, 08, 14).

## Desktop check

An Apple silicon Mac shares Darwin's handling of x18, so the in-process design, the x18 patching, and FEX integration can be tested there before the device.

## Done when

- An original x86-64 Windows console program prints a line, reads input, and starts a child program that runs as a pseudo-process, all through FEX in the app process: on a Mac, and on a device that passes 05's gates.
- The x18 patch counts and fault counts are logged for that run.
