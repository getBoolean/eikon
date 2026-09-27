# Stage 2: Code memory, x18, and the low 4 GB

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A probe log that answers four questions for one device. Can the app start a helper process? Can that helper run code it generates, and by which method? Does the helper keep register x18 across system calls, thread switches, and signals? How much of the helper's low 4 GB is free?

**Architecture:** Guests do not run in the app. From stage 4 on they run in helper processes (`eikon-wine`, later `eikon-linux`). The probes therefore run in a helper, `eikon-probe`, which the app starts with `posix_spawn`. The helper is linked with a 16 KB `__PAGEZERO`, as `eikon-wine` will be. Each JIT method runs in its own helper process, so a crash in one method does not hide the others. The app records each child's exit status or the signal that killed it.

Probes report results. They do not try to obtain JIT.

These four answers gate later stages:

- **Helper spawn.** If the app cannot start a helper, every guest stage is blocked until the app's entitlements change (see `stages.md`, Open decisions).
- **JIT in the helper.** Wine loads its own ARM64 PE DLLs from files that iOS never signature-checks, so even Wine's native code needs executable memory without a signature. With no JIT method, stages 3 to 8 and 14 make no device claim.
- **x18.** Windows ARM64 code keeps its thread pointer (TEB) in x18. Apple reserves x18, and Darwin is reported to clear it. If the helper loses x18, Wine's ARM64 DLLs and FEX's Windows DLLs cannot run as written, and stages 4 to 8 are blocked on that device. The native Kirikiri route (stage 11) and FEX (stage 14) do not use the Windows ABI.
- **Low 4 GB.** Every i386 guest needs memory below `0x100000000`. A normal arm64 iOS executable reserves that whole range as `__PAGEZERO`.

**Tech Stack:** Objective-C, C with inline ARM64 assembly, Mach `vm_region_64`, `vm_allocate` and `vm_remap`, `posix_spawn`, Python for the key-list test.

## Global Constraints

- No JIT bypass and no exploit. Do not call `ptrace`, task-for-pid, or any debugger attach.
- Do not add `dynamic-codesigning` or any other entitlement by hand in this stage. Whether to add one is an open decision in `stages.md`. This stage records which entitlements the installed binaries have, so the owner can decide from the result.
- iOS pages are 16 KB. Use `vm_page_size` or `getpagesize()`, never a literal `4096`.
- Log before every step that can crash: before writing to code memory and before calling into it.
- Never replace an existing mapping. Do not use `MAP_FIXED` or `VM_FLAGS_OVERWRITE`. `MAP_FIXED_NOREPLACE` does not exist on Darwin.
- Do not include `<mach/mach_vm.h>`; the iOS SDK marks it unsupported. Use `vm_region_64`, `vm_allocate`, and `vm_remap` from `<mach/mach.h>`.
- Do not call `pthread_jit_write_protect_np`; the iOS SDK marks it unavailable. Flush the instruction cache with `sys_icache_invalidate` from `<libkern/OSCacheControl.h>`.
- The log lives in the app's own directory, `Library/Application Support/Eikon/`. An app installed under `/Applications` has no container, so `NSDocumentDirectory` resolves to the shared `/var/mobile/Documents`. Do not write there.
- Package id `com.getboolean.eikon`. This stage still links neither Wine nor FEX.
- No program titles in the log format.

---

### Task 1: Log format

**Files:**
- Create: `src/probe/ProbeLog.h`
- Create: `src/probe/ProbeLog.m`
- Test: `tests/test_probe_log.py`

**Interfaces:**
- Consumes: nothing
- Produces: `ProbeLogFormatLine(key, value)` writes `key=value\n`. `EikonDataURL()` returns `Library/Application Support/Eikon/`, creating it if needed. Later stages keep their guest roots and logs under it.

Keys the app writes: `device_model`, `ios_version`, `spawn`, `spawn_errno`, `entitlements_app`, `entitlements_helper`.

Keys the helper prints, which the app stores with a `helper.` prefix: `page_size`, `jit_try`, `jit_mapjit`, `jit_dualmap`, `jit_mprotect`, `jit_method`, `jit_run`, `x18_syscall`, `x18_yield`, `x18_signal`, `pagezero_size`, `low4g_free_bytes`, `low4g_gap_at`, `low4g_page`, `low4g_kr`.

- [ ] **Step 1: Write the failing test**

```python
from pathlib import Path

KEYS = (
    "device_model", "ios_version", "spawn", "spawn_errno",
    "entitlements_app", "entitlements_helper",
    "page_size", "jit_try", "jit_mapjit", "jit_dualmap", "jit_mprotect",
    "jit_method", "jit_run", "x18_syscall", "x18_yield", "x18_signal",
    "pagezero_size", "low4g_free_bytes", "low4g_gap_at", "low4g_page", "low4g_kr",
)

def test_header_lists_every_key():
    text = (Path(__file__).resolve().parents[1] / "src" / "probe" / "ProbeLog.h").read_text(encoding="utf-8")
    for key in KEYS:
        assert key in text
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `python3 -m pytest tests/test_probe_log.py -v`

Expected: FAIL, header missing.

- [ ] **Step 3: Write the header and the writer**

`src/probe/ProbeLog.h`:

```objc
#import <Foundation/Foundation.h>

// App keys: device_model, ios_version, spawn, spawn_errno,
//   entitlements_app, entitlements_helper
// Helper keys (stored as helper.<key>): page_size, jit_try, jit_mapjit,
//   jit_dualmap, jit_mprotect, jit_method, jit_run, x18_syscall, x18_yield,
//   x18_signal, pagezero_size, low4g_free_bytes, low4g_gap_at, low4g_page,
//   low4g_kr
NSString *ProbeLogFormatLine(NSString *key, NSString *value);
NSURL *EikonDataURL(void);
NSURL *ProbeLogURL(void);
BOOL ProbeLogAppend(NSString *key, NSString *value, NSError **error);
```

`src/probe/ProbeLog.m`:

```objc
#import "ProbeLog.h"

NSString *ProbeLogFormatLine(NSString *key, NSString *value) {
    return [NSString stringWithFormat:@"%@=%@\n", key, value];
}

NSURL *EikonDataURL(void) {
    NSFileManager *files = [NSFileManager defaultManager];
    NSURL *support = [files URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:nil];
    NSURL *dir = [support URLByAppendingPathComponent:@"Eikon" isDirectory:YES];
    [files createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

NSURL *ProbeLogURL(void) {
    return [EikonDataURL() URLByAppendingPathComponent:@"probe.log"];
}

BOOL ProbeLogAppend(NSString *key, NSString *value, NSError **error) {
    NSData *line = [ProbeLogFormatLine(key, value) dataUsingEncoding:NSUTF8StringEncoding];
    NSURL *url = ProbeLogURL();
    if (![[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
        return [line writeToURL:url options:NSDataWritingAtomic error:error];
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:url error:error];
    if (!handle) return NO;
    [handle seekToEndOfFile];
    [handle writeData:line];
    [handle synchronizeFile];
    [handle closeFile];
    return YES;
}
```

Add `src/probe/ProbeLog.m` to `Eikon_FILES` in the `Makefile`.

- [ ] **Step 4: Run the test**

Run: `python3 -m pytest tests/test_probe_log.py -v`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/probe/ProbeLog.h src/probe/ProbeLog.m tests/test_probe_log.py Makefile
git commit -m "Add the probe log contract."
```

### Task 2: The helper and its code-memory probe

**Files:**
- Create: `tools/probe/main.c`
- Create: `tools/probe/jit.c`
- Create: `tools/probe/probe.h`
- Modify: `Makefile`

**Interfaces:**
- Consumes: nothing
- Produces: `eikon-probe`, installed at `/var/jb/usr/libexec/eikon-probe` and linked with `-Wl,-pagezero_size,0x4000`. It prints `key=value` lines to stdout and calls `fflush` after each one. Modes:

```
eikon-probe --jit=mapjit|dualmap|mprotect   # one method; exits 0 when the code returned 42
eikon-probe --x18
eikon-probe --low4g
```

`probe.h` declares `void emit(const char *key, const char *fmt, ...)`, which prints one line and flushes.

Each JIT mode tries one way that a process which already has JIT can run generated code. It prints `jit_try=<method>:write` before writing, and `jit_try=<method>:call` before calling. The generated code is `mov w0, #42; ret` (`0x52800540`, `0xD65F03C0`).

1. `mapjit`: `mmap` with `PROT_READ | PROT_WRITE | PROT_EXEC` and `MAP_JIT`, write, invalidate the cache, call. On A12 and later chips a thread cannot write to a `MAP_JIT` page without a permission toggle, and iOS has no public toggle. A crash at `mapjit:write` is the expected result there, and it is still a useful answer.
2. `dualmap`: two addresses for one memory region, the method JavaScriptCore uses. `mmap` the `MAP_JIT` region, then `vm_remap` it with `copy = FALSE` to a second address. `mprotect` the original to `PROT_READ | PROT_EXEC` and the alias to `PROT_READ | PROT_WRITE`. Write through the alias, invalidate the cache at the executable address, and call through the executable address.
3. `mprotect`: an ordinary read-write page, written, then `mprotect` to `PROT_READ | PROT_EXEC`, then called. This works only when something outside Eikon has already marked the process as debugged.

A failed call prints `jit_<method>=fail:<errno>` and exits 1. A successful run prints `jit_<method>=42` and exits 0.

- [ ] **Step 1: Write the helper**

`main.c` parses the mode and dispatches. `jit.c` holds the three methods. Do not add a fourth method that attaches a debugger.

Add to the `Makefile`, after the application block:

```make
TOOL_NAME = eikon-probe
eikon-probe_FILES = tools/probe/main.c tools/probe/jit.c tools/probe/x18.c tools/probe/low4g.c
eikon-probe_CFLAGS = -Itools/probe
eikon-probe_LDFLAGS = -Wl,-pagezero_size,0x4000
eikon-probe_INSTALL_PATH = /usr/libexec

include $(THEOS_MAKE_PATH)/tool.mk
```

`x18.c` and `low4g.c` come from Tasks 3 and 4. Until they exist, list only the files that do.

- [ ] **Step 2: Commit**

```bash
git add tools/probe Makefile
git commit -m "Add the probe helper and its three code-memory methods."
```

### Task 3: x18 probe

**Files:**
- Create: `tools/probe/x18.c`

**Interfaces:**
- Consumes: `emit`
- Produces: `x18_syscall`, `x18_yield`, and `x18_signal`. Each is `kept` when x18 still holds a marker value after 10000 rounds of that event. Otherwise it is `lost:<round>:<hex value seen>`.

- [ ] **Step 1: Write the probe**

The compiler never allocates x18 on Darwin, so a value placed there with inline assembly is changed only by the kernel. Set and read it with:

```c
static inline void x18_set(uint64_t v) { __asm__ volatile("mov x18, %0" :: "r"(v)); }
static inline uint64_t x18_get(void) { uint64_t v; __asm__ volatile("mov %0, x18" : "=r"(v)); return v; }
```

For each round, set the marker `0x45494B4F4E000000 | round`, trigger the event, then read it back:

- `syscall`: `getppid()`.
- `yield`: `sched_yield()`, while two other threads spin, so the thread really is switched out. Also run one round with `usleep(1000)`.
- `signal`: `raise(SIGUSR1)` with an empty handler installed.

Print the first loss, or `kept`. Before the first `emit` of each mode, restore x18 to 0: the helper's own code does not depend on it, but keep it predictable.

- [ ] **Step 2: Check on a Mac first**

Build `x18.c` with a small `main` for macOS arm64 and run it. Record the Mac result in the commit message. The Mac and iOS kernels may differ, and only the device result gates later stages.

- [ ] **Step 3: Commit**

```bash
git add tools/probe/x18.c Makefile
git commit -m "Measure whether x18 survives syscalls, thread switches, and signals."
```

### Task 4: Low 4 GB probe

**Files:**
- Create: `tools/probe/low4g.c`

**Interfaces:**
- Consumes: `emit`
- Produces: `pagezero_size` as the hex `vmsize` of the helper's `__PAGEZERO` segment, or `none`; `low4g_free_bytes` as a decimal count of unmapped bytes in `[vm_page_size, 0x100000000)`; `low4g_gap_at` as the hex start of the largest gap, or `none`; `low4g_page` as `ok`, `fail`, or `skip` when there is no gap; and `low4g_kr` as the decimal `kern_return_t` when `low4g_page` is `fail`.

- [ ] **Step 1: Write the probe**

Read `__PAGEZERO` from `_dyld_get_image_header(0)` by walking its `LC_SEGMENT_64` load commands.

Walk `vm_region_64(mach_task_self(), &addr, &size, VM_REGION_BASIC_INFO_64, ...)`, starting at `vm_page_size` and stopping at `0x100000000`. The gaps are the spaces between the returned regions, clipped to that range. Sum the gaps and remember the largest.

If a gap exists, call `vm_allocate(mach_task_self(), &at, vm_page_size, VM_FLAGS_FIXED)` with `at` at the gap's start. Without `VM_FLAGS_OVERWRITE`, this returns `KERN_NO_SPACE` instead of replacing anything. On `KERN_SUCCESS`, `vm_deallocate` the page and print `low4g_page=ok`. Otherwise print `low4g_page=fail` and `low4g_kr=<kr>`.

Do not reserve the whole gap. A one-page answer is the measurement this stage needs.

- [ ] **Step 2: Commit**

```bash
git add tools/probe/low4g.c Makefile
git commit -m "Measure free space in the helper's low 4 GB."
```

### Task 5: Button, spawning, and device run

**Files:**
- Create: `src/probe/ProbeRunner.h`
- Create: `src/probe/ProbeRunner.m`
- Modify: `src/RootViewController.m`
- Create: `plans/probe-result.md`

**Interfaces:**
- Consumes: `ProbeLogAppend`, `eikon-probe`
- Produces: a button labeled `Run probes` that truncates `probe.log`, then writes the app keys, and then runs the helper five times: `--low4g`, `--x18`, and each `--jit=` method. Every helper stdout line is stored as `helper.<key>=<value>`. After each run, `helper.<mode>.exit` records `exit:<n>` or `signal:<n>`. `helper.jit_method` is the first of `dualmap`, `mapjit`, `mprotect` whose line was `42`, or `none`, and `helper.jit_run` is `42` or `skip`.

- [ ] **Step 1: Write the runner**

Read `device_model` from `sysctlbyname("hw.machine")`, and `ios_version` from `[[NSProcessInfo processInfo] operatingSystemVersionString]`.

Start each helper with `posix_spawn`, with stdout on a pipe. If `posix_spawn` fails, write `spawn=fail` and `spawn_errno=<n>`, and skip the helper runs. Otherwise write `spawn=ok`. `waitpid` gives the exit status or signal.

Run the helpers on a background queue. When they finish, show the log in a second label.

- [ ] **Step 2: Rebuild, install, and run on a Dopamine device**

```bash
make package FINALPACKAGE=1
```

Open the app and tap `Run probes`. Copy `Library/Application Support/Eikon/probe.log` off the device from the mobile user's home, then run:

```bash
ssh mobile@<device> 'for m in --low4g --x18 --jit=dualmap --jit=mapjit --jit=mprotect; do /var/jb/usr/libexec/eikon-probe $m; echo "exit=$?"; done'
ssh mobile@<device> 'ldid -e /var/jb/Applications/Eikon.app/Eikon; ldid -e /var/jb/usr/libexec/eikon-probe'
```

The ssh run is the comparison for when the app cannot spawn. A process started from the shell may be treated differently from one the app starts, so record both.

- [ ] **Step 3: Record the result**

Create `plans/probe-result.md` with four sections: `app` (every line of `probe.log`), `shell` (the ssh output), `entitlements` (both `ldid -e` outputs), and `device` (model and iOS version). Later stages read this file:

- `spawn=fail`: every guest stage is blocked until the owner decides the app's entitlements.
- `helper.jit_run=skip`: stage 3 builds and stops without claiming a device run. The owner decides whether to add `dynamic-codesigning`.
- Any `helper.x18_*` line other than `kept`: the Wine route (stages 4 to 8) is blocked on this device. Stage 11 and stage 14 are unaffected.
- `helper.low4g_page` other than `ok`: i386 guests are blocked on this device. Stages 4 to 6 build and pass their desktop oracles, but make no device claim, and stage 7 moves ahead of stage 4.

- [ ] **Step 4: Commit**

```bash
git add src/probe src/RootViewController.m plans/probe-result.md Makefile
git commit -m "Run the probes in a spawned helper and record the device result."
```
