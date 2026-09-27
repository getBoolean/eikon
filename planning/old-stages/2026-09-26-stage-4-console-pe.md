# Stage 4: A 32-bit Windows program reads a file

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An original i386 Windows program prints `eikon-console` and reads the first byte of a data file. That is the file and console surface Kirikiri and BGI need before they need a window.

**Architecture:** Wine is built as native ARM64 with an i386 PE guest. FEX's `libwow64fex.dll`, built from `FEX-2609`, is the CPU DLL that translates the guest's x86 code. No window, no audio, no Direct3D.

The guest runs in `eikon-wine`, a separate executable linked with a 16 KB `__PAGEZERO`, as stage 2's `eikon-probe` was. That is what gives the i386 guest memory below 4 GB. The app starts it with `posix_spawn`. Wine also needs `wineserver`, and the app starts that the same way. Both are native ARM64 binaries installed under `/var/jb/usr/libexec/`.

Wine's macOS support is x86_64 only; on Apple silicon it runs under Rosetta. Its ARM64 code for signals, thread contexts, and the system-call dispatcher (`dlls/ntdll/unix/signal_arm64.c`) targets Linux and FreeBSD, not Darwin. This stage reuses the parts of Wine's Darwin code that are not CPU-specific, such as file, process, and Mach-O handling. It writes the ARM64 Darwin CPU layer new, in `src/host/signal_arm64_darwin.c`. Files that do not compile for iOS are replaced by `src/host/*_darwin.c` overrides. An override starts as the smallest code this one program needs, and any unimplemented call returns `STATUS_NOT_IMPLEMENTED` and logs its name.

Windows ARM64 code keeps its TEB pointer in x18. The new CPU layer must restore x18 on every return into PE code: after syscalls, signals, and exception dispatch. Restoring it there is not enough if Darwin clears x18 on an ordinary thread switch. The stage 2 `x18_yield` result says which case this device is. If it is not `kept`, this stage stops after the desktop oracle and writes the finding into `plans/wine-ios-gaps.md`.

iOS pages are 16 KB, and Wine and i386 Windows programs assume 4 KB pages. On Asahi Linux, which also uses 16 KB pages, Wine runs only inside a 4 KB-page virtual machine, and iOS has no such VM. Every failure that traces back to page size goes into `plans/wine-ios-gaps.md`. Treat page size as a known risk, not an edge case.

**Tech Stack:** Wine 11.0 configured for `aarch64` and `i386`, FEX `libwow64fex.dll`, llvm-mingw, mingw-w64 `i686`, Theos.

## Global Constraints

- Wine submodule `third_party/wine` at tag `wine-11.0`.
- Do not run Wine under FEX. Wine is native ARM64, and FEX is loaded inside it as the CPU DLL for the guest PE only.
- The guest program in this stage is original and lives in `demos/windows/console`.
- No program titles from outside this repo.
- No JIT bypass. If stage 3 logged `add42=unsupported`, this stage does not claim a device run.
- If `plans/probe-result.md` does not show `helper.low4g_page=ok`, `helper.jit_run=42`, and `kept` for all three `helper.x18_*` lines, i386 guests are blocked on that device. Build everything and pass the desktop oracle, but do not claim a device run.
- Do not copy Autorun's `horizon*.c`. Autorun's Horizon server is replaced by Wine's own `wineserver`, built for iOS.

---

### Task 1: The guest program

**Files:**
- Create: `demos/windows/console/main.c`
- Create: `demos/windows/console/probe.bin`
- Create: `demos/windows/console/Makefile`
- Test: `tests/test_console_guest.py`

**Interfaces:**
- Consumes: nothing
- Produces: `console.exe` (i386) which returns 0 when stdout shows `eikon-console\n` and `probe.bin` begins with `K`

- [ ] **Step 1: Write the failing test**

```python
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def test_probe_byte_is_k():
    assert (ROOT / "demos" / "windows" / "console" / "probe.bin").read_bytes()[:1] == b"K"

def test_source_checks_that_byte():
    text = (ROOT / "demos" / "windows" / "console" / "main.c").read_text(encoding="utf-8")
    assert "eikon-console\\n" in text
    assert "probe.bin" in text
    assert "byte != 'K'" in text
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `python -m pytest tests/test_console_guest.py -v`

Expected: FAIL

- [ ] **Step 3: Write the program**

`demos/windows/console/main.c`:

```c
#include <windows.h>

int main(void) {
    const char msg[] = "eikon-console\n";
    DWORD wrote = 0;
    HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE);
    if (!WriteFile(out, msg, sizeof msg - 1, &wrote, NULL) || wrote != sizeof msg - 1)
        return 1;
    HANDLE file = CreateFileA("probe.bin", GENERIC_READ, FILE_SHARE_READ, NULL,
                              OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE)
        return 2;
    char byte = 0;
    if (!ReadFile(file, &byte, 1, &wrote, NULL) || wrote != 1 || byte != 'K') {
        CloseHandle(file);
        return 3;
    }
    CloseHandle(file);
    return 0;
}
```

`probe.bin` is the single byte `K`.

`Makefile` builds with `i686-w64-mingw32-gcc -O2 -o console.exe main.c`.

- [ ] **Step 4: Run the test, then run the exe under desktop Wine**

```bash
python -m pytest tests/test_console_guest.py -v
i686-w64-mingw32-gcc -O2 -o demos/windows/console/console.exe demos/windows/console/main.c
cd demos/windows/console && wine console.exe
```

Expected: pytest PASS, Wine prints `eikon-console` and exits 0. Desktop Wine is the oracle. It is not the iOS result.

- [ ] **Step 5: Commit**

```bash
git add demos/windows/console tests/test_console_guest.py
git commit -m "Add the console guest that reads one data byte."
```

### Task 2: Darwin host surface

**Files:**
- Create: `src/host/eikon_host.h`
- Create: `src/host/eikon_host.c`
- Test: `tests/host/test_eikon_host.c`

**Interfaces:**
- Consumes: a directory URL that contains `probe.bin`
- Produces:

```c
int eikon_host_init(const char *root);
int eikon_stdout_write(const void *bytes, size_t len);
int eikon_file_open_read(const char *name, int *out_fd);
int eikon_file_read(int fd, void *buf, size_t len, size_t *out_n);
int eikon_file_close(int fd);
```

Return 0 on success. `eikon_file_open_read` rejects any name that contains `/`, `\\`, or `..`.

- [ ] **Step 1: Write a native test that opens `probe.bin` and reads `K`**

Compile `tests/host/test_eikon_host.c` against `eikon_host.c` with the system compiler. Expected exit code 0.

- [ ] **Step 2: Commit**

```bash
git add src/host tests/host/test_eikon_host.c
git commit -m "Add the file and stdout host used by the console guest."
```

### Task 3: Wine and `libwow64fex.dll`

**Files:**
- Create: `third_party/wine` at tag `wine-11.0`
- Create: `src/host/signal_arm64_darwin.c` (the new ARM64 Darwin CPU layer)
- Create: `src/host/*_darwin.c` (overrides for Wine Unix-side files that do not build for iOS)
- Create: `tools/wine/main.c` (the `eikon-wine` loader)
- Create: `docs/build-wine-ios.md` with the exact commands below
- Create: `plans/wine-ios-gaps.md`

**Interfaces:**
- Consumes: `eikon_host_*`, stage 3's FEXCore patches
- Produces: `libwow64fex.dll`, Wine's i386 and aarch64 PE DLLs, `wineserver` and `eikon-wine` built for iOS, and a Unix-side `ntdll` whose `NtWriteFile` and `NtReadFile` reach `eikon_stdout_write` and `eikon_file_read` for this program

- [ ] **Step 1: Configure Wine**

There are two builds. The PE half is built on Linux with llvm-mingw, matching Autorun's PE configure except that the CPU DLL comes from FEX:

```bash
git submodule add https://github.com/wine-mirror/wine.git third_party/wine
git -C third_party/wine checkout wine-11.0
mkdir -p build/wine-pe && cd build/wine-pe
../../third_party/wine/configure --enable-archs=aarch64,i386 --with-mingw
```

From that build, keep the PE DLLs (`ntdll.dll`, `kernel32.dll`, `kernelbase.dll`, and what they import) for `aarch64` and `i386`. Its Linux Unix side is not shipped.

The Unix half is built on macOS against the iOS SDK. It covers the Unix side of `ntdll`, `wineserver`, and `eikon-wine`. Start from Wine's Darwin sources. Each file that does not compile for iOS gets a `src/host/<name>_darwin.c` override, listed in `plans/wine-ios-gaps.md` with the reason. For this program, `NtWriteFile` on the stdout handle calls `eikon_stdout_write`, and `NtCreateFile` and `NtReadFile` on a relative read-only name call `eikon_file_*`. Every other unimplemented syscall returns `STATUS_NOT_IMPLEMENTED` and logs its name. That log is the list of what to add next.

`eikon-wine` links with `-Wl,-pagezero_size,0x4000` and has the same entitlements as the app. The app starts `wineserver` first, then `eikon-wine console.exe`. The spawned programs read and write under the guest root, `Library/Application Support/Eikon/guest/` (`EikonDataURL()` from stage 2). Both helpers also receive `--jit-method=` from stage 2's result.

- [ ] **Step 2: Build `libwow64fex.dll`**

Build FEX's WoW64 DLL from `third_party/FEX` at `FEX-2609`, with stage 3's FEXCore patches applied, using llvm-mingw and FEX's own toolchain file:

```bash
cmake -S build/fex-patched -B build/fex-wow64 -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE=Data/CMake/toolchain_mingw.cmake \
    -DMINGW_TRIPLE=aarch64-w64-mingw32 \
    -DENABLE_LTO=False -DENABLE_JEMALLOC_GLIBC_ALLOC=False \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build build/fex-wow64 --target wow64fex
```

`build/fex-patched` is `third_party/FEX` copied, with `patches/fex/` applied. Check the target name and the toolchain file path against the tag, and record the exact commands and the llvm-mingw version in `docs/build-wine-ios.md`. FEX's wiki points to bylaws' llvm-mingw builds for these DLLs.

Install the DLL as `system32/libwow64fex.dll` in the prefix, and point Wine's WoW64 layer at it the way FEX's Wine instructions describe. Record the exact registry key.

The DLL asks Wine for code memory through `NtAllocateVirtualMemory` and `NtProtectVirtualMemory`. The Unix side maps those requests with the stage 2 method. If that method is `dualmap`, it must give FEX two addresses for one region. Record how, for example a section mapped twice, in `docs/build-wine-ios.md`.

Expected artifact: `build/fex-wow64/.../libwow64fex.dll`, with the path recorded.

**Wine version.** FEX's wiki says upstream Wine still lacks some pieces for full FEX support, and recommends bylaws' `upstream-arm64ec` Wine branch. Start with `wine-11.0`. If the DLL fails because of something missing in Wine, switch the pin to that branch at a fixed commit, and record the failure and the commit in `docs/build-wine-ios.md`.

- [ ] **Step 3: Device acceptance**

Ship `console.exe` and `probe.bin` in the app bundle, and copy them to the guest root on first run. A button `Run console` starts them through `eikon-wine`. The probe log gains `console=<exit code>` and a copy of stdout containing `eikon-console`.

Expected: `console=0`. A missing syscall is a failure of this stage, and the log line names it. When the i386 gate from stage 2 is closed, the button appends `console=blocked-<reason>` (`low4g`, `jit`, `x18`, or `spawn`) and does not spawn anything.

- [ ] **Step 4: Commit**

```bash
git add src/host tools/wine docs/build-wine-ios.md plans/wine-ios-gaps.md .gitmodules third_party/wine Makefile
git commit -m "Run the console guest through Wine and FEX's WoW64 DLL."
```
