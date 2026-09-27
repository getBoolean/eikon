# 08 · Wine media: windows, Metal graphics, audio, video

## Purpose

Give Windows games under Wine a screen, sound, and video on iOS. This includes a Wine display driver for the app's game view, Direct3D through Metal, audio, and video playback. It also covers the app-level limits: backgrounding and memory. Once it's done, Kirikiri/BGI-class (32-bit, 2D, Direct3D 9 or GDI) and Unity-class (64-bit, Direct3D 11) games can be tried.

## Read first

- `planning/requirements.md`: "Running Windows games", "Games to support" (Unity needs amd64 and Direct3D 11), "Prior art" (Proton builds graphics layers as ARM64EC; Madeira uses DXMT and found DXVK blocked by MoltenVK's missing geometry shaders), "Operational requirements" (memory limits, backgrounding), "Known risks" (MoltenVK gaps).
- `planning/deep_project_interview.md`.
- `planning/06-wine-core/spec.md`, `planning/07-wine-wow64-guest-window/spec.md`, `planning/04-input/spec.md`.

## Scope

**In:**
- **A Wine display driver for iOS** (the host layer is new). Top-level windows are presented in 02's session host view, with window-to-view mapping, mode changes, fullscreen, and the cursor. Input from 04 feeds Wine's message queue, including IME messages for composition text.
- **GDI and DirectDraw software path first:** blit a window's pixels to the screen through Metal. Many 2D visual novels need only this.
- **Direct3D 11 through DXMT** on Metal. Port DXMT's macOS Unix side to iOS. For 64-bit games, build the graphics layer as ARM64EC so it runs native, following Proton.
- **Direct3D 9:** **open decision** for /deep-plan. Options include DXVK on MoltenVK (D3D9 rarely needs geometry shaders), a DXMT-based path, or another route. 32-bit games' graphics layers, which are i386 in Proton, run translated. Evaluate an aarch64-native layer with WoW64 thunks instead, since 14 would otherwise interpret them.
- GPU memory that a 32-bit game maps lands inside its guest window (07's contract).
- **Audio:** a Wine audio driver on AVAudioSession/CoreAudio (like winecoreaudio), plus DirectSound, XAudio2, and waveOut. Handle interruptions and route changes.
- **Video:** the playback paths the target engines use (DirectShow and Media Foundation). **Open decision:** how to decode on iOS (a GStreamer build, or a native AVFoundation bridge).
- **Backgrounding:** on resign-active, pause the game and stop all Metal work before the app enters the background. Resume cleanly.
- **Memory:** survive jetsam limits. Unity needs gigabytes. Evaluate raised-memory-limit entitlements for each install method (with 01), and report memory pressure to the user.
- Ship Wine Mono's ARM64 build (Unity uses its own runtime, but some games and tools need .NET).

**Out:** text encoding and fonts (09), the text capture hooks (11), and the no-JIT build (14).

## Needs

- 07 (i386 guests and the window contract), 06 (Wine, and 64-bit guests for Direct3D 11), 04 (input), and 02 (session host).

## Provides

- A graphics, audio, and input path for every Windows game (09, 11, 14). Save locations in the prefix are discovered here for 12.

## Done when

- Original test programs run on a device: a 32-bit GDI/Direct3D 9 program draws and plays a sound, a 64-bit Direct3D 11 program draws a frame, and a video test plays.
- Going to the background and returning doesn't crash.
- A real Kirikiri-class and a Unity-class game have been tried from the mount, with results recorded by engine and hash only.
