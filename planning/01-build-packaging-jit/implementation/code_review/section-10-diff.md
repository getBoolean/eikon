diff --git a/.github/workflows/ci.yml b/.github/workflows/ci.yml
index 6ea33d9..9150c5c 100644
--- a/.github/workflows/ci.yml
+++ b/.github/workflows/ci.yml
@@ -58,6 +58,13 @@ jobs:
           echo "DEVELOPER_DIR=$best/Contents/Developer" >> "$GITHUB_ENV"
           DEVELOPER_DIR="$best/Contents/Developer" xcodebuild -version
       - name: Install tools
-        run: brew install xcodegen uv
-      - name: Swift tests and launch check
-        run: make test-swift
+        run: |
+          brew list --formula ldid >/dev/null 2>&1 && brew uninstall --ignore-dependencies ldid || true
+          brew install xcodegen ldid-procursus dpkg uv
+      - name: Build, package and verify
+        run: make test-swift archive package verify
+      - name: Upload artifacts
+        uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1
+        with:
+          name: eikon-dist
+          path: dist/
diff --git a/Makefile b/Makefile
index 5bbe6c4..bad4a05 100644
--- a/Makefile
+++ b/Makefile
@@ -50,16 +50,17 @@ test-scripts:
 	@uv run pytest tests/
 
 archive:
-	@$(call stub,10)
+	@scripts/archive.sh
 
 ipa tipa deb:
-	@$(call stub,10)
+	@scripts/package.sh $@
 
-package:
-	@$(call stub,10)
+package: ipa tipa deb
+	@cd dist && shasum -a 256 Eikon-*.ipa Eikon-*.tipa *.deb > SHA256SUMS
+	@echo "package: wrote dist/SHA256SUMS"
 
 verify:
-	@$(call stub,10)
+	@uv run scripts/verify_artifacts.py dist/
 
 all: check test archive package verify
 
diff --git a/README.md b/README.md
index c39c8cf..9ac161f 100644
--- a/README.md
+++ b/README.md
@@ -76,7 +76,9 @@ process handle SIGBUS SIGSEGV SIGILL SIGTRAP -s false -n false
 
 - **Dopamine rootless deb** (`com.getboolean.eikon`, `iphoneos-arm64`), installed at `/var/jb/Applications/Eikon.app`. Supported on Dopamine 2, for iOS 15.0–16.6.1.
 - **`Eikon.tipa`** for TrollStore, up to iOS 17.0. On iOS 16 and later, **Developer Mode must be on**: the `.tipa` carries `get-task-allow`, which TrollStore's enable-JIT feature needs.
-- **`Eikon.ipa`** for AltStore, on current iOS.
+- **`Eikon.ipa`** for AltStore, on current iOS. AltStore re-signs it with the developer profile's entitlements, replacing the ones in the ipa.
+
+The deb needs no Developer Mode. Each artifact carries the same binary, signed with its own entitlements (`packaging/entitlements/`); `make verify` checks that.
 
 ## JIT
 
diff --git a/packaging/deb/control.in b/packaging/deb/control.in
new file mode 100644
index 0000000..5590456
--- /dev/null
+++ b/packaging/deb/control.in
@@ -0,0 +1,14 @@
+Package: com.getboolean.eikon
+Name: Eikon
+Version: @VERSION@
+Architecture: iphoneos-arm64
+Depends: firmware (>= 15.0)
+Section: Games
+Maintainer: getBoolean <https://github.com/getBoolean>
+Author: getBoolean
+Installed-Size: @INSTALLED_SIZE@
+Homepage: https://github.com/getBoolean/eikon
+Icon: https://getboolean.github.io/eikon-source/icon.png
+Depiction: https://getboolean.github.io/eikon-source/
+SileoDepiction: https://getboolean.github.io/eikon-source/depiction.json
+Description: An early prototype that reports whether JIT is usable and shows device status. Not a working emulator yet.
diff --git a/packaging/deb/postinst b/packaging/deb/postinst
new file mode 100755
index 0000000..f7ad96b
--- /dev/null
+++ b/packaging/deb/postinst
@@ -0,0 +1,15 @@
+#!/bin/sh
+# Register the app icon after install. Exits 0 if uicache is absent; the
+# Procursus uikittools trigger on /var/jb/Applications usually covers this.
+# Open point: whether uicache must run as `mobile` on iOS 15+ (checked on the
+# first Dopamine install, adjusted here if needed).
+set -e
+PATH="/var/jb/usr/bin:/var/jb/bin:$PATH"
+export PATH
+
+if [ "$1" = configure ] || [ -z "$1" ]; then
+	if command -v uicache >/dev/null 2>&1; then
+		uicache -p /var/jb/Applications/Eikon.app || true
+	fi
+fi
+exit 0
diff --git a/packaging/deb/prerm b/packaging/deb/prerm
new file mode 100755
index 0000000..743aa07
--- /dev/null
+++ b/packaging/deb/prerm
@@ -0,0 +1,12 @@
+#!/bin/sh
+# Unregister the app icon on removal (not on upgrade).
+set -e
+PATH="/var/jb/usr/bin:/var/jb/bin:$PATH"
+export PATH
+
+if [ "$1" = remove ]; then
+	if command -v uicache >/dev/null 2>&1; then
+		uicache -u /var/jb/Applications/Eikon.app || true
+	fi
+fi
+exit 0
diff --git a/packaging/entitlements/README.md b/packaging/entitlements/README.md
new file mode 100644
index 0000000..8a8bde0
--- /dev/null
+++ b/packaging/entitlements/README.md
@@ -0,0 +1,43 @@
+# Entitlements
+
+Eikon ships one binary in three packages. They differ only in entitlements, one
+Info.plist stamp (`EKPackageKind`) and container format. These plists are what
+`scripts/package.sh` signs each artifact with, and what `scripts/verify_artifacts.py`
+checks the signed artifacts against.
+
+## Keys, and which install methods honour them
+
+| Key | deb | tipa | ipa | Purpose and who honours it |
+|---|---|---|---|---|
+| `com.apple.private.security.no-sandbox` | ✓ | ✓ | – | Runs outside the app sandbox. Honoured by Dopamine and TrollStore installs (ad-hoc / TrollStore signing). AltStore can't grant it, so the ipa leaves it out. |
+| `get-task-allow` | – | ✓ | ✓ | Lets another process attach. TrollStore's enable-jit helper attaches to set `CS_DEBUGGED`. AltStore's developer profile carries it too. The deb leaves it out (Dopamine doesn't need it, and on iOS 16+ it would force Developer Mode). |
+| `com.apple.developer.kernel.increased-memory-limit` | ✓ | ✓ | ✓ | Raises the per-app memory cap. A public App ID capability, so AltStore requests it from the developer account. |
+| `com.apple.developer.kernel.extended-virtual-addressing` | ✓ | ✓ | ✓ | Allows a larger virtual address space. Also a public App ID capability. |
+| `com.apple.private.memorystatus` | ✓ | ✓ | – | Adjusts the memorystatus (jetsam) limits. A private key AltStore can't grant, so the ipa leaves it out. |
+
+## Unverified
+
+- Whether the two `com.apple.developer.kernel.*` memory keys have any effect under Dopamine's ad-hoc signing. Evidence: the device report's `memory.availableBytes`.
+- Whether an AltStore **free** team can be granted `increased-memory-limit` and `extended-virtual-addressing`. Evidence: the first ipa install. If a free team can't be granted a capability and the install fails, drop that key from `ipa.plist` and note it here.
+
+Later splits add rows here: section 08 for the memory evidence, sections 05 and 07 for address space.
+
+## Why `platform-application` is not used
+
+It brings a stricter IOKit sandbox (Metal would then need explicit GPU exceptions), it can cost the app its data container, and nothing Eikon does needs it.
+
+## Forbidden in every artifact
+
+`scripts/verify_artifacts.py` fails the build if any artifact's main executable carries one of these:
+
+| Key | Why it's forbidden |
+|---|---|
+| `dynamic-codesigning` | Crashes on iOS 15+ / A12+, and TrollStore bans it. Eikon never relies on RWX or `MAP_JIT`. |
+| `com.apple.private.cs.debugger` | Eikon never attaches a debugger, calls `ptrace`, or uses task-for-pid. |
+| `com.apple.private.skip-library-validation` | Not needed; Eikon loads only its own signed code. |
+| `com.apple.private.persona-mgmt` | Not needed. |
+| `platform-application` | See above. |
+
+## `.tipa` and Developer Mode
+
+The tipa carries `get-task-allow`, so on **iOS 16 and later it needs Developer Mode on**. Without it the app may not launch. The deb omits the key for exactly this reason, and the README documents the requirement.
diff --git a/packaging/entitlements/deb.plist b/packaging/entitlements/deb.plist
new file mode 100644
index 0000000..d514fcf
--- /dev/null
+++ b/packaging/entitlements/deb.plist
@@ -0,0 +1,14 @@
+<?xml version="1.0" encoding="UTF-8"?>
+<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
+<plist version="1.0">
+<dict>
+	<key>com.apple.private.security.no-sandbox</key>
+	<true/>
+	<key>com.apple.developer.kernel.increased-memory-limit</key>
+	<true/>
+	<key>com.apple.developer.kernel.extended-virtual-addressing</key>
+	<true/>
+	<key>com.apple.private.memorystatus</key>
+	<true/>
+</dict>
+</plist>
diff --git a/packaging/entitlements/ipa.plist b/packaging/entitlements/ipa.plist
new file mode 100644
index 0000000..e385036
--- /dev/null
+++ b/packaging/entitlements/ipa.plist
@@ -0,0 +1,12 @@
+<?xml version="1.0" encoding="UTF-8"?>
+<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
+<plist version="1.0">
+<dict>
+	<key>get-task-allow</key>
+	<true/>
+	<key>com.apple.developer.kernel.increased-memory-limit</key>
+	<true/>
+	<key>com.apple.developer.kernel.extended-virtual-addressing</key>
+	<true/>
+</dict>
+</plist>
diff --git a/packaging/entitlements/tipa.plist b/packaging/entitlements/tipa.plist
new file mode 100644
index 0000000..63df389
--- /dev/null
+++ b/packaging/entitlements/tipa.plist
@@ -0,0 +1,16 @@
+<?xml version="1.0" encoding="UTF-8"?>
+<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
+<plist version="1.0">
+<dict>
+	<key>com.apple.private.security.no-sandbox</key>
+	<true/>
+	<key>get-task-allow</key>
+	<true/>
+	<key>com.apple.developer.kernel.increased-memory-limit</key>
+	<true/>
+	<key>com.apple.developer.kernel.extended-virtual-addressing</key>
+	<true/>
+	<key>com.apple.private.memorystatus</key>
+	<true/>
+</dict>
+</plist>
diff --git a/scripts/archive.sh b/scripts/archive.sh
new file mode 100755
index 0000000..5d51bc6
--- /dev/null
+++ b/scripts/archive.sh
@@ -0,0 +1,57 @@
+#!/bin/bash
+# Build the one Release archive that every artifact comes from. Run from the repo root.
+set -euo pipefail
+
+root=$(cd "$(dirname "$0")/.." && pwd)
+cd "$root"
+
+die() {
+	echo "archive.sh: $*" >&2
+	exit 1
+}
+
+make project
+
+archive="build/Eikon.xcarchive"
+rm -rf "$archive"
+xcrun xcodebuild archive \
+	-project Eikon.xcodeproj \
+	-scheme Eikon \
+	-configuration Release \
+	-destination 'generic/platform=iOS' \
+	-archivePath "$archive" \
+	CODE_SIGNING_ALLOWED=NO
+
+app="$archive/Products/Applications/Eikon.app"
+[ -d "$app" ] || die "archive did not produce $app"
+
+# A Release build must never ship the placeholder acknowledgements.
+[ -f build/generated/Acknowledgements.json ] || die "build/generated/Acknowledgements.json is missing; run make generated"
+
+# arm64-only guard. No nested Mach-O files exist in this split; the guard is for
+# later splits that add frameworks.
+is_macho() {
+	local magic
+	magic=$(xxd -p -l 4 "$1" 2>/dev/null || true)
+	case "$magic" in
+	cffaedfe | cafebabe | feedfacf | bebafeca) return 0 ;;
+	*) return 1 ;;
+	esac
+}
+
+while IFS= read -r -d '' macho; do
+	is_macho "$macho" || continue
+	archs=$(xcrun lipo -archs "$macho" 2>/dev/null) || die "could not read architectures of $macho"
+	case " $archs " in
+	*" arm64 "*) ;;
+	*) die "$macho has no arm64 slice (has: $archs)" ;;
+	esac
+	if [ "$archs" != "arm64" ]; then
+		echo "archive.sh: thinning $macho ($archs) to arm64"
+		xcrun lipo "$macho" -thin arm64 -output "$macho"
+		archs=$(xcrun lipo -archs "$macho")
+		[ "$archs" = "arm64" ] || die "$macho still has non-arm64 slices after thinning: $archs"
+	fi
+done < <(find "$app" -type f -print0)
+
+echo "archive.sh: built $archive"
diff --git a/scripts/package.sh b/scripts/package.sh
new file mode 100755
index 0000000..0129620
--- /dev/null
+++ b/scripts/package.sh
@@ -0,0 +1,90 @@
+#!/bin/bash
+# Package the Release archive into one install artifact. Run from the repo root.
+#
+#   scripts/package.sh ipa | tipa | deb
+#
+# One build, three artifacts: they differ only in entitlements, the EKPackageKind
+# stamp and container format. Reads the version from VERSION; nothing is hard-coded.
+set -euo pipefail
+
+root=$(cd "$(dirname "$0")/.." && pwd)
+cd "$root"
+
+die() {
+	echo "package.sh: $*" >&2
+	exit 1
+}
+
+kind=${1:-}
+case "$kind" in
+ipa | tipa | deb) ;;
+*) die "usage: package.sh ipa|tipa|deb" ;;
+esac
+
+version=$(tr -d '[:space:]' <VERSION)
+[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION '$version' is not MAJOR.MINOR.PATCH"
+
+archived_app="build/Eikon.xcarchive/Products/Applications/Eikon.app"
+[ -d "$archived_app" ] || die "missing $archived_app; run make archive"
+
+entitlements="packaging/entitlements/$kind.plist"
+[ -f "$entitlements" ] || die "missing $entitlements"
+
+# ldid must be the Procursus build (the check doctor.sh uses).
+command -v ldid >/dev/null 2>&1 || die "ldid not found; run make doctor"
+ldid_help=$( { ldid 2>&1; ldid --version 2>&1; } || true)
+if ! printf '%s' "$ldid_help" | grep -qi procursus &&
+	! printf '%s' "$ldid_help" | grep -Eq -- '(^|[[:space:]])-M([[:space:]]|$)'; then
+	die "ldid is not the Procursus build; run make doctor"
+fi
+
+stage="build/stage/$kind"
+rm -rf "$stage"
+mkdir -p "$stage"
+
+app="$stage/Eikon.app"
+COPYFILE_DISABLE=1 ditto "$archived_app" "$app"
+
+/usr/libexec/PlistBuddy -c "Set :EKPackageKind $kind" "$app/Info.plist"
+
+bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")
+# One bundle-level call: Procursus ldid signs nested code first and seals resources.
+ldid "-S$entitlements" "-I$bundle_id" "$app"
+
+read_back=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Info.plist")
+[ "$read_back" = "$version" ] || die "staged version $read_back does not match VERSION $version"
+
+mkdir -p dist
+
+case "$kind" in
+ipa | tipa)
+	mkdir -p "$stage/Payload"
+	mv "$app" "$stage/Payload/Eikon.app"
+	out="$root/dist/Eikon-$version.$kind"
+	rm -f "$out"
+	(cd "$stage" && zip -qr -X --symlinks "$out" Payload -x '*/._*' '*/.DS_Store' '__MACOSX/*')
+	echo "package.sh: wrote dist/Eikon-$version.$kind"
+	;;
+deb)
+	deb_root="$stage/root"
+	app_dir="$deb_root/var/jb/Applications"
+	doc_dir="$deb_root/var/jb/usr/share/doc/$bundle_id"
+	mkdir -p "$app_dir" "$doc_dir" "$deb_root/DEBIAN"
+	mv "$app" "$app_dir/Eikon.app"
+	cp LICENSE THIRD_PARTY_NOTICES.md "$doc_dir/"
+
+	installed_size=$(du -sk "$deb_root/var" | cut -f1)
+	sed -e "s/@VERSION@/$version/" -e "s/@INSTALLED_SIZE@/$installed_size/" \
+		packaging/deb/control.in >"$deb_root/DEBIAN/control"
+	install -m 0755 packaging/deb/postinst "$deb_root/DEBIAN/postinst"
+	install -m 0755 packaging/deb/prerm "$deb_root/DEBIAN/prerm"
+
+	chmod -R u=rwX,go=rX "$deb_root"
+	chmod 0755 "$deb_root/DEBIAN/postinst" "$deb_root/DEBIAN/prerm"
+
+	out="dist/${bundle_id}_${version}_iphoneos-arm64.deb"
+	rm -f "$out"
+	SOURCE_DATE_EPOCH=$(git log -1 --format=%ct) dpkg-deb --root-owner-group -Zxz -b "$deb_root" "$out"
+	echo "package.sh: wrote $out"
+	;;
+esac
diff --git a/scripts/verify_artifacts.py b/scripts/verify_artifacts.py
new file mode 100755
index 0000000..fcfb274
--- /dev/null
+++ b/scripts/verify_artifacts.py
@@ -0,0 +1,386 @@
+#!/usr/bin/env python3
+"""Verify the three install artifacts in dist/ and that they share one binary.
+
+    uv run scripts/verify_artifacts.py dist/
+
+Expectations come from the repo (VERSION, packaging/entitlements/<kind>.plist),
+not from constants in this file. The only policy list here is the forbidden
+entitlements. Reports every failure, grouped by artifact, before exiting 1.
+"""
+
+from __future__ import annotations
+
+import hashlib
+import plistlib
+import struct
+import subprocess
+import sys
+import tempfile
+import zipfile
+from pathlib import Path
+
+ROOT = Path(__file__).resolve().parent.parent
+ENTITLEMENTS_DIR = ROOT / "packaging" / "entitlements"
+
+FORBIDDEN = [
+    "dynamic-codesigning",
+    "com.apple.private.cs.debugger",
+    "com.apple.private.skip-library-validation",
+    "com.apple.private.persona-mgmt",
+    "platform-application",
+]
+
+MH_MAGIC_64 = 0xFEEDFACF
+FAT_MAGIC = 0xCAFEBABE
+FAT_MAGIC_64 = 0xCAFEBABF
+CPU_TYPE_ARM64 = 0x0100000C
+LC_SEGMENT_64 = 0x19
+LC_UUID = 0x1B
+LC_CODE_SIGNATURE = 0x1D
+CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
+CSSLOT_CODEDIRECTORY = 0
+CSSLOT_RESOURCEDIR = 3
+
+
+class VerifyError(Exception):
+    """A tool or artifact could not be processed at all."""
+
+
+def run(*args: str) -> bytes:
+    result = subprocess.run(args, capture_output=True)
+    if result.returncode != 0:
+        raise VerifyError(f"{' '.join(args)} failed: {result.stderr.decode(errors='replace').strip()}")
+    return result.stdout
+
+
+# --- Mach-O parsing -------------------------------------------------------
+
+class MachO:
+    """The arm64 image of a Mach-O file: its load commands, parsed lazily."""
+
+    def __init__(self, path: Path) -> None:
+        self.path = path
+        data = path.read_bytes()
+        self.base, self.size = _arm64_slice(data)
+        self.data = data
+
+    def _macho(self) -> bytes:
+        return self.data[self.base:self.base + self.size]
+
+    def load_commands(self):
+        macho = self._macho()
+        (magic,) = struct.unpack_from("<I", macho, 0)
+        if magic != MH_MAGIC_64:
+            raise VerifyError(f"{self.path}: not a 64-bit little-endian Mach-O")
+        ncmds = struct.unpack_from("<I", macho, 16)[0]
+        offset = 32  # mach_header_64
+        for _ in range(ncmds):
+            cmd, cmdsize = struct.unpack_from("<II", macho, offset)
+            yield cmd, offset, cmdsize
+            offset += cmdsize
+
+    def uuid(self) -> bytes | None:
+        macho = self._macho()
+        for cmd, offset, _ in self.load_commands():
+            if cmd == LC_UUID:
+                return macho[offset + 8:offset + 24]
+        return None
+
+    def segment_hashes(self) -> dict[str, str]:
+        """sha256 per segment file range, excluding __LINKEDIT (holds the signature)."""
+        macho = self._macho()
+        hashes: dict[str, str] = {}
+        for cmd, offset, _ in self.load_commands():
+            if cmd != LC_SEGMENT_64:
+                continue
+            name = macho[offset + 8:offset + 24].rstrip(b"\x00").decode("ascii", "replace")
+            fileoff, filesize = struct.unpack_from("<QQ", macho, offset + 32)
+            if name == "__LINKEDIT":
+                continue
+            chunk = macho[fileoff:fileoff + filesize]
+            hashes[name] = hashlib.sha256(chunk).hexdigest()
+        return hashes
+
+    def code_signature(self) -> bytes | None:
+        macho = self._macho()
+        for cmd, offset, _ in self.load_commands():
+            if cmd == LC_CODE_SIGNATURE:
+                dataoff, datasize = struct.unpack_from("<II", macho, offset + 8)
+                return macho[dataoff:dataoff + datasize]
+        return None
+
+    def resource_seal_present(self) -> bool:
+        """The CodeDirectory has a non-zero hash in the resource-directory special slot."""
+        signature = self.code_signature()
+        if signature is None:
+            return False
+        directory = _code_directory(signature)
+        if directory is None:
+            return False
+        magic, length = struct.unpack_from(">II", directory, 0)
+        hash_offset, ident_offset, n_special = struct.unpack_from(">III", directory, 16)
+        hash_size = directory[36]
+        if n_special < CSSLOT_RESOURCEDIR:
+            return False
+        slot_start = hash_offset - CSSLOT_RESOURCEDIR * hash_size
+        seal = directory[slot_start:slot_start + hash_size]
+        return len(seal) == hash_size and any(seal)
+
+
+def _arm64_slice(data: bytes) -> tuple[int, int]:
+    (magic,) = struct.unpack_from(">I", data, 0)
+    if magic in (FAT_MAGIC, FAT_MAGIC_64):
+        count = struct.unpack_from(">I", data, 4)[0]
+        wide = magic == FAT_MAGIC_64
+        entry = 32 if wide else 20
+        for i in range(count):
+            base = 8 + i * entry
+            cputype = struct.unpack_from(">I", data, base)[0]
+            if wide:
+                offset, size = struct.unpack_from(">QQ", data, base + 8)
+            else:
+                offset, size = struct.unpack_from(">II", data, base + 8)
+            if cputype == CPU_TYPE_ARM64:
+                return offset, size
+        raise VerifyError("fat Mach-O has no arm64 slice")
+    return 0, len(data)
+
+
+def _code_directory(signature: bytes) -> bytes | None:
+    if len(signature) < 12 or struct.unpack_from(">I", signature, 0)[0] != CSMAGIC_EMBEDDED_SIGNATURE:
+        return None
+    count = struct.unpack_from(">I", signature, 8)[0]
+    for i in range(count):
+        slot_type, offset = struct.unpack_from(">II", signature, 12 + i * 8)
+        if slot_type == CSSLOT_CODEDIRECTORY:
+            return signature[offset:]
+    return None
+
+
+def is_macho(path: Path) -> bool:
+    try:
+        with path.open("rb") as handle:
+            head = handle.read(4)
+    except OSError:
+        return False
+    if len(head) < 4:
+        return False
+    magic_le = struct.unpack("<I", head)[0]
+    magic_be = struct.unpack(">I", head)[0]
+    return magic_le == MH_MAGIC_64 or magic_be in (FAT_MAGIC, FAT_MAGIC_64)
+
+
+# --- Artifact discovery and extraction ------------------------------------
+
+def find_artifacts(dist: Path) -> dict[str, Path]:
+    patterns = {"ipa": "*.ipa", "tipa": "*.tipa", "deb": "*.deb"}
+    found: dict[str, Path] = {}
+    problems = []
+    for kind, pattern in patterns.items():
+        matches = sorted(dist.glob(pattern))
+        if len(matches) != 1:
+            problems.append(f"expected exactly one {pattern} in {dist}, found {len(matches)}")
+        else:
+            found[kind] = matches[0]
+    if problems:
+        raise VerifyError("; ".join(problems))
+    return found
+
+
+def extract(artifact: Path, kind: str, dest: Path) -> Path:
+    if kind in ("ipa", "tipa"):
+        with zipfile.ZipFile(artifact) as archive:
+            names = archive.namelist()
+            archive.extractall(dest)
+        _stash_zip_names(dest, names)
+        return dest / "Payload" / "Eikon.app"
+    run("dpkg-deb", "-x", str(artifact), str(dest))
+    return dest / "var" / "jb" / "Applications" / "Eikon.app"
+
+
+def _stash_zip_names(dest: Path, names: list[str]) -> None:
+    (dest / ".zip-entries").write_text("\n".join(names), encoding="utf-8")
+
+
+def zip_entries(dest: Path) -> list[str]:
+    return (dest / ".zip-entries").read_text(encoding="utf-8").splitlines()
+
+
+# --- Checks ---------------------------------------------------------------
+
+def app_executable(app: Path) -> Path:
+    info = plistlib.loads((app / "Info.plist").read_bytes())
+    return app / info["CFBundleExecutable"]
+
+
+def read_info(app: Path) -> dict:
+    return plistlib.loads((app / "Info.plist").read_bytes())
+
+
+def check_layout(kind: str, dest: Path, app: Path) -> list[str]:
+    problems: list[str] = []
+    if kind in ("ipa", "tipa"):
+        for name in zip_entries(dest):
+            top = name.split("/", 1)[0]
+            if top not in ("Payload", "") and not name.startswith("Payload/"):
+                problems.append(f"{kind}: entry outside Payload/: {name}")
+    else:
+        allowed_top = {".", "var"}
+        for path in dest.rglob("*"):
+            if path.name == ".zip-entries":
+                continue
+            rel = path.relative_to(dest)
+            if rel.parts and rel.parts[0] not in allowed_top:
+                problems.append(f"deb: path outside var/jb/: {rel}")
+                break
+    return problems
+
+
+def check_deb_control(deb: Path, app: Path, version: str) -> list[str]:
+    fields = {}
+    for line in run("dpkg-deb", "-f", str(deb)).decode().splitlines():
+        if ":" in line:
+            key, _, value = line.partition(":")
+            fields[key.strip()] = value.strip()
+    info = read_info(app)
+    problems = []
+    if fields.get("Architecture") != "iphoneos-arm64":
+        problems.append(f"deb: Architecture is {fields.get('Architecture')!r}, expected iphoneos-arm64")
+    if fields.get("Package") != info.get("CFBundleIdentifier"):
+        problems.append(f"deb: Package {fields.get('Package')!r} != bundle id {info.get('CFBundleIdentifier')!r}")
+    if fields.get("Version") != version:
+        problems.append(f"deb: Version {fields.get('Version')!r} != VERSION {version!r}")
+    return problems
+
+
+def check_version_and_stamp(kind: str, app: Path, version: str) -> list[str]:
+    info = read_info(app)
+    problems = []
+    if info.get("CFBundleShortVersionString") != version:
+        problems.append(f"{kind}: CFBundleShortVersionString {info.get('CFBundleShortVersionString')!r} != {version!r}")
+    if info.get("EKPackageKind") != kind:
+        problems.append(f"{kind}: EKPackageKind {info.get('EKPackageKind')!r} != {kind!r}")
+    return problems
+
+
+def check_hygiene(kind: str, dest: Path, app: Path) -> list[str]:
+    problems = []
+    names = zip_entries(dest) if kind in ("ipa", "tipa") else [
+        str(p.relative_to(dest)) for p in dest.rglob("*") if p.name != ".zip-entries"
+    ]
+    for name in names:
+        base = name.rstrip("/").rsplit("/", 1)[-1]
+        if base.startswith("._") or base == ".DS_Store" or name.startswith("__MACOSX/") or "/__MACOSX/" in name:
+            problems.append(f"{kind}: junk file {name}")
+    return problems
+
+
+def entitlements_of(executable: Path) -> dict:
+    output = run("ldid", "-e", str(executable))
+    if not output.strip():
+        return {}
+    return plistlib.loads(output)
+
+
+def check_signature(kind: str, app: Path, expected: dict) -> list[str]:
+    problems: list[str] = []
+    executable = app_executable(app)
+    entitlements = entitlements_of(executable)
+
+    for key, value in expected.items():
+        if entitlements.get(key) != value:
+            problems.append(f"{kind}: missing/wrong entitlement {key}={value!r} (got {entitlements.get(key)!r})")
+    for key in FORBIDDEN:
+        if key in entitlements:
+            problems.append(f"{kind}: forbidden entitlement {key}")
+
+    macho = MachO(executable)
+    if not macho.resource_seal_present():
+        problems.append(f"{kind}: main executable has no sealed resource directory")
+    if not (app / "_CodeSignature" / "CodeResources").is_file():
+        problems.append(f"{kind}: bundle has no _CodeSignature/CodeResources")
+
+    for path in app.rglob("*"):
+        if path.is_file() and path != executable and is_macho(path):
+            nested = MachO(path)
+            if nested.code_signature() is None:
+                problems.append(f"{kind}: nested Mach-O not signed: {path.relative_to(app)}")
+            if entitlements_of(path):
+                problems.append(f"{kind}: nested Mach-O carries entitlements: {path.relative_to(app)}")
+    return problems
+
+
+
+# --- Driver ---------------------------------------------------------------
+
+def main(argv: list[str]) -> int:
+    if len(argv) != 1:
+        print("usage: verify_artifacts.py <dist-dir>", file=sys.stderr)
+        return 2
+    dist = Path(argv[0])
+    version = (ROOT / "VERSION").read_text().strip()
+
+    try:
+        artifacts = find_artifacts(dist)
+        expected = {kind: plistlib.loads((ENTITLEMENTS_DIR / f"{kind}.plist").read_bytes())
+                    for kind in artifacts}
+    except (VerifyError, OSError) as error:
+        print(f"verify: {error}", file=sys.stderr)
+        return 1
+
+    problems: list[str] = []
+    identities: dict[str, tuple[bytes | None, dict[str, str], str]] = {}
+    build_versions: dict[str, str] = {}
+
+    with tempfile.TemporaryDirectory() as tmp:
+        for kind, artifact in artifacts.items():
+            dest = Path(tmp) / kind
+            dest.mkdir()
+            try:
+                app = extract(artifact, kind, dest)
+                if not app.is_dir():
+                    problems.append(f"{kind}: no Eikon.app in {artifact.name}")
+                    continue
+                problems += check_layout(kind, dest, app)
+                if kind == "deb":
+                    problems += check_deb_control(artifact, app, version)
+                problems += check_version_and_stamp(kind, app, version)
+                problems += check_hygiene(kind, dest, app)
+                problems += check_signature(kind, app, expected[kind])
+                executable = app_executable(app)
+                macho = MachO(executable)
+                identities[kind] = (macho.uuid(), macho.segment_hashes(), artifact.name)
+                build_versions[kind] = read_info(app).get("CFBundleVersion", "")
+            except (VerifyError, OSError, KeyError) as error:
+                problems.append(f"{kind}: {error}")
+
+        problems += compare_binaries(identities)
+        if len(set(build_versions.values())) > 1:
+            problems.append(f"CFBundleVersion differs across artifacts: {build_versions}")
+
+    if problems:
+        for problem in problems:
+            print(f"verify: {problem}", file=sys.stderr)
+        return 1
+
+    print(f"verify: {', '.join(a.name for a in artifacts.values())} — same binary, version {version}, OK")
+    return 0
+
+
+def compare_binaries(identities: dict[str, tuple[bytes | None, dict[str, str], str]]) -> list[str]:
+    if len(identities) < 2:
+        return []
+    problems = []
+    uuids = {kind: uuid for kind, (uuid, _, _) in identities.items()}
+    if len(set(uuids.values())) != 1 or None in uuids.values():
+        problems.append(f"main executables have different LC_UUID: {uuids}")
+    segment_names = set().union(*(hashes.keys() for _, hashes, _ in identities.values()))
+    for name in sorted(segment_names):
+        values = {kind: hashes.get(name) for kind, (_, hashes, _) in identities.items()}
+        if len(set(values.values())) != 1:
+            problems.append(f"segment {name} differs across artifacts: {values}")
+    return problems
+
+
+if __name__ == "__main__":
+    sys.exit(main(sys.argv[1:]))
