# Stage 4: A 32-bit Windows program reads a file

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An original i386 Windows program prints `eikon-console` and reads the first byte of a data file. That is the file and console surface Kirikiri and BGI need before they need a window.

**Architecture:** Wine is built as native ARM64 with an i386 PE guest. Box64's `wowbox64.dll` (`-DWOW64=ON` at tag `v0.3.6`) is the CPU DLL. The unix side is a Darwin host written in this repo, large enough for this one program: standard output and one read-only file. No window, no audio, no Direct3D.

**Tech Stack:** Wine 11.0 configured for `aarch64` and `i386`, Box64 WowBox64, mingw-w64 `i686`, Theos.

## Global Constraints

- Wine submodule `third_party/wine` at tag `wine-11.0`.
- Do not run Wine under FEX or under Box64. Box64 translates the guest PE only.
- The guest program in this stage is original and lives in `demos/windows/console`.
- No program titles from outside this repo.
- No JIT bypass. If stage 3 logged `add42=unsupported`, this stage does not claim a device run.

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
    assert "== 'K'" in text
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

### Task 3: Wine and wowbox64

**Files:**
- Create: `third_party/wine` at tag `wine-11.0`
- Create: `docs/build-wine-ios.md` with the exact commands below

**Interfaces:**
- Consumes: `eikon_host_*`, Box64 `v0.3.6`
- Produces: `wowbox64.dll` and an iOS-linked `ntdll` whose `WriteFile` and `ReadFile` call `eikon_stdout_write` and `eikon_file_read`

- [ ] **Step 1: Configure Wine**

On Linux, matching Autorun's PE configure except the CPU DLL comes from Box64:

```bash
git submodule add https://github.com/wine-mirror/wine.git third_party/wine
git -C third_party/wine checkout wine-11.0
mkdir -p build/wine-pe && cd build/wine-pe
../../third_party/wine/configure --enable-archs=aarch64,i386 --with-mingw
```

Build `dlls/ntdll` and the i386 `kernel32`. The unix half of `ntdll` is replaced by `src/host/ntdll_darwin.c`, which implements `NtWriteFile` for the stdout handle and `NtReadFile` / `NtCreateFile` for a relative read-only name. Every other syscall returns `STATUS_NOT_IMPLEMENTED` and logs the name. That log is the list for the next function to add. Do not copy Autorun's `horizon*.c`.

- [ ] **Step 2: Build wowbox64**

```bash
cmake -S third_party/box64 -B build/box64-wow64 -DWOW64=ON -DARM_DYNAREC=ON -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build build/box64-wow64 -j4
```

Expected artifact: `build/box64-wow64/wowbox64-prefix/src/wowbox64-build/wowbox64.dll`

- [ ] **Step 3: Device acceptance**

Ship `console.exe` and `probe.bin` in the app bundle. A button `Run console` runs them. The probe log gains `console=0` and a copy of stdout containing `eikon-console`.

Expected: `console=0`. A missing syscall is a failure of this stage, and the log line names it.

- [ ] **Step 4: Commit**

```bash
git add src/host/ntdll_darwin.c docs/build-wine-ios.md .gitmodules third_party/wine Makefile
git commit -m "Run the console guest through Wine and wowbox64."
```
