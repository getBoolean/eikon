# 14 · No-JIT build: Box64 interpreter and signed Wine

## Purpose

Make the AltStore `.ipa` run 32-bit Windows games without JIT. Box64's interpreter runs as the WoW64 CPU DLL inside Wine, and Wine's own code and Box64's DLL are delivered as signed Mach-O, which AltStore signs with the rest of the app at install. The route is slow, and meant for 2D visual novels. The owner sequenced it late.

## Read first

- `planning/requirements.md`: Goal 4. "Builds and JIT" (the no-JIT build), "Constraints" (the install-method table, the guest window, hardware facts: iOS runs only signed code without JIT), "Decisions" (Box64 only here, only its interpreter, no pre-translated route), "Known risks" (interpreter speed, signed Mach-O Wine, Box64's low-4 GB assumption).
- `planning/deep_project_interview.md`.
- `planning/07-wine-wow64-guest-window/spec.md` (guest-window contract) and `planning/08-wine-media/spec.md`.

## Scope

**In:**
- Box64 as a submodule at a tag, with changes as patch files. Build its WoW64 DLL with the interpreter only (no dynarec in the default path).
- **Guest window in Box64:** the interpreter adds B to every 32-bit memory access, meeting 07's contract. Box64's 32-bit support assumes the low 4 GB today.
- **Signed Mach-O Wine:** Wine's ARM64 PE DLLs normally load as PE files mapped executable, which needs JIT. Build Wine's modules and Box64's DLL as Mach-O images that the loader links in or maps as signed code, while keeping the PE semantics Wine needs (exports, relocations, TLS, and the loader's module list). Neither project does this today. This is the core research item. Include how 06's x18 patching works when modules are signed and can't be patched.
- **Graphics layers:** 32-bit graphics layers built for i386 would be interpreted and very slow. Prefer ARM64-native layers with WoW64 thunks (coordinate with 08's decision).
- **Optional JIT:** if an enabler (such as StikDebug) gave the process JIT, the no-JIT build may use it (loading Wine normally, and possibly Box64's dynarec). It never requires JIT.
- The route picker and capability screen: 64-bit Windows games (including Unity) and Linux games show "needs the main build" with the reason.
- Signing: confirm every Mach-O in the `.ipa` is signed by AltStore at install, and that the dylib count and size fit AltStore's limits.

**Out:** 64-bit Windows (Box64 has no ARM64EC DLL), Linux games, and FEX in this build.

## Needs

- 07 (the guest-window contract and WoW64 layer), 08 (display, audio, input under Wine), 06 (Wine build and in-process design), 01 (the no-JIT flavor and `.ipa`).

## Done when

- The AltStore-signed `.ipa` runs, without JIT, an original i386 Windows test program that draws a window, plays a sound, and takes input.
- A real 2D visual novel from the mount has been tried, with its speed recorded by engine and hash.
