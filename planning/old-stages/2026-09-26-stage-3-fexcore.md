# Stage 3: FEXCore runs one x86 function

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An x86 function that returns `42` does so inside an Eikon helper process, translated by FEXCore's JIT, using the code-memory method stage 2 proved for helpers.

**Architecture:** FEX is the only x86 translator in Eikon. FEXCore, the JIT and CPU core, is shared by three front ends:
- the Linux front end (stages 9 and 14)
- `libwow64fex.dll` for i386 Windows games (stage 4)
- `libarm64ecfex.dll` for amd64 Windows games (stage 7)

Changes to FEXCore itself carry forward to all three: a code buffer that can write through one address and run through another, 16 KB page handling, and staying clear of x18. The Darwin host glue in this stage (memory, threads, signals) carries forward to the Linux front end in stage 14. Inside Wine, the DLLs get memory and signals through Wine's Windows calls instead, so stage 4 maps those calls onto the same arena rules.

FEX is a submodule pinned at tag `FEX-2609`, and its checkout stays clean. Changes that cannot be avoided live as patch files in `patches/fex/`, applied to a copy of the tree under `build/`. If stage 2's device log said `helper.jit_run` was anything but `42`, this stage builds and passes its Mac check, then stops. It does not invent a way to get JIT.

The nine bytes `B8 28 00 00 00 83 C0 02 C3` mean `mov eax, 40; add eax, 2; ret` in both 32-bit and 64-bit mode. The device run translates them as 64-bit code, so it does not need the low 4 GB. The Linux host check also runs them as i386.

**Tech Stack:** FEX-Emu `FEX-2609`, C and C++, clang, CMake, nasm, Theos, a Linux ARM64 host, and an Apple-silicon Mac.

## Global Constraints

- Pin `third_party/FEX` at `FEX-2609`. If stage 9 already added it, reuse that submodule. Do not commit changes inside it.
- FEX translates only the guest's x86 code. Wine is never run under FEX. Wine is native ARM64, and FEX is loaded inside it as a CPU DLL.
- No JIT bypass. The arena returns `ENOTSUP` when stage 2 said `skip`.
- No program titles.

---

### Task 1: Pin FEX and define the blob

**Files:**
- Create: `third_party/FEX` (submodule), unless stage 9 already created it
- Create: `src/guest/add42.bin`
- Create: `src/guest/add42.h`
- Test: `tests/test_add42.py`

**Interfaces:**
- Consumes: nothing
- Produces: `kAdd42[]` and `kAdd42Len`, the bytes of `mov eax, 40; add eax, 2; ret`

- [ ] **Step 1: Write the failing test**

```python
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BLOB = bytes([0xB8, 40, 0, 0, 0, 0x83, 0xC0, 2, 0xC3])

def test_blob_is_add_two_to_forty():
    assert (ROOT / "src" / "guest" / "add42.bin").read_bytes() == BLOB

def test_header_matches_blob():
    text = (ROOT / "src" / "guest" / "add42.h").read_text(encoding="utf-8")
    body = re.search(r"kAdd42\[\]\s*=\s*\{([^}]*)\}", text).group(1)
    assert bytes(int(tok, 0) for tok in body.replace(" ", "").split(",") if tok) == BLOB
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `python3 -m pytest tests/test_add42.py -v`

Expected: FAIL

- [ ] **Step 3: Add the bytes and the submodule**

```bash
git submodule add https://github.com/FEX-Emu/FEX third_party/FEX
git -C third_party/FEX checkout FEX-2609
git -C third_party/FEX submodule update --init --recursive
```

`src/guest/add42.h`:

```c
#pragma once
#include <stddef.h>
#include <stdint.h>

static const uint8_t kAdd42[] = { 0xB8, 40, 0, 0, 0, 0x83, 0xC0, 2, 0xC3 };
static const size_t kAdd42Len = sizeof kAdd42;
```

Write those same bytes to `src/guest/add42.bin`.

- [ ] **Step 4: Run the test**

Run: `python3 -m pytest tests/test_add42.py -v`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add .gitmodules third_party/FEX src/guest/add42.bin src/guest/add42.h tests/test_add42.py
git commit -m "Pin FEX-2609 and the add-42 guest blob."
```

### Task 2: Run the blob under FEX on a Linux ARM64 host

**Files:**
- Create: `tests/host/add42_i386.asm`
- Create: `tests/host/add42_x86_64.asm`
- Create: `tests/host/run_add42_fex.sh`

**Interfaces:**
- Consumes: `src/guest/add42.bin`, and stage 9's `build/fex/Bin/FEXInterpreter` (build it with stage 9 Task 2 Step 1 if it does not exist yet)
- Produces: exit status 0 from the script when both ELFs exit 42 under FEX

Each `_start` calls an `add42` whose body is `incbin "../../src/guest/add42.bin"`, then exits with its return value. The i386 ELF exits with `int 0x80` (`eax=1`, `ebx=ret`), and the x86-64 ELF with `syscall` (`eax=60`, `edi=ret`). Both are static and need no root filesystem.

- [ ] **Step 1: Write and run the script**

```bash
#!/bin/sh
set -eu
cd "$(dirname "$0")"
out=../../build/add42
mkdir -p "$out"
nasm -f elf32 -o "$out/add42_i386.o" add42_i386.asm
x86_64-linux-gnu-ld -m elf_i386 -o "$out/add42_i386" "$out/add42_i386.o"
nasm -f elf64 -o "$out/add42_x86_64.o" add42_x86_64.asm
x86_64-linux-gnu-ld -m elf_x86_64 -o "$out/add42_x86_64" "$out/add42_x86_64.o"
for elf in add42_i386 add42_x86_64; do
    set +e
    ../../build/fex/Bin/FEXInterpreter "$out/$elf"
    rc=$?
    set -e
    echo "$elf=$rc"
    [ "$rc" -eq 42 ] || exit 1
done
```

Expected: `add42_i386=42`, `add42_x86_64=42`, and exit 0.

This proves the bytes and FEX's JIT on ARM64 Linux. It does not prove Darwin.

- [ ] **Step 2: Commit**

```bash
git add tests/host/add42_i386.asm tests/host/add42_x86_64.asm tests/host/run_add42_fex.sh
git commit -m "Check the add-42 blob under FEX on Linux."
```

### Task 3: Map FEXCore's host needs

**Files:**
- Create: `plans/fexcore-darwin.md`

**Interfaces:**
- Consumes: `third_party/FEX` at `FEX-2609`
- Produces: the design for Tasks 4 and 5, and the shared base for stages 4, 7, and 14

- [ ] **Step 1: Read how the Windows front end embeds FEXCore**

The WoW64 and ARM64EC DLLs run FEXCore without the Linux front end, so they are the closest model for embedding it. Write down, in `plans/fexcore-darwin.md`:

- the calls that create a context and a thread, set guest registers, and run from a guest address until it returns
- how FEXCore allocates its code buffer, and whether it can write code through one address and run it through another (needed when stage 2 chose `dualmap`)
- how it finds and handles self-modifying code: which signals, and which `mprotect` granularity
- whether its ARM64 backend or dispatcher uses x18
- where it assumes a 4 KB host page
- which of its host calls are Linux-only or Windows-only, grouped by area: memory, threads, signals, files, and time

- [ ] **Step 2: Decide whether to continue**

If running one block needs more than the memory, thread, signal, and time areas, stop and report to the owner with this file.

- [ ] **Step 3: Commit**

```bash
git add plans/fexcore-darwin.md
git commit -m "Map what FEXCore needs from a Darwin host."
```

### Task 4: Code arena

**Files:**
- Create: `src/guest/EikonCodeArena.h`
- Create: `src/guest/EikonCodeArena.c`

**Interfaces:**
- Consumes: stage 2's method, passed to the helper as `--jit-method=<m>`
- Produces:

```c
typedef struct {
    void *rx;
    void *rw;
    size_t size;
} EikonCodeBlock;

// Returns 0 on success. Returns ENOTSUP when the method is none.
// For dualmap, rx and rw are different addresses of the same memory.
int EikonCodeArenaSetMethod(const char *method);
int EikonCodeArenaReserve(size_t size, EikonCodeBlock *out);
int EikonCodeArenaSeal(EikonCodeBlock block, size_t offset, size_t len); // flush and make executable
void EikonCodeArenaUnmap(EikonCodeBlock block);
```

- [ ] **Step 1: Implement the arena**

Use the same calls as stage 2's `tools/probe/jit.c`:

- `dualmap`: a `MAP_JIT` region plus a `vm_remap` alias. `rw` is writable, `rx` is executable. `Seal` flushes the cache at `rx`.
- `mapjit`: one `MAP_JIT` read-write-execute mapping. `rx == rw`. `Seal` only flushes the cache with `sys_icache_invalidate`.
- `mprotect`: a read-write mapping. `Seal` flushes the cache, then `mprotect`s the range to `PROT_READ | PROT_EXEC`.

On macOS, `mapjit` may also toggle `pthread_jit_write_protect_np`, which exists there. On iOS, do not call it. Sizes round up to `getpagesize()`.

- [ ] **Step 2: Commit**

```bash
git add src/guest/EikonCodeArena.h src/guest/EikonCodeArena.c
git commit -m "Add the code arena for FEXCore's JIT."
```

### Task 5: FEXCore on a Mac, then in the helper

**Files:**
- Create: `cmake/ios.toolchain.cmake`
- Create: `src/guest/fexcore/` (Darwin host glue)
- Create: `patches/fex/` (only if needed)
- Create: `src/guest/RunAdd42.cpp`
- Create: `docs/build-fexcore-darwin.md`
- Modify: `tools/probe/main.c`, `src/RootViewController.m`, `Makefile`

**Interfaces:**
- Consumes: Tasks 3 and 4
- Produces: `eikon-probe --add42 --jit-method=<m>`, which prints `add42=<n>`, and a button `Run add 42` that starts it and copies the line into `probe.log`

- [ ] **Step 1: Build FEXCore for macOS arm64 and run the blob there**

Build FEXCore as a static library with the Darwin glue from Task 3's list. Route its code buffer to the arena. A small Mac harness (`tests/host/run_add42_fexcore.cpp`) sets up a 64-bit guest stack, copies `kAdd42` into guest memory, and runs from its address until the `ret` reaches a stop address. It reads `RAX`.

Expected on the Mac: `add42=42`. Record every patch and glue file in `docs/build-fexcore-darwin.md`.

- [ ] **Step 2: Build for iOS and run in the helper**

`cmake/ios.toolchain.cmake` sets `CMAKE_SYSTEM_NAME` to `iOS` and `CMAKE_OSX_ARCHITECTURES` to `arm64`. Link the same library and harness code into `eikon-probe`.

Expected on the device: `add42=42`. If the arena returns `ENOTSUP`, the line is `add42=unsupported` and the stage is done. If the helper is killed, the button appends `add42=signal:<n>`.

- [ ] **Step 3: Commit**

```bash
git add src/guest cmake patches docs/build-fexcore-darwin.md tools/probe src/RootViewController.m Makefile tests/host
git commit -m "Run the add-42 blob through FEXCore on macOS and iOS."
```
