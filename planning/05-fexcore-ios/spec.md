# 05 · FEXCore on iOS, and the device gates

## Purpose

Port FEXCore (FEX-Emu, tag `FEX-2609`) to Darwin so it translates x86 code to ARM64 inside the Eikon app process on iOS, with an Apple silicon Mac as the desktop check. This is the x86 translator whenever the process has usable JIT, for both Windows (06, 07) and Linux (13) games. This split also measures the device gates that decide what later splits may claim on each device.

## Read first

- `planning/requirements.md`: Goals 1, 2, 4. "Builds and JIT", "Constraints" (hardware facts, guest window, device gates, upstream code stays clean), "Prior art" (Valve's FEX config, Madeira's JIT memory), "Known risks" (16 KB pages, TSO speed).
- `planning/deep_project_interview.md`.
- `planning/01-build-packaging-jit/spec.md` (JIT detection, device reports).

## Scope

**In:**
- FEX as a fork starting from `FEX-2609`, with Darwin/iOS changes as commits on the fork's `eikon` branch. The fork builds FEXCore and publishes it as GitHub releases, and Eikon pins them in `third_party/deps.toml`. Build FEXCore as a library for iOS arm64 and for macOS arm64.
- Darwin port of the core:
  - memory allocation and address-space management without Linux calls
  - **16 KB host pages**, where FEX assumes 4 KB. Decide how guest 4 KB page semantics (protection, mapping granularity) are emulated or approximated. This is a known risk: on Asahi Linux, FEX only runs inside a 4 KB VM, and iOS has none.
  - **JIT memory double-mapped:** an RX view and a separate RW alias (A12+ needs a second writable address). The RW alias sits outside any guest window. Instruction cache invalidation.
  - Signal and fault handling with Darwin's `ucontext` layout.
  - x18: generated code and FEX's own code must never use x18 as a general register on Darwin. Document how that is guaranteed.
- A configuration layer: Valve's defaults (`TSOEnabled=1`, `HalfBarrierTSOEnabled=1`, `VectorTSOEnabled=0`, `MemcpySetTSOEnabled=0`, `X87ReducedPrecision=1`, `Multiblock=1`, `MaxInst=500`), plus per-game overrides keyed by game hash and stored in 02's settings. iOS has no public way to turn on Apple's hardware TSO mode, so TSO stays emulated.
- An embedding API for 06/07 (Windows DLL glue) and 13 (Linux front end): run guest code, thread entry, exceptions and signals, and the hooks 07 needs to add a guest base B to every 32-bit memory access.
- **Device gates**, measured in the app process on each device and recorded with 01's device report:
  - the process has JIT (by running generated code)
  - x18 behavior: what Darwin does to x18 across syscalls, context switches, and signals. This informs 06's trampoline design.
  - guest window feasibility: reserve a 4 GB region above 4 GB at a chosen base, allocate and protect inside it, and measure the address-space limits for each install method and entitlement. `__PAGEZERO` can't be shrunk, since the kernel rejects it.
- The gate results feed 02's route picker.

**Out:** Wine (06), the WoW64 pointer conversion (07), and the Linux syscall layer (13).

## Needs

- 01 (JIT on and detected, device reports), 02 (settings store, keyed by hash).

## Provides

- FEXCore for iOS/macOS, its embedding API, and its config layer (06, 07, 13).
- Device gate results (02's route picker, and 06, 07, 13, 14).

## Constraints to carry

- A split whose gate fails still builds and passes its desktop check, but makes no device claim.
- No `ptrace`, no debugger attach, and no task-for-pid.

## Done when

- An original x86 (i386 and amd64) test function that returns 42 runs through FEXCore on a Mac and on a device with JIT.
- Each tested device has a gate report (device, iOS, chip, install method, build).
- Per-game overrides change FEX behavior, which a test shows.
