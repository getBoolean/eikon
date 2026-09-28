diff --git a/.github/workflows/release.yml b/.github/workflows/release.yml
index c946dfc..33523bf 100644
--- a/.github/workflows/release.yml
+++ b/.github/workflows/release.yml
@@ -70,12 +70,12 @@ jobs:
           notes=$(cat <<'EOF'
           Eikon ${{ github.ref_name }} — an early prototype that reports whether JIT is usable and shows device status. It does not run anything yet.
 
-          Install: the deb is for Dopamine (rootless); the .tipa is for TrollStore and needs Developer Mode on iOS 16+; the .ipa is for AltStore. Each carries the same binary, signed with its own entitlements.
+          Install: the deb is for Dopamine (rootless); the .ipa is for AltStore, and also installs to TrollStore (needs Developer Mode on iOS 16+). Each carries the same binary, signed with its own entitlements.
           EOF
           )
           # Fails if a release for this tag already exists. Assets are never replaced.
           gh release create "$TAG" --repo "$GITHUB_REPOSITORY" --title "$TAG" --notes "$notes" \
-            dist/Eikon-*.ipa dist/Eikon-*.tipa dist/*.deb dist/SHA256SUMS
+            dist/Eikon-*.ipa dist/*.deb dist/SHA256SUMS
 
   publish:
     needs: release
@@ -117,7 +117,7 @@ jobs:
           TAG: ${{ github.ref_name }}
         run: |
           version=$(tr -d '[:space:]' < eikon/VERSION)
-          deb="com.getboolean.eikon_${version}_iphoneos-arm64.deb"
+          deb="com.getboolean.eikon.rootless_${version}_iphoneos-arm64.deb"
           base="https://github.com/${GITHUB_REPOSITORY}/releases/download/${TAG}"
           url="$base/$deb"
           mkdir -p work
diff --git a/Makefile b/Makefile
index b4021dd..5e22ff4 100644
--- a/Makefile
+++ b/Makefile
@@ -8,12 +8,12 @@ SHELL := /bin/bash
 stub = echo "$@: not implemented yet (section $(1))" >&2; exit 1
 
 .PHONY: help doctor bootstrap version generated project check \
-	test test-swift test-scripts archive ipa tipa deb package verify all \
+	test test-swift test-scripts archive ipa deb package verify all \
 	publish fetch-deps verify-deps pin-dep clean
 
 help:
 	@echo "Targets: doctor bootstrap version generated project check test test-swift"
-	@echo "         test-scripts archive ipa tipa deb package verify all publish"
+	@echo "         test-scripts archive ipa deb package verify all publish"
 	@echo "         fetch-deps verify-deps pin-dep NAME=<name> TAG=<tag> [ASSET=<asset>] clean"
 
 doctor:
@@ -52,14 +52,14 @@ test-scripts:
 archive:
 	@scripts/archive.sh
 
-ipa tipa deb: archive
+ipa deb: archive
 	@scripts/package.sh $@
 
 # Clear dist/ first so only this build is packaged, summed and verified.
 package: archive
 	@rm -rf dist
-	@$(MAKE) ipa tipa deb
-	@cd dist && shasum -a 256 Eikon-*.ipa Eikon-*.tipa *.deb > SHA256SUMS
+	@$(MAKE) ipa deb
+	@cd dist && shasum -a 256 Eikon-*.ipa *.deb > SHA256SUMS
 	@echo "package: wrote dist/SHA256SUMS"
 
 verify:
diff --git a/README.md b/README.md
index a283b4c..b956649 100644
--- a/README.md
+++ b/README.md
@@ -74,11 +74,13 @@ process handle SIGBUS SIGSEGV SIGILL SIGTRAP -s false -n false
 
 ## Install methods and artifacts
 
-- **Dopamine rootless deb** (`com.getboolean.eikon`, `iphoneos-arm64`), installed at `/var/jb/Applications/Eikon.app`. Supported on Dopamine 2, for iOS 15.0–16.6.1.
-- **`Eikon.tipa`** for TrollStore, up to iOS 17.0. On iOS 16 and later, **Developer Mode must be on**: the `.tipa` carries `get-task-allow`, which TrollStore's enable-JIT feature needs.
-- **`Eikon.ipa`** for AltStore, on current iOS. AltStore re-signs it with the developer profile's entitlements, replacing the ones in the ipa.
+- **Dopamine rootless deb** (`com.getboolean.eikon.rootless`, `iphoneos-arm64`), installed at `/var/jb/Applications/Eikon.app`. Supported on Dopamine 2, for iOS 15.0–16.6.1. Needs no Developer Mode.
+- **`Eikon.ipa`** (`com.getboolean.eikon`) for **AltStore or TrollStore**:
+  - With **AltStore**: it re-signs the ipa with the developer profile's entitlements, replacing the ones in the ipa, and may rewrite the bundle id.
+  - With **TrollStore**: it installs the ipa as-is, keeping its entitlements. "Open with JIT" or the enable-JIT feature grants JIT.
+  - On iOS 16 and later, **Developer Mode must be on**: the ipa carries `get-task-allow`.
 
-The deb needs no Developer Mode. Each artifact carries the same binary, signed with its own entitlements (`packaging/entitlements/`); `make verify` checks that.
+The deb and the ipa use **different bundle ids** so a Dopamine install and a TrollStore-installed ipa can coexist. Both carry the same binary, signed with their own entitlements (`packaging/entitlements/`); `make verify` checks that.
 
 ## JIT
 
diff --git a/VERSION b/VERSION
index 6e8bf73..0ea3a94 100644
--- a/VERSION
+++ b/VERSION
@@ -1 +1 @@
-0.1.0
+0.2.0
diff --git a/device-reports/README.md b/device-reports/README.md
index 5012c2c..188b0f5 100644
--- a/device-reports/README.md
+++ b/device-reports/README.md
@@ -12,17 +12,19 @@ filing must follow the same rule: no program titles, nothing device-identifying.
 The artifacts used below come from the **GitHub Release**, not local builds, so the
 reports describe what users actually install. `<v>` is the released version.
 
+**One method at a time.** The Dopamine deb (`com.getboolean.eikon.rootless`) and the ipa (`com.getboolean.eikon`) have different bundle ids and can coexist. A TrollStore-installed ipa and an AltStore-installed ipa share the id `com.getboolean.eikon`, so installing one shadows the other — uninstall (and reboot or `uicache`) before switching between them.
+
 ## iPad Pro 12.9" 6th gen (M2), iPadOS 17.0
 
-### TrollStore
-1. With Developer Mode on, install `Eikon-<v>.tipa` and launch it.
-2. Expect TrollStore to open and return, then the status screen to show **usable**, source `trollStore`.
-3. File the report.
-4. Disable TrollStore's URL scheme, then relaunch after the cooldown. Expect **not usable**, reason `trollStoreTimedOut`. Re-enable the scheme, press **Retry JIT**, and expect usable again.
-5. Turn Developer Mode off and try to launch. Record in the report notes what happens: a TrollStore install warning, a launch refusal, or a launch without JIT.
+### TrollStore (the `.ipa`, not a separate tipa)
+1. With Developer Mode on, install `Eikon-<v>.ipa` **with TrollStore** and launch it.
+2. Record the **Detected method** and **Bundle ID** on the status screen. We expect `trollStore`; the report confirms what markers TrollStore leaves for an ipa install.
+3. Use TrollStore's **"Open with JIT"** (or the enable-JIT flow) and relaunch. Expect **usable**. File the report.
+4. Launch normally (without Open with JIT). If it's not usable, note the reason; press **Retry JIT** and see whether TrollStore's enable-JIT URL grants it.
+5. Turn Developer Mode off and try to launch. Record what happens: a TrollStore warning, a launch refusal, or a launch without JIT.
 
 ### Dopamine 3 (if it supports this device)
-1. Uninstall the `.tipa` first; both use the same bundle id.
+1. The deb has its own id, so it won't collide with a TrollStore ipa — but uninstall an AltStore ipa first if one is present.
 2. Add `https://getboolean.github.io/eikon-source/` in Sileo, install Eikon, and launch.
 3. Expect **usable** at first paint, source `dopamine`.
 4. File the report. Its notes should also answer:
@@ -53,7 +55,7 @@ LiveContainer) has granted JIT — to report JIT `usable` with source
 JIT `not usable` (`txmEnforced`) regardless. This case is to find out the ground
 truth, not to confirm a fixed expectation.
 
-1. Install LiveContainer (via AltStore, SideStore, or TrollStore) and load `Eikon-0.1.0.ipa` into it as a guest app.
+1. Install LiveContainer (via AltStore, SideStore, or TrollStore) and load `Eikon-<v>.ipa` into it as a guest app.
 2. If you use a JIT source with LiveContainer (SideStore/JITStreamer, or its TrollStore JIT), enable it for the guest, then launch Eikon inside LiveContainer.
 3. File the report, and record in the notes:
    - the **Detected method** and the **Bundle ID** shown on the status screen (LiveContainer may run the guest under its own id)
@@ -77,8 +79,7 @@ truth, not to confirm a fixed expectation.
 
 | Device | Install | Expected JIT | Source or reason |
 |---|---|---|---|
-| iPad M2, 17.0 | TrollStore | usable | `trollStore` |
-| iPad M2, 17.0 | TrollStore, scheme disabled | not usable | `trollStoreTimedOut` |
+| iPad M2, 17.0 | TrollStore ipa, Open with JIT | usable | `trollStore` |
 | iPad M2, 17.0 | Dopamine 3 | usable | `dopamine` |
 | iPad M2, 17.0 | Dopamine 3, JIT off | not usable | `dopamineJITOff` |
 | iPhone A15, 27.0 | AltStore | not usable | `txmEnforced` |
diff --git a/packaging/deb/control.in b/packaging/deb/control.in
index 5590456..dfb9a14 100644
--- a/packaging/deb/control.in
+++ b/packaging/deb/control.in
@@ -1,4 +1,4 @@
-Package: com.getboolean.eikon
+Package: com.getboolean.eikon.rootless
 Name: Eikon
 Version: @VERSION@
 Architecture: iphoneos-arm64
diff --git a/packaging/entitlements/README.md b/packaging/entitlements/README.md
index 8a8bde0..fb47018 100644
--- a/packaging/entitlements/README.md
+++ b/packaging/entitlements/README.md
@@ -1,24 +1,32 @@
 # Entitlements
 
-Eikon ships one binary in three packages. They differ only in entitlements, one
-Info.plist stamp (`EKPackageKind`) and container format. These plists are what
+Eikon ships one binary in two packages: an AltStore/TrollStore `.ipa` and a
+Dopamine rootless `.deb`. They differ only in entitlements, one Info.plist stamp
+(`EKPackageKind`), the bundle id, and container format. These plists are what
 `scripts/package.sh` signs each artifact with, and what `scripts/verify_artifacts.py`
 checks the signed artifacts against.
 
+The `.ipa` covers both AltStore and TrollStore. AltStore re-signs it on install
+and replaces its entitlements with the developer profile's, so the embedded set
+below matters only for TrollStore, which preserves it. The deb uses its own
+bundle id (`com.getboolean.eikon.rootless`) so a Dopamine install and a
+TrollStore-installed ipa can coexist; the ipa keeps `com.getboolean.eikon`.
+
 ## Keys, and which install methods honour them
 
-| Key | deb | tipa | ipa | Purpose and who honours it |
-|---|---|---|---|---|
-| `com.apple.private.security.no-sandbox` | ✓ | ✓ | – | Runs outside the app sandbox. Honoured by Dopamine and TrollStore installs (ad-hoc / TrollStore signing). AltStore can't grant it, so the ipa leaves it out. |
-| `get-task-allow` | – | ✓ | ✓ | Lets another process attach. TrollStore's enable-jit helper attaches to set `CS_DEBUGGED`. AltStore's developer profile carries it too. The deb leaves it out (Dopamine doesn't need it, and on iOS 16+ it would force Developer Mode). |
-| `com.apple.developer.kernel.increased-memory-limit` | ✓ | ✓ | ✓ | Raises the per-app memory cap. A public App ID capability, so AltStore requests it from the developer account. |
-| `com.apple.developer.kernel.extended-virtual-addressing` | ✓ | ✓ | ✓ | Allows a larger virtual address space. Also a public App ID capability. |
-| `com.apple.private.memorystatus` | ✓ | ✓ | – | Adjusts the memorystatus (jetsam) limits. A private key AltStore can't grant, so the ipa leaves it out. |
+| Key | ipa | deb | Purpose and who honours it |
+|---|---|---|---|
+| `com.apple.private.security.no-sandbox` | ✓ | ✓ | Runs outside the app sandbox. Honoured by TrollStore and by Dopamine installs. AltStore can't grant it, and drops it when it re-signs the ipa. |
+| `get-task-allow` | ✓ | – | Lets another process attach. TrollStore's enable-jit / "Open with JIT" attaches to set `CS_DEBUGGED`. AltStore's developer profile carries it too. The deb leaves it out (Dopamine doesn't need it, and on iOS 16+ it would force Developer Mode). |
+| `com.apple.developer.kernel.increased-memory-limit` | ✓ | ✓ | Raises the per-app memory cap. A public App ID capability, so AltStore requests it from the developer account. |
+| `com.apple.developer.kernel.extended-virtual-addressing` | ✓ | ✓ | Allows a larger virtual address space. Also a public App ID capability. |
+| `com.apple.private.memorystatus` | ✓ | ✓ | Adjusts the memorystatus (jetsam) limits. A private key AltStore can't grant; it drops it when re-signing the ipa. |
 
 ## Unverified
 
 - Whether the two `com.apple.developer.kernel.*` memory keys have any effect under Dopamine's ad-hoc signing. Evidence: the device report's `memory.availableBytes`.
 - Whether an AltStore **free** team can be granted `increased-memory-limit` and `extended-virtual-addressing`. Evidence: the first ipa install. If a free team can't be granted a capability and the install fails, drop that key from `ipa.plist` and note it here.
+- Whether a TrollStore-installed ipa is detected as `trollStore` and gets JIT from "Open with JIT". Evidence: a device report from that install.
 
 Later splits add rows here: section 08 for the memory evidence, sections 05 and 07 for address space.
 
@@ -38,6 +46,10 @@ It brings a stricter IOKit sandbox (Metal would then need explicit GPU exception
 | `com.apple.private.persona-mgmt` | Not needed. |
 | `platform-application` | See above. |
 
-## `.tipa` and Developer Mode
+## Developer Mode
+
+The ipa carries `get-task-allow`, so on **iOS 16 and later it needs Developer Mode on**, both when installed via TrollStore and after AltStore re-signs it. The deb omits the key and needs no Developer Mode.
+
+## One id per artifact
 
-The tipa carries `get-task-allow`, so on **iOS 16 and later it needs Developer Mode on**. Without it the app may not launch. The deb omits the key for exactly this reason, and the README documents the requirement.
+The `.ipa` keeps `com.getboolean.eikon` (AltStore rewrites it per account anyway). The `.deb` uses `com.getboolean.eikon.rootless`. Different ids let a Dopamine install and a TrollStore-installed ipa coexist on one device instead of shadowing each other. The executable is byte-identical across both; only `Info.plist` and the signature differ, so `make verify`'s same-binary check still holds.
diff --git a/packaging/entitlements/ipa.plist b/packaging/entitlements/ipa.plist
index e385036..63df389 100644
--- a/packaging/entitlements/ipa.plist
+++ b/packaging/entitlements/ipa.plist
@@ -2,11 +2,15 @@
 <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
 <plist version="1.0">
 <dict>
+	<key>com.apple.private.security.no-sandbox</key>
+	<true/>
 	<key>get-task-allow</key>
 	<true/>
 	<key>com.apple.developer.kernel.increased-memory-limit</key>
 	<true/>
 	<key>com.apple.developer.kernel.extended-virtual-addressing</key>
 	<true/>
+	<key>com.apple.private.memorystatus</key>
+	<true/>
 </dict>
 </plist>
diff --git a/packaging/entitlements/tipa.plist b/packaging/entitlements/tipa.plist
deleted file mode 100644
index 63df389..0000000
--- a/packaging/entitlements/tipa.plist
+++ /dev/null
@@ -1,16 +0,0 @@
-<?xml version="1.0" encoding="UTF-8"?>
-<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
-<plist version="1.0">
-<dict>
-	<key>com.apple.private.security.no-sandbox</key>
-	<true/>
-	<key>get-task-allow</key>
-	<true/>
-	<key>com.apple.developer.kernel.increased-memory-limit</key>
-	<true/>
-	<key>com.apple.developer.kernel.extended-virtual-addressing</key>
-	<true/>
-	<key>com.apple.private.memorystatus</key>
-	<true/>
-</dict>
-</plist>
diff --git a/planning/01-build-packaging-jit/sections/section-10-packaging-verifier.md b/planning/01-build-packaging-jit/sections/section-10-packaging-verifier.md
index e81f5eb..b2259cf 100644
--- a/planning/01-build-packaging-jit/sections/section-10-packaging-verifier.md
+++ b/planning/01-build-packaging-jit/sections/section-10-packaging-verifier.md
@@ -313,3 +313,14 @@ Open points recorded in the entitlements README: whether Dopamine honours the me
 The archive's arm64 guard and the verifier's nested-Mach-O checks have nothing to act on in this split (a single flat app bundle); they guard the later splits that add frameworks.
 
 The review trail is in `../implementation/code_review/section-10-*.md`.
+
+---
+
+## Change 2026-09-28: two artifacts, distinct ids
+
+The `.tipa` was dropped (owner decision): TrollStore installs the `.ipa` directly, so a separate tipa is redundant. The pipeline now produces two artifacts:
+
+- `dist/Eikon-<v>.ipa` — AltStore and TrollStore. Its `ipa.plist` carries the TrollStore-friendly set (`no-sandbox`, `get-task-allow`, the kernel memory keys, `memorystatus`); AltStore re-signs and drops them, TrollStore keeps them. Bundle id `com.getboolean.eikon`.
+- `dist/com.getboolean.eikon.rootless_<v>_iphoneos-arm64.deb` — Dopamine. Bundle id `com.getboolean.eikon.rootless`, stamped by `package.sh` (like `EKPackageKind`) so the executable stays byte-identical.
+
+The distinct ids let a Dopamine install and a TrollStore-installed ipa coexist instead of shadowing each other (a same-bundle-id collision shadowed the tipa during v0.1.0 testing). `verify_artifacts.py` now expects exactly the ipa and the deb; the same-binary check compares the two, and holds because the bundle id lives in Info.plist, not the Mach-O. `entitlements/tipa.plist` was removed. `make all` passes at 0.2.0.
diff --git a/planning/requirements.md b/planning/requirements.md
index 010c44f..c8d7410 100644
--- a/planning/requirements.md
+++ b/planning/requirements.md
@@ -17,7 +17,7 @@ The owner, playing their own collection of Windows games on their own jailbroken
 5. Show game text correctly in any language the game was written for.
 6. Translate game text while the game runs, into the user's language.
 7. Install as a Dopamine rootless package from the Sileo source.
-8. Install on devices that are not jailbroken: a TrollStore build (`.tipa`), and an IPA sideloaded by hand with AltStore.
+8. Install on devices that are not jailbroken: a single `.ipa` that installs with AltStore, and the same `.ipa` installed with TrollStore. (The separate `.tipa` was dropped on 2026-09-28; TrollStore installs the `.ipa` directly.)
 9. Sync game saves and settings across the owner's devices through their own WebDAV server.
 
 ## Games to support, in priority order
@@ -37,7 +37,7 @@ The collection's `Game.exe` files are 11 i386 and 5 amd64. Most games are Japane
 ## Functional requirements
 
 ### Builds and JIT
-- **One build.** One app binary, built once, ships as all three artifacts: the Dopamine deb, the TrollStore `.tipa`, and the AltStore `.ipa`. The artifacts differ only in entitlements and packaging. The app decides at run time, from whether the process has usable JIT, which routes it offers.
+- **One build.** One app binary, built once, ships as two artifacts: the Dopamine deb and the `.ipa` (for AltStore and TrollStore). They differ only in entitlements, one Info.plist stamp, the bundle id and packaging. The app decides at run time, from whether the process has usable JIT, which routes it offers. (Two artifacts, not three, since 2026-09-28.)
 - **Turning JIT on.** The app turns JIT on automatically where the install method allows it:
   - on Dopamine, using what Dopamine provides, with no setup or extra tool for the user
   - on TrollStore, through TrollStore's "launch with JIT" URL scheme (`apple-magnifier://enable-jit?bundle-id=<id>`, TrollStore 2.0.12 and later), the way UTM and PojavLauncher do. It does not use the `dynamic-codesigning` entitlement: iOS 15 and later on A12 and newer chips ban it, and apps signed with it crash on launch.
@@ -100,9 +100,9 @@ The collection's `Game.exe` files are 11 i386 and 5 amd64. Most games are Japane
 - Works on every build and install method.
 
 ### Packaging
-- A Dopamine rootless deb, package id `com.getboolean.eikon`, published on the `eikon-source` Sileo repo through GitHub Pages. Only package files go there, never app source.
-- A TrollStore package (`Eikon.tipa`) and an AltStore package (`Eikon.ipa`). All three packages carry the same app binary at the same version, and differ only in entitlements and packaging.
-- The deb and the `.tipa` run unsandboxed (`com.apple.private.security.no-sandbox`), which TrollStore documents and Dopamine honors. The `.tipa` keeps its data container, which TrollStore says `no-sandbox` allows. Neither uses root helpers (`com.apple.private.persona-mgmt`) or any entitlement TrollStore lists as banned. Neither uses `platform-application` (decided 2026-09-27). It moves the app to a stricter IOKit sandbox profile, so Metal would need GPU exceptions. It can also cost the data container unless `com.apple.private.security.storage.AppDataContainers` is added. No planned feature needs it.
+- A Dopamine rootless deb, package id `com.getboolean.eikon.rootless`, published on the `eikon-source` Sileo repo through GitHub Pages. Only package files go there, never app source. (Its own id, distinct from the ipa, so a Dopamine install and a TrollStore-installed ipa can coexist.)
+- One `Eikon.ipa`, installed with either AltStore or TrollStore, with bundle id `com.getboolean.eikon`. AltStore rewrites the id per account and re-signs, replacing the ipa's entitlements; TrollStore installs it as-is and keeps them. Both packages carry the same app binary at the same version, and differ only in entitlements, the bundle id and packaging.
+- The deb and the `.ipa` run unsandboxed (`com.apple.private.security.no-sandbox`) where their install method allows it: Dopamine honors it for the deb, and TrollStore for the ipa. AltStore re-signs the ipa and drops it. The TrollStore ipa keeps its data container, which TrollStore says `no-sandbox` allows. Neither uses root helpers (`com.apple.private.persona-mgmt`) or any entitlement TrollStore lists as banned. Neither uses `platform-application` (decided 2026-09-27). It moves the app to a stricter IOKit sandbox profile, so Metal would need GPU exceptions. It can also cost the data container unless `com.apple.private.security.storage.AppDataContainers` is added. No planned feature needs it.
 
 ## Constraints
 
@@ -115,7 +115,9 @@ The collection's `Game.exe` files are 11 i386 and 5 amd64. Most games are Japane
   - A crash in a game takes the app down with it.
 - **What each install method allows:**
 
-  | | Dopamine deb | TrollStore `.tipa` | AltStore `.ipa` |
+  (TrollStore and AltStore install the same `.ipa`; they differ only in runtime JIT behaviour.)
+
+  | | Dopamine deb | TrollStore `.ipa` | AltStore `.ipa` |
   |---|---|---|---|
   | JIT | Automatic, through Dopamine | Automatic, through TrollStore's JIT launch | Never requested. Used if a JIT enabler provides it |
   | x86 translation, usual case | FEX JIT | FEX JIT | Box64 interpreter (FEX if an enabler gave usable JIT) |
@@ -181,7 +183,7 @@ For Eikon, that means: build the graphics layers as ARM64EC for 64-bit games; st
 
 ## Operational requirements
 
-- Sign every binary and dylib in each package so it loads under its install method: ad-hoc with `ldid` for Dopamine, TrollStore's signing for the `.tipa`, and AltStore's signing at install for the `.ipa`.
+- Sign every binary and dylib in each package so it loads under its install method: ad-hoc with `ldid` for Dopamine, and for the `.ipa` either TrollStore's signing or AltStore's signing at install.
 - Run Wine's server as a thread inside the app process, and replace its use of Mach task ports, which iOS restricts.
 - Survive iOS memory limits for the app process. Unity games need gigabytes.
 - Handle the app going to the background while a game runs: pause the game, and stop Metal drawing, since using Metal in the background crashes the process.
@@ -192,9 +194,9 @@ For Eikon, that means: build the graphics layers as ARM64EC for 64-bit games; st
 Made by the owner on 2026-09-27:
 
 - **License:** GPL-3.0-or-later. Kirikiroid2's GPL-derived video player may ship.
-- **Builds:** one build, shipped as the Dopamine deb, the TrollStore `.tipa`, and the AltStore `.ipa`. The app picks routes at run time from whether it has usable JIT. This replaced the earlier two-build plan (main and no-JIT) on 2026-09-27, so that installs without JIT still run the no-JIT routes, and AltStore installs with JIT from an enabler can use FEX.
+- **Builds:** one build, shipped as the Dopamine deb and the `.ipa` (AltStore or TrollStore). The app picks routes at run time from whether it has usable JIT. This replaced the earlier two-build plan (main and no-JIT) on 2026-09-27, so that installs without JIT still run the no-JIT routes, and AltStore installs with JIT from an enabler can use FEX.
 - **JIT:** automatic on Dopamine and TrollStore. Relying on Dopamine's and TrollStore's mechanisms is acceptable.
-- **Entitlements:** unsandboxed for the deb and the `.tipa`, with `get-task-allow` on the `.tipa` for TrollStore's JIT launch. Sideloaded apps already need Developer Mode. No root helpers, and no `platform-application`.
+- **Entitlements:** unsandboxed for the deb and the `.ipa`, with `get-task-allow` on the `.ipa` for TrollStore's JIT launch (AltStore drops it and re-signs). Sideloaded apps already need Developer Mode. No root helpers, and no `platform-application`.
 - **Process model:** games run inside the app process on every install method.
 - **32-bit address space:** a guest window, not a small `__PAGEZERO`, which the iOS kernel rejects.
 - **Madeira:** take its design decisions, but do not build on its code or forks. It is a research prototype, far from complete.
diff --git a/scripts/package.sh b/scripts/package.sh
index 0129620..0b67ac4 100755
--- a/scripts/package.sh
+++ b/scripts/package.sh
@@ -1,7 +1,7 @@
 #!/bin/bash
 # Package the Release archive into one install artifact. Run from the repo root.
 #
-#   scripts/package.sh ipa | tipa | deb
+#   scripts/package.sh ipa | deb
 #
 # One build, three artifacts: they differ only in entitlements, the EKPackageKind
 # stamp and container format. Reads the version from VERSION; nothing is hard-coded.
@@ -17,10 +17,14 @@ die() {
 
 kind=${1:-}
 case "$kind" in
-ipa | tipa | deb) ;;
-*) die "usage: package.sh ipa|tipa|deb" ;;
+ipa | deb) ;;
+*) die "usage: package.sh ipa|deb" ;;
 esac
 
+# The deb gets its own bundle id, so a Dopamine install and a TrollStore-installed
+# ipa can coexist. The ipa keeps the id the archive built with.
+deb_bundle_id="com.getboolean.eikon.rootless"
+
 version=$(tr -d '[:space:]' <VERSION)
 [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION '$version' is not MAJOR.MINOR.PATCH"
 
@@ -46,6 +50,9 @@ app="$stage/Eikon.app"
 COPYFILE_DISABLE=1 ditto "$archived_app" "$app"
 
 /usr/libexec/PlistBuddy -c "Set :EKPackageKind $kind" "$app/Info.plist"
+if [ "$kind" = deb ]; then
+	/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $deb_bundle_id" "$app/Info.plist"
+fi
 
 bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")
 # One bundle-level call: Procursus ldid signs nested code first and seals resources.
@@ -57,7 +64,7 @@ read_back=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app
 mkdir -p dist
 
 case "$kind" in
-ipa | tipa)
+ipa)
 	mkdir -p "$stage/Payload"
 	mv "$app" "$stage/Payload/Eikon.app"
 	out="$root/dist/Eikon-$version.$kind"
diff --git a/scripts/verify_artifacts.py b/scripts/verify_artifacts.py
index 9051349..4754765 100755
--- a/scripts/verify_artifacts.py
+++ b/scripts/verify_artifacts.py
@@ -173,7 +173,7 @@ def is_macho(path: Path) -> bool:
 # --- Artifact discovery and extraction ------------------------------------
 
 def find_artifacts(dist: Path) -> dict[str, Path]:
-    patterns = {"ipa": "*.ipa", "tipa": "*.tipa", "deb": "*.deb"}
+    patterns = {"ipa": "*.ipa", "deb": "*.deb"}
     found: dict[str, Path] = {}
     problems = []
     for kind, pattern in patterns.items():
@@ -188,7 +188,7 @@ def find_artifacts(dist: Path) -> dict[str, Path]:
 
 
 def extract(artifact: Path, kind: str, dest: Path) -> Path:
-    if kind in ("ipa", "tipa"):
+    if kind == "ipa":
         with zipfile.ZipFile(artifact) as archive:
             names = archive.namelist()
             archive.extractall(dest)
@@ -219,7 +219,7 @@ def read_info(app: Path) -> dict:
 
 def check_layout(kind: str, dest: Path, app: Path) -> list[str]:
     problems: list[str] = []
-    if kind in ("ipa", "tipa"):
+    if kind == "ipa":
         for name in zip_entries(dest):
             top = name.split("/", 1)[0]
             if top not in ("Payload", "") and not name.startswith("Payload/"):
@@ -267,7 +267,7 @@ def check_version_and_stamp(kind: str, app: Path, version: str) -> list[str]:
 
 def check_hygiene(kind: str, dest: Path, app: Path) -> list[str]:
     problems = []
-    names = zip_entries(dest) if kind in ("ipa", "tipa") else [
+    names = zip_entries(dest) if kind == "ipa" else [
         str(p.relative_to(dest)) for p in dest.rglob("*") if p.name != ".zip-entries"
     ]
     for name in names:
