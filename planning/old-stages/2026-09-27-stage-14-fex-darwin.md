# Stage 14: Linux guests on a Darwin host

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Signal Drift runs under FEX on a Darwin kernel, first on an Apple-silicon Mac and then on the device in `eikon-linux`, prints both frames, and exits 0.

**Architecture:** Linux guests stay on FEX. FEX translates x86-64 instructions, but it passes Linux system calls straight to a Linux kernel, and iOS runs XNU. This stage adds a Linux system-call layer that FEX calls instead: each x86-64 Linux syscall is carried out with Darwin calls. It starts with only the syscalls Signal Drift makes, and grows from a logged list, the same rule as Wine's `STATUS_NOT_IMPLEMENTED`.

Stage 3 already made FEXCore run on Darwin: code buffer, memory, threads, and signals, with patches in `patches/fex/`. This stage adds the Linux front end on top of it. Most work happens on a Mac, which has the same kernel family and 16 KB pages but allows ordinary JIT and debugging. The device task only repeats the Mac result inside a helper process.

Known problems, in the order they will be met:

- **FEX assumes a Linux host.** Its loader, signal handling, thread creation, and memory code call Linux directly. The syscall layer sits under those too, or they get Darwin versions in `src/linux/`.
- **Page size.** FEX requires 4 KB host pages and refuses 16 KB. On Asahi Linux it runs only inside a 4 KB-page VM, and iOS has none. Task 3 gets past this for a static ELF linked with 16 KB-aligned segments. A general answer means tracking 4 KB guest pages inside 16 KB host pages. That is a later stage, and it is recorded, not attempted, here.
- **JIT and x18.** Stage 3 handled both in FEXCore. This stage reuses its arena and patches.
- **Graphics.** Linux games draw through X11 or Wayland and OpenGL or Vulkan. Nothing here provides those. A later stage has to add a display layer, and FEX's host-library thunks for Vulkan (to MoltenVK) are the likely way in. This stage is console only.

**Tech Stack:** FEX-Emu `FEX-2609` (pinned in stage 9), C and C++, CMake, clang, Theos.

## Global Constraints

- Do not run Linux guests under Box64, QEMU, or v86.
- Changes to FEX live as patches in `patches/fex/`, applied to a copy under `build/`. The submodule stays clean.
- The syscall layer lives in `src/linux/`, outside FEX, behind one interface, so it can be tested without FEX.
- Stage 9's Linux run is the oracle. The Mac run's output must match it byte for byte.
- No JIT bypass. The device task needs `helper.jit_run=42` and `spawn=ok` from stage 2.
- No program titles besides Signal Drift.

---

### Task 1: Map what FEX needs from the host

**Files:**
- Create: `plans/fex-darwin-gaps.md`

**Interfaces:**
- Consumes: `third_party/FEX` at `FEX-2609`, stage 9's build, and stage 3's `plans/fexcore-darwin.md`
- Produces: a written map of FEX's Linux dependencies and Signal Drift's syscall list

- [ ] **Step 1: List Signal Drift's syscalls**

On the stage 9 Linux machine:

```bash
strace -f -o build/signal-drift.strace build/fex/Bin/FEXInterpreter demos/linux/signal-drift-static
```

Record the guest syscalls in `plans/fex-darwin-gaps.md`: `strace` shows the host's view, so also run with FEX's own syscall logging if `FEX-2609` has it. Expect roughly `brk`, `mmap`, `munmap`, `mprotect`, `arch_prctl`, `set_tid_address`, `set_robust_list`, `rseq`, `prlimit64`, `readlinkat`, `getrandom`, `uname`, `newfstatat`, `write`, and `exit_group`.

- [ ] **Step 2: List FEX's own Linux dependencies**

Search FEX's frontend and FEXCore for direct Linux calls, for example `syscall(`, `SYS_`, `/proc/`, `prctl`, `clone`, `signalfd`, `memfd_create`, `mremap`, `personality`, and `MAP_FIXED_NOREPLACE`. Group them by area: loader, memory, signals, threads, and the code buffer. Note which already have a non-Linux path. FEX builds for Windows as `libwow64fex.dll` and `libarm64ecfex.dll`, so FEXCore has some host abstraction to reuse.

- [ ] **Step 3: Page size**

Record where the Linux front end checks the host page size, beyond what stage 3 already found in FEXCore.

If Steps 2 and 3 show that a Mac port needs more than the loader, memory, signal, and syscall areas, stop and report to the owner with this file before continuing.

- [ ] **Step 4: Commit**

```bash
git add plans/fex-darwin-gaps.md
git commit -m "Map FEX's Linux host dependencies for a Darwin port."
```

### Task 2: The syscall layer

**Files:**
- Create: `src/linux/eikon_linux.h`
- Create: `src/linux/eikon_linux.c`
- Test: `tests/host/test_eikon_linux.c`

**Interfaces:**
- Consumes: Task 1's list
- Produces:

```c
// Runs one x86-64 Linux syscall on Darwin. Returns the Linux result:
// a value >= 0, or -errno with Linux errno numbers.
long eikon_linux_syscall(long nr, long a0, long a1, long a2, long a3, long a4, long a5);
```

Unimplemented numbers return `-ENOSYS` (Linux's 38) and log `linux_syscall_missing=<nr>` once per number. Errno values are translated from Darwin numbers to Linux numbers. Structures that differ, such as `stat` and `utsname`, are converted field by field.

- [ ] **Step 1: Host test on the Mac**

For each syscall in Task 1's list, check the result directly: `write` to a pipe, `brk` growing, `mmap` of anonymous memory, `uname` returning `Linux` and `x86_64`, `getrandom` filling a buffer, and an unknown number returning `-38`.

- [ ] **Step 2: Implement until it passes**

- [ ] **Step 3: Commit**

```bash
git add src/linux tests/host/test_eikon_linux.c
git commit -m "Add the Linux syscall layer for Darwin hosts."
```

### Task 3: FEX on an Apple-silicon Mac

**Files:**
- Create: `patches/fex/` (Darwin host patches)
- Create: `docs/build-fex-darwin.md`
- Modify: `demos/linux/Makefile`

**Interfaces:**
- Consumes: Tasks 1 and 2
- Produces: `build/fex-darwin/Bin/FEXInterpreter` running `signal-drift-static-16k` on macOS

- [ ] **Step 1: A 16 KB-aligned guest**

Add a third build to `demos/linux/Makefile`:

```make
signal-drift-static-16k: signal-drift.c
	x86_64-linux-gnu-gcc -O2 -static -Wl,-z,max-page-size=0x4000 -Wl,-z,common-page-size=0x4000 -o $@ $<
```

This lets the loader map every segment on a 16 KB boundary. Keep the plain static build as the target for the later general 4 KB work.

- [ ] **Step 2: Port and build**

Starting from stage 3's patched FEXCore, apply patches until the Linux front end builds on macOS arm64 with the syscall layer, routing each area Task 1 listed to `src/linux/` or to a Darwin version. Record every patch and the reason for it in `docs/build-fex-darwin.md`.

- [ ] **Step 3: Run**

```bash
build/fex-darwin/Bin/FEXInterpreter demos/linux/signal-drift-static-16k ; echo $?
```

Expected: `frame 1`, `frame 2`, and `0`, the same as stage 9's Linux output.

- [ ] **Step 4: Commit**

```bash
git add patches/fex docs/build-fex-darwin.md demos/linux/Makefile src/linux
git commit -m "Run Signal Drift under FEX on macOS."
```

### Task 4: FEX on the device

**Files:**
- Create: `tools/linux/main.c` (the `eikon-linux` helper)
- Modify: `Makefile`, `src/RootViewController.m`, `docs/build-fex-darwin.md`

**Interfaces:**
- Consumes: Task 3, stage 2's `helper.jit_method`
- Produces: `eikon-linux`, installed at `/var/jb/usr/libexec/eikon-linux`, and a button `Run Linux` that starts it on `signal-drift-static-16k` and appends `linux=<exit code>` and its stdout to `probe.log`

- [ ] **Step 1: Build for iOS**

Build the same tree with the iOS toolchain. The code buffer is stage 3's arena, with the `--jit-method=` the app passes. When `helper.jit_run=skip`, the button appends `linux=unsupported` and spawns nothing.

- [ ] **Step 2: Device acceptance**

Expected: `linux=0`, and stdout has both frame lines.

- [ ] **Step 3: Commit**

```bash
git add tools/linux Makefile src/RootViewController.m docs/build-fex-darwin.md
git commit -m "Run Signal Drift under FEX on iOS."
```
