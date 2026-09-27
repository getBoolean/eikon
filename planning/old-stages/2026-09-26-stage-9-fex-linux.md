# Stage 9: Signal Drift under FEX

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The original Linux sketch Signal Drift runs under FEX for more than one frame and the process exits 0. This happens on a Linux machine. The iOS app does not link FEX in this stage.

**Architecture:** Submodule `third_party/FEX` at tag `FEX-2609`. The guest is `demos/linux`, built as an x86-64 ELF, then run with FEX's normal ARM64 JIT on Linux. The binary is named `FEXInterpreter`, but it is the JIT. The earlier simulator run matched one frame and aborted on exit. Wine is not involved.

The guest is built twice. The static build needs nothing from the host and is the acceptance run. The dynamic build needs an x86-64 root filesystem, set up with `FEXRootFSFetcher`. It is the check that the dynamic-ELF abort from the simulator run is gone.

**Tech Stack:** FEX-Emu `FEX-2609`, CMake, a Linux ARM64 host.

## Global Constraints

- Do not run this guest under Box64, QEMU, or v86.
- Do not put FEX into the iOS app in this stage.
- Signal Drift is original. If `demos/linux` is absent, task 1 writes a two-frame stand-in with the same exit check, named Signal Drift, rather than fetching a commercial program.
- No JIT bypass. The host is Linux, where FEX's own code cache is allowed.
- No program titles besides Signal Drift, which is the sketch already named in the handoff.

---

### Task 1: A two-frame guest

**Files:**
- Create: `demos/linux/signal-drift.c`
- Create: `demos/linux/Makefile`
- Test: `tests/test_signal_drift.py`

**Interfaces:**
- Consumes: nothing
- Produces: two x86-64 ELFs, `signal-drift-static` and `signal-drift`, that print `frame 1` and `frame 2` and return 0

- [ ] **Step 1: Write the program**

```c
#include <stdio.h>

int main(void) {
    puts("frame 1");
    puts("frame 2");
    return 0;
}
```

`Makefile` builds both:

```make
all: signal-drift signal-drift-static
signal-drift: signal-drift.c
	x86_64-linux-gnu-gcc -O2 -o $@ $<
signal-drift-static: signal-drift.c
	x86_64-linux-gnu-gcc -O2 -static -o $@ $<
```

- [ ] **Step 2: Test the source**

```python
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
text = (ROOT / "demos" / "linux" / "signal-drift.c").read_text(encoding="utf-8")

def test_two_frames():
    assert 'puts("frame 1")' in text
    assert 'puts("frame 2")' in text
    assert "return 0" in text
```

Run: `python -m pytest tests/test_signal_drift.py -v`

Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add demos/linux tests/test_signal_drift.py
git commit -m "Add a two-frame Signal Drift stand-in."
```

### Task 2: Run it under FEX

**Files:**
- Create: `third_party/FEX` at tag `FEX-2609`
- Create: `docs/build-fex.md`

**Interfaces:**
- Consumes: the ELF from task 1
- Produces: stdout containing both frame lines and exit code 0

- [ ] **Step 1: Build FEX's JIT, not the simulator**

```bash
git submodule add https://github.com/FEX-Emu/FEX third_party/FEX
git -C third_party/FEX checkout FEX-2609
git -C third_party/FEX submodule update --init --recursive
cmake -S third_party/FEX -B build/fex -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++
cmake --build build/fex --target FEXInterpreter FEXRootFSFetcher
```

FEX builds with clang. Write the commands into `docs/build-fex.md` once they succeed, along with any flag the build log shows was needed. Do not configure the simulator build used earlier.

- [ ] **Step 2: Run**

```bash
build/fex/Bin/FEXInterpreter demos/linux/signal-drift-static ; echo $?
```

Expected stdout:

```
frame 1
frame 2
```

Expected exit code: `0`

A non-zero exit is the stage failing, including an abort during process teardown. The log of that abort is appended to `docs/build-fex.md`.

Then run the dynamic build against a root filesystem:

```bash
build/fex/Bin/FEXRootFSFetcher
build/fex/Bin/FEXInterpreter demos/linux/signal-drift ; echo $?
```

Expected: the same two lines and `0`. Record the root filesystem image name in `docs/build-fex.md`.

- [ ] **Step 3: Commit**

```bash
git add .gitmodules third_party/FEX docs/build-fex.md
git commit -m "Run Signal Drift under FEX and require a clean exit."
```
