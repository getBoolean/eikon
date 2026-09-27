# Stage 8: Unity class, one Direct3D 11 frame

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An original amd64 program presents one Direct3D 11 frame. That is the graphics class for Unity (`UnityPlayer.dll`, and `GameAssembly.dll` when the player is IL2CPP). Ren'Py and GameMaker get tried only after this frame works, because their Windows builds sit on the same process, window, and file stages.

**Architecture:** DXVK's `d3d11.dll` and `dxgi.dll` on the MoltenVK surface from stage 6. The CPU path is stage 7. This stage does not ship a Unity player and does not implement IL2CPP.

**Tech Stack:** DXVK D3D11, MoltenVK, Wine amd64, Box64.

## Global Constraints

- Guest is `demos/windows/d3d11`. Original.
- Stage 7 logged `amd64=42` and stage 6 logged `present=0` before the device claim.
- No program titles. No Unity editor, no IL2CPP compiler.
- No JIT bypass.

---

### Task 1: The guest

**Files:**
- Create: `demos/windows/d3d11/main.c`
- Test: `tests/test_d3d11_guest.py`

**Interfaces:**
- Consumes: stages 5, 6, and 7
- Produces: a swap chain on the stage 5 window, cleared to red `0x00FF0000`, one `Present`, then `presented` written to `d3d11.txt` and exit 0

- [ ] **Step 1: Write `main.c`**

Use `D3D11CreateDeviceAndSwapChain` with `D3D_DRIVER_TYPE_HARDWARE` and `DXGI_FORMAT_B8G8R8A8_UNORM`. Clear the render target. Present with sync interval 1. Write the file only after `Present` returns `S_OK`.

Build with `x86_64-w64-mingw32-gcc` and link `d3d11` and `dxgi`.

Oracle: desktop Wine plus DXVK. Expected file contents `presented`.

- [ ] **Step 2: Commit**

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

- [ ] **Step 1: Build amd64 DXVK**

Append the exact tag and the output names `d3d11.dll` and `dxgi.dll` to `docs/build-dxvk.md`. Copy both beside `d3d11.exe`.

- [ ] **Step 2: Device acceptance**

Button `Run d3d11`. The view is red. `d3d11.txt` contains `presented`. Log line `d3d11=0`.

Ren'Py and GameMaker are not launched in this stage. The next experiment after `d3d11=0`, outside this plan, is one of those engines' own Windows build, still without recording a title.

- [ ] **Step 3: Commit**

```bash
git add docs/build-dxvk.md Makefile
git commit -m "Present one Direct3D 11 frame on the MoltenVK surface."
```
