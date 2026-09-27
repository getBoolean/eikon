# 13 · Linux x86-64 games (needs JIT)

## Purpose

Run Linux x86-64 games on iOS through FEX's Linux front end, inside the Eikon app process, with graphics, audio, and input. Available only when the process has usable JIT (one build; the route picker checks 01's JIT API). The owner sequenced this late: the collection is mostly Windows.

## Read first

- `planning/requirements.md`: Goal 2. "Running Linux games", "Constraints" (games run inside the app process, stay on iOS: FEX only for Linux, no QEMU or v86, and the hardware facts), "Known risks" (16 KB pages).
- `planning/deep_project_interview.md`.
- `planning/05-fexcore-ios/spec.md`, `planning/04-input/spec.md`, `planning/08-wine-media/spec.md` (Metal work to reuse).

## Scope

**In:**
- **FEX's Linux front end on Darwin:** a Linux syscall layer implemented on Darwin in the app process, where FEX normally passes syscalls to a Linux kernel. That covers files, memory, threads and futexes, signals, time, sockets as needed, and `/proc` and `/dev` as games use them.
- **ELF loading in-process.** x86-64 Linux programs, especially non-PIE ones, expect low addresses that iOS can't provide. **Open decision:** a guest base offset for 64-bit Linux guests too (like 07's window), and only accepting PIE, or something else. Decide from 05's measurements.
- **fork/exec:** pseudo-processes in the same process, as for Wine.
- **Rootfs:** which x86-64 libraries ship (glibc, SDL, and so on), and their licenses and credits.
- **Graphics:** FEX thunks from guest GL/Vulkan to host libraries. **Open decision:** Vulkan through MoltenVK, and GL through a translation layer on Metal. Present into 02's session host. Stop Metal in the background.
- **Audio:** guest ALSA, PulseAudio, or SDL audio routed to CoreAudio.
- **Input:** from 04, delivered as SDL/evdev-style input.
- Implement 02's runtime interface and route-picker entry, available only with JIT.

**Out:** a no-JIT route for Linux (Linux needs JIT), and Box64 (not used for Linux).

## Needs

- 05 (FEXCore and gates), 04 (input), and 02. Reuses 08's Metal work where it can.

## Done when

- An original Linux x86-64 test game (SDL, GL or Vulkan, sound, input) runs on a device with JIT and exits cleanly. It also runs on a Mac as the desktop check.
- Its save location is registered with 12's interface.
