# Stage 5: One window and a tap

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An original i386 program opens one window, fills it, and reports a tap as a left click. Kirikiri, BGI, Ren'Py, and GameMaker all need this before their own drawing does.

**Architecture:** The guest uses GDI only. The Darwin display driver keeps the latest bitmap and the shell draws it in a `CALayer`. A tap converts the view point into client coordinates and posts `WM_LBUTTONDOWN` then `WM_LBUTTONUP`. MoltenVK and DXVK are not in this stage.

**Tech Stack:** Wine `win32u` user driver, UIKit, Core Animation.

## Global Constraints

- The guest is `demos/windows/window`. It is original.
- Software blit only. No Metal shader yet.
- No program titles.
- Stage 4's `console=0` is required before the device acceptance of this stage. If stage 4 logged `console=blocked-<reason>`, this stage stops at its desktop oracle.

---

### Task 1: The guest

**Files:**
- Create: `demos/windows/window/main.c`
- Test: `tests/test_window_guest.py`

**Interfaces:**
- Consumes: stage 4's loader
- Produces: a window titled `EikonWindow`, client size 640 by 480, filled blue (`RGB(0, 0, 255)`). On `WM_LBUTTONDOWN` it writes `click` to a file `click.txt` and exits 0.

- [ ] **Step 1: Write the source test**

```python
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
text = (ROOT / "demos" / "windows" / "window" / "main.c").read_text(encoding="utf-8")

def test_window_contract():
    assert "EikonWindow" in text
    assert "640" in text and "480" in text
    assert "WM_LBUTTONDOWN" in text
    assert "click.txt" in text
```

- [ ] **Step 2: Implement `main.c`**

Register a class. Size the window with `AdjustWindowRectEx` so the client area is 640 by 480, then `CreateWindowExW` and `ShowWindow`. Fill the client with a solid blue brush in `WM_PAINT`. On `WM_LBUTTONDOWN`, open `click.txt` with `CreateFileA(..., GENERIC_WRITE, ..., CREATE_ALWAYS, ...)`, write the five bytes `click` with `WriteFile`, close the file, then `PostQuitMessage(0)`.

Build with `i686-w64-mingw32-gcc -mwindows -o window.exe main.c`. Confirm under desktop Wine that a click produces `click.txt`.

- [ ] **Step 3: Commit**

```bash
git add demos/windows/window tests/test_window_guest.py
git commit -m "Add the GDI window guest."
```

### Task 2: Bitmap handoff

**Files:**
- Create: `src/host/eikon_window.h`
- Create: `src/host/eikon_window.c`
- Create: `src/host/EikonWindowView.m`
- Create: `src/host/win32u_darwin.c`
- Modify: `src/host/eikon_host.h`, `src/host/eikon_host.c`
- Test: `tests/host/test_eikon_window.c`

**Interfaces:**
- Consumes: stage 4 host
- Produces:

```c
void eikon_window_present(const uint8_t *bgra, int width, int height, int stride);
void eikon_window_set_click_handler(void (*fn)(int x, int y, int down));
int eikon_window_copy(uint8_t *bgra, int width, int height, int stride); // test getter

// Added to stage 4's host. Stage 4 only opened files for reading.
int eikon_file_open_write(const char *name, int *out_fd); // create or truncate
int eikon_file_write(int fd, const void *bytes, size_t len, size_t *out_n);
```

`eikon_file_open_write` uses the same name rule as `eikon_file_open_read`: it rejects `/`, `\\`, and `..`. `NtCreateFile` with write access and `NtWriteFile` on a file handle route to these two functions.

The guest runs in `eikon-wine`, a separate process, and the view lives in the app. `eikon_window_present` therefore writes into a shared-memory buffer (`shm_open` plus `mmap`) that the app maps. Taps go back to the guest over a pipe. Record the channel in `docs/build-wine-ios.md`.

`EikonWindowView` retains the latest BGRA buffer and draws it scaled to the view, letterboxed. A tap calls the handler with view coordinates mapped back into the 640 by 480 client.

- [ ] **Step 1: Host test**

`tests/host/test_eikon_window.c` calls `eikon_window_present` with a 2 by 2 blue buffer and reads it back through `eikon_window_copy`. Expected first pixel bytes `0xFF, 0x00, 0x00, 0xFF` in BGRA. The same test opens `click.txt` for writing in a temporary root, writes `click`, and reads the five bytes back.

- [ ] **Step 2: Wire `NtUser` present**

`src/host/win32u_darwin.c` implements the present call the guest hits from `BitBlt` of the window backing store. Other user calls log `STATUS_NOT_IMPLEMENTED` plus the function name, same rule as stage 4.

- [ ] **Step 3: Device acceptance**

Button `Run window`. The view turns blue. A tap writes `click.txt` inside the guest root. Probe log gains `window=0`.

- [ ] **Step 4: Commit**

```bash
git add src/host tests/host/test_eikon_window.c demos/windows/window Makefile
git commit -m "Present a GDI window and deliver a tap as a click."
```
