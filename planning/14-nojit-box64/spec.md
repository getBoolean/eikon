# 14 · No-JIT route: Box64 interpreter and signed Wine

## Purpose

Let Eikon run 32-bit Windows games when the process has no usable JIT: always on the AltStore `.ipa` without an enabler, and on the deb or `.tipa` when JIT is missing. There is one build (decided 2026-09-27), so this route ships in every package and is chosen at run time. Box64's interpreter runs as the WoW64 CPU DLL inside Wine, and Wine's own code and Box64's DLL are delivered as signed Mach-O, signed with the rest of the app. The route is slow, and meant for 2D visual novels. The owner sequenced it late.

## Read first

- `planning/requirements.md`: Goal 4. "Builds and JIT" (one build, the no-JIT route), "Constraints" (the install-method table, the guest window, hardware facts: iOS runs only signed code without JIT), "Decisions" (Box64 only without usable JIT, only its interpreter, no pre-translated route), "Known risks" (interpreter speed, signed Mach-O Wine, Box64's low-4 GB assumption).
- `planning/deep_project_interview.md`.
- `planning/07-wine-wow64-guest-window/spec.md` (guest-window contract) and `planning/08-wine-media/spec.md`.

## Scope

**In:**
- Box64 as a fork starting from a tag, with changes as commits on the fork's `eikon` branch. The fork publishes its builds as GitHub releases, and Eikon pins them in `third_party/deps.toml`. Build its WoW64 DLL with the interpreter only (no dynarec in the default path).
- **Guest window in Box64:** the interpreter adds B to every 32-bit memory access, meeting 07's contract. Box64's 32-bit support assumes the low 4 GB today.
- **Signed Mach-O Wine:** Wine's ARM64 PE DLLs normally load as PE files mapped executable, which needs JIT. Build Wine's modules and Box64's DLL as Mach-O images that the loader links in or maps as signed code, while keeping the PE semantics Wine needs (exports, relocations, TLS, and the loader's module list). Neither project does this today. This is the core research item. Include how 06's x18 patching works when modules are signed and can't be patched.
- **Graphics layers:** 32-bit graphics layers built for i386 would be interpreted and very slow. Prefer ARM64-native layers with WoW64 thunks (coordinate with 08's decision).
- **Route choice:** the route picker (02) selects this route from 01's JIT API when the process has no usable JIT. With usable JIT, FEX (06, 07) is used instead. Box64's dynarec is not used.
- The route picker and capability screen: 64-bit Windows games (including Unity) and Linux games show "needs JIT" with the reason, and the install-method-specific way to get it.
- Signing: confirm every Mach-O is signed in each package (ldid for the deb, TrollStore for the `.tipa`, AltStore at install for the `.ipa`), and that the dylib count and total size fit AltStore's limits. Record the size the route adds to every package.

**Out:** 64-bit Windows (Box64 has no ARM64EC DLL) and Linux games on this route. Both need JIT.

## Needs

- 07 (the guest-window contract and WoW64 layer), 08 (display, audio, input under Wine), 06 (Wine build and in-process design), 01 (the JIT detection API and the three packages).

## Done when

- The AltStore-signed `.ipa` runs, without JIT (and the deb or `.tipa` with JIT turned off), an original i386 Windows test program that draws a window, plays a sound, and takes input.
- A real 2D visual novel from the mount has been tried, with its speed recorded by engine and hash.
