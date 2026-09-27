# Stage 9: Signal Drift under FEX

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The original Linux sketch Signal Drift runs under FEX for more than one frame and the process exits 0. This happens on a Linux machine. The iOS app does not link FEX in this stage.

**Architecture:** Submodule `third_party/FEX` at tag `FEX-2609`. The guest is `demos/linux`, built as a native x86-64 ELF, then run with FEX's normal ARM64 JIT on Linux. The earlier simulator run matched one frame and aborted on exit. This stage uses the JIT build, which is the build that can load a dynamic ELF. Wine is not involved.

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
- Produces: an x86-64 ELF that prints `frame 1` and `frame 2` and returns 0

- [ ] **Step 1: Write the program**

```c
#include <stdio.h>

int main(void) {
    puts("frame 1");
    puts("frame 2");
    return 0;
}
```

`Makefile` uses `x86_64-linux-gnu-gcc -O2 -o signal-drift signal-drift.c`.

- [ ] **Step 2: Test the source**

```python
from pathlib import Path
text = Path("demos/linux/signal-drift.c").read_text(encoding="utf-8")

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
cmake -S third_party/FEX -B build/fex -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build build/fex -j4 --target FEXInterpreter
```

Write those commands into `docs/build-fex.md` once they succeed. If the configure line needs an extra flag to turn the interpreter off, add that flag to the doc after the build log shows it. The acceptance run uses `FEXInterpreter`, which JITs.

- [ ] **Step 2: Run**

```bash
build/fex/Bin/FEXInterpreter demos/linux/signal-drift ; echo $?
```

Expected stdout:

```
frame 1
frame 2
```

Expected exit code: `0`

A non-zero exit is the stage failing, including an abort during process teardown. The log of that abort is appended to `docs/build-fex.md`.

- [ ] **Step 3: Commit**

```bash
git add .gitmodules third_party/FEX docs/build-fex.md
git commit -m "Run Signal Drift under FEX and require a clean exit."
```
