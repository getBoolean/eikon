# 04 · Input layer

## Purpose

One input layer that every route uses. It turns touch, hardware keyboards, and game controllers into what games expect from a mouse and keyboard, and supports text entry, including Japanese composition.

## Read first

- `planning/requirements.md`: "Input", "Games to support" (visual novels first, Unity later).
- `planning/deep_project_interview.md`.
- `planning/02-app-shell/spec.md` (session host, settings) and `planning/03-native-kirikiri/spec.md` (first consumer).

## Scope

**In:**
- Route-neutral events: pointer move, buttons, wheel, keys (with enough information to map to Windows virtual keys and scancodes, and to Linux/SDL key codes), and text and composition events.
- Mapping touch coordinates from the host view to game coordinates, including letterboxing and scaling.
- Touch schemes: tap to click, a gesture for right-click, drag, scroll, and hover where the game needs it. An on-screen overlay for common keys (Enter, Esc, Ctrl to skip, arrows, and so on). Per-game layouts stored in 02's settings.
- Hardware keyboards (UIKit presses and key commands), including modifiers and keys iOS reserves by default.
- Game controllers (GameController framework), mapped to keys or mouse per game, with presets for visual novels.
- Text entry: bring up the system keyboard on demand, and support Japanese IME composition (marked text), delivering both composition and committed text so the route can pass them on (for Wine, as IME messages).
- Adapters: replace 03's minimal touch in native Kirikiri. Define the contract the Wine driver (08), Ren'Py (10), and Linux (13) consume.

**Out:** the per-route plumbing inside Wine, Ren'Py, or Linux (their splits), and translation overlay input (11).

## Needs

- 02 (session host, settings), and 03 as the first real consumer.

## Provides

- The input contract and the touch, keyboard, and controller UI (08, 10, 13, 14).

## Done when

- On a device, native Kirikiri takes touch, a hardware keyboard, a controller, and Japanese text entry through this layer.
- The per-game layout is saved and restored.
- The contract is documented with a test harness that records the events a route would receive.
