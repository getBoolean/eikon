# Stage 8: Unity class, one Direct3D 11 frame

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An original amd64 program presents one Direct3D 11 frame. That is the graphics class for Unity (`UnityPlayer.dll`, and `GameAssembly.dll` when the player is IL2CPP). Ren'Py and GameMaker get tried only after this frame works, because their Windows builds sit on the same process, window, and file stages.

**Architecture:** `d3d11.dll` and `dxgi.dll` on the surface from stage 6. The CPU path is stage 7. This stage does not ship a Unity player and does not implement IL2CPP.

DXVK's D3D11 path needs Vulkan features that MoltenVK lacks, such as geometry shaders and transform feedback, more strictly than D3D9 does. Task 2 runs stage 6's feature check for D3D11 first. If DXVK cannot run on MoltenVK, use DXMT, a Direct3D 11 implementation for Wine that draws with Metal directly. It fits "drawing goes through Metal" in `stages.md` and skips MoltenVK for this path. Record the choice in `docs/build-dxvk.md`.

**Tech Stack:** DXVK D3D11 on MoltenVK, or DXMT on Metal; Wine ARM64EC; FEX `libarm64ecfex.dll`.

## Global Constraints

- Guest is `demos/windows/d3d11`. Original.
- Stage 7 logged `amd64=42` before the device claim. Stage 6's surface code (Task 2) must exist. Stage 6's `present=0` device run is required only when stage 2's i386 gate is open; this guest is amd64 and does not depend on it.
- No program titles. No Unity editor, no IL2CPP compiler.
- No JIT bypass.

---

### Task 1: The guest

**Files:**
- Create: `demos/windows/d3d11/main.c`
- Test: `tests/test_d3d11_guest.py`

**Interfaces:**
- Consumes: stages 5, 6, and 7
- Produces: a swap chain on a window made the same way as stage 5's (built here as amd64), cleared to red (`{1.0f, 0.0f, 0.0f, 1.0f}`), one `Present`, then `presented` written to `d3d11.txt` and exit 0

- [ ] **Step 1: Write the failing test**

```python
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def test_d3d11_contract():
    text = (ROOT / "demos" / "windows" / "d3d11" / "main.c").read_text(encoding="utf-8")
    assert "D3D11CreateDeviceAndSwapChain" in text
    assert "DXGI_FORMAT_B8G8R8A8_UNORM" in text
    assert "ClearRenderTargetView" in text
    assert "d3d11.txt" in text
```

Run: `python -m pytest tests/test_d3d11_guest.py -v`

Expected: FAIL

- [ ] **Step 2: Write `main.c`**

Use `D3D11CreateDeviceAndSwapChain` with `D3D_DRIVER_TYPE_HARDWARE` and `DXGI_FORMAT_B8G8R8A8_UNORM`. Get the back buffer, create a render target view, and `ClearRenderTargetView` it to `{1.0f, 0.0f, 0.0f, 1.0f}`. Present with sync interval 1. Write the file only after `Present` returns `S_OK`.

Run: `python -m pytest tests/test_d3d11_guest.py -v`

Expected: PASS

Build with `x86_64-w64-mingw32-gcc` and link `d3d11` and `dxgi`.

Oracle: desktop Wine plus DXVK. Expected file contents `presented`.

- [ ] **Step 3: Commit**

```bash
git add demos/windows/d3d11 tests/test_d3d11_guest.py
git commit -m "Add the Direct3D 11 present guest."
```

### Task 2: Device frame

**Files:**
- Modify: `docs/build-dxvk.md`
- Modify: `src/host/eikon_vulkan.m` only if the amd64 surface path differs

**Interfaces:**
- Consumes: `eikon_metal_layer` from stage 6
- Produces: probe log `d3d11=0` and a red view

- [ ] **Step 1: Choose and build the amd64 D3D11 layer**

Run the stage 6 feature check against DXVK's D3D11 requirements. Build amd64 DXVK, or DXMT if DXVK is ruled out. Append the project, the exact tag, the reason for the choice, and the output names `d3d11.dll` and `dxgi.dll` to `docs/build-dxvk.md`. Copy both DLLs beside `d3d11.exe`.

- [ ] **Step 2: Device acceptance**

Button `Run d3d11`. The view is red. `d3d11.txt` contains `presented`. Log line `d3d11=0`.

Ren'Py and GameMaker are not launched in this stage. The next experiment after `d3d11=0`, outside this plan, is one of those engines' own Windows build, still without recording a title.

- [ ] **Step 3: Commit**

```bash
git add docs/build-dxvk.md Makefile
git commit -m "Present one Direct3D 11 frame on the MoltenVK surface."
```
