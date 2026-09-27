# Stage 2: Code memory and the low 4 GB

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The shell writes a probe log that says whether this process can already execute generated ARM64 code, and how much of the low 4 GB is free.

**Architecture:** Two probes run on a button. They report results. They do not try to obtain JIT. The low-4 GB probe only reads existing mappings and attempts `MAP_FIXED_NOREPLACE` inside a gap. Kirikiri and BGI need that low range; Unity does not.

**Tech Stack:** Objective-C, `mach_vm_region`, `mmap`, Python for the log parser.

## Global Constraints

- No JIT bypass and no exploit. Do not call `ptrace`, task-for-pid, or any debugger attach. Do not add `dynamic-codesigning` by hand.
- If `mmap` with `MAP_JIT` fails, record `errno` and stop that attempt.
- Do not `MAP_FIXED` over an existing mapping.
- Package id `com.getboolean.eikon`. This stage still links neither Box64, Wine, nor FEX.
- No program titles in the log format.

---

### Task 1: Log format

**Files:**
- Create: `src/probe/ProbeLog.h`
- Create: `src/probe/ProbeLog.m`
- Test: `tests/test_probe_log.py`

**Interfaces:**
- Consumes: nothing
- Produces: `ProbeLogFormatLine(key, value)` writes `key=value\n`. Keys used later: `jit_map`, `jit_run`, `jit_errno`, `low4g_free_bytes`, `low4g_gap_at`, `low4g_page`

- [ ] **Step 1: Write the failing test**

```python
from pathlib import Path

def test_parser_reads_the_contract():
    text = (Path(__file__).resolve().parents[1] / "src" / "probe" / "ProbeLog.h").read_text(encoding="utf-8")
    for key in ("jit_map", "jit_run", "jit_errno", "low4g_free_bytes", "low4g_gap_at", "low4g_page"):
        assert key in text
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `python -m pytest tests/test_probe_log.py -v`

Expected: FAIL, header missing.

- [ ] **Step 3: Write the header and the writer**

`src/probe/ProbeLog.h`:

```objc
#import <Foundation/Foundation.h>

// Log keys: jit_map, jit_run, jit_errno, low4g_free_bytes, low4g_gap_at, low4g_page
NSString *ProbeLogFormatLine(NSString *key, NSString *value);
NSURL *ProbeLogURL(NSFileManager *files);
BOOL ProbeLogAppend(NSString *key, NSString *value, NSError **error);
```

`src/probe/ProbeLog.m`:

```objc
#import "ProbeLog.h"

NSString *ProbeLogFormatLine(NSString *key, NSString *value) {
    return [NSString stringWithFormat:@"%@=%@\n", key, value];
}

NSURL *ProbeLogURL(NSFileManager *files) {
    NSURL *docs = [files URLForDirectory:NSDocumentDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:nil];
    return [docs URLByAppendingPathComponent:@"probe.log"];
}

BOOL ProbeLogAppend(NSString *key, NSString *value, NSError **error) {
    NSData *line = [ProbeLogFormatLine(key, value) dataUsingEncoding:NSUTF8StringEncoding];
    NSURL *url = ProbeLogURL([NSFileManager defaultManager]);
    if (![[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
        return [line writeToURL:url options:NSDataWritingAtomic error:error];
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:url error:error];
    if (!handle) return NO;
    [handle seekToEndOfFile];
    [handle writeData:line];
    [handle closeFile];
    return YES;
}
```

Add `src/probe/ProbeLog.m` to `Eikon_FILES` in the `Makefile`.

- [ ] **Step 4: Run the test**

Run: `python -m pytest tests/test_probe_log.py -v`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/probe/ProbeLog.h src/probe/ProbeLog.m tests/test_probe_log.py Makefile
git commit -m "Add the probe log contract."
```

### Task 2: Code-memory probe

**Files:**
- Create: `src/probe/CodeMemoryProbe.h`
- Create: `src/probe/CodeMemoryProbe.m`
- Test: device log, after Task 4

**Interfaces:**
- Consumes: `ProbeLogAppend`
- Produces: `jit_map` is `ok` or `fail`; `jit_run` is `42` or `skip`; `jit_errno` is the decimal errno when the map fails

- [ ] **Step 1: Write the probe**

`src/probe/CodeMemoryProbe.h`:

```objc
#import <Foundation/Foundation.h>

void RunCodeMemoryProbe(void);
```

`src/probe/CodeMemoryProbe.m`:

```objc
#import "CodeMemoryProbe.h"
#import "ProbeLog.h"
#import <errno.h>
#import <pthread.h>
#import <sys/mman.h>

void RunCodeMemoryProbe(void) {
    size_t size = 4096;
    int flags = MAP_PRIVATE | MAP_ANONYMOUS;
#ifdef MAP_JIT
    flags |= MAP_JIT;
#endif
    void *page = mmap(NULL, size, PROT_READ | PROT_WRITE, flags, -1, 0);
    if (page == MAP_FAILED) {
        ProbeLogAppend(@"jit_map", @"fail", nil);
        ProbeLogAppend(@"jit_errno", [NSString stringWithFormat:@"%d", errno], nil);
        ProbeLogAppend(@"jit_run", @"skip", nil);
        return;
    }
    ProbeLogAppend(@"jit_map", @"ok", nil);

#if defined(__APPLE__) && defined(__aarch64__)
    pthread_jit_write_protect_np(0);
#endif
    uint32_t *words = page;
    words[0] = 0x52800540; // mov w0, #42
    words[1] = 0xD65F03C0; // ret
    __builtin___clear_cache((char *)page, (char *)page + 8);
#if defined(__APPLE__) && defined(__aarch64__)
    pthread_jit_write_protect_np(1);
#endif
    if (mprotect(page, size, PROT_READ | PROT_EXEC) != 0) {
        ProbeLogAppend(@"jit_run", @"skip", nil);
        ProbeLogAppend(@"jit_errno", [NSString stringWithFormat:@"%d", errno], nil);
        munmap(page, size);
        return;
    }
    int (*fn)(void) = page;
    int value = fn();
    ProbeLogAppend(@"jit_run", [NSString stringWithFormat:@"%d", value], nil);
    munmap(page, size);
}
```

`mprotect` to executable is the check that the process already has JIT. On failure the log says `skip`. Do not add a second attempt that attaches a debugger.

- [ ] **Step 2: Add the file to `Eikon_FILES`**

- [ ] **Step 3: Commit**

```bash
git add src/probe/CodeMemoryProbe.h src/probe/CodeMemoryProbe.m Makefile
git commit -m "Record whether the process can already run generated code."
```

### Task 3: Low 4 GB probe

**Files:**
- Create: `src/probe/AddressSpaceProbe.h`
- Create: `src/probe/AddressSpaceProbe.m`

**Interfaces:**
- Consumes: `ProbeLogAppend`
- Produces: `low4g_free_bytes` as a decimal count of unmapped bytes below `0x100000000`; `low4g_gap_at` as the hex start of the largest gap, or `none`; `low4g_page` as `ok` if a one-page `MAP_FIXED_NOREPLACE` in that gap succeeds, otherwise `fail`

- [ ] **Step 1: Write the probe**

Walk `mach_vm_region` from `0x10000` to `0x100000000`. Sum the gaps. Remember the largest gap whose size is at least `4096` and whose start is page-aligned.

If a gap exists, `mmap` one page at its start with `MAP_FIXED_NOREPLACE | MAP_PRIVATE | MAP_ANONYMOUS` and `PROT_NONE`. On success, `munmap` it and log `low4g_page=ok`. On failure, log `low4g_page=fail` and the errno in `jit_errno` is the wrong key; use a line `low4g_errno=<errno>` as well. Add `low4g_errno` to the key list in `ProbeLog.h` and to `tests/test_probe_log.py`.

Do not reserve the whole gap. A one-page answer is the measurement this stage needs.

- [ ] **Step 2: Commit**

```bash
git add src/probe/AddressSpaceProbe.h src/probe/AddressSpaceProbe.m src/probe/ProbeLog.h tests/test_probe_log.py Makefile
git commit -m "Measure free space in the low 4 GB."
```

### Task 4: Button and device run

**Files:**
- Modify: `src/RootViewController.m`

**Interfaces:**
- Consumes: `RunCodeMemoryProbe`, `RunAddressSpaceProbe`
- Produces: a button labeled `Run probes` that truncates `probe.log` and then runs both probes

- [ ] **Step 1: Add the button**

Truncate the log with `[NSData data] writeToURL:atomically:`, then call both probes. Show the log text in a second label after they return.

- [ ] **Step 2: Rebuild, install, and run on a Dopamine device**

```bash
make package FINALPACKAGE=1
```

Open the app, tap `Run probes`, then copy `Documents/probe.log` off the device.

- [ ] **Step 3: Record the result in the commit message of a notes file**

Create `plans/probe-result.md` with the six keys and their values from that device. This file is how stage 3 knows whether dynarec can be enabled. If `jit_run` is `skip`, stage 3 stops after building Box64 and does not claim the function ran. If `low4g_page` is `fail`, stage 6 still builds, and its notes say Kirikiri guests that require a fixed low base are blocked on this device.

- [ ] **Step 4: Commit**

```bash
git add src/RootViewController.m plans/probe-result.md Makefile
git commit -m "Run the code-memory and address-space probes from the shell."
```
