diff --git a/.github/workflows/ci.yml b/.github/workflows/ci.yml
new file mode 100644
index 0000000..1d5a362
--- /dev/null
+++ b/.github/workflows/ci.yml
@@ -0,0 +1,49 @@
+name: CI
+
+on:
+  push:
+  pull_request:
+
+# This workflow never publishes or writes anything.
+permissions:
+  contents: read
+
+jobs:
+  scripts:
+    runs-on: ubuntu-latest
+    steps:
+      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
+        with:
+          # version.sh counts commits and refuses a shallow clone.
+          fetch-depth: 0
+      - uses: astral-sh/setup-uv@c18668ad3cf93ea998bef934396af7bb5c839dc7 # v10.2.0
+      - name: Script tests
+        run: uv run pytest tests/
+      - name: Version check
+        run: scripts/version.sh --check
+
+  build:
+    runs-on: macos-latest
+    steps:
+      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
+        with:
+          fetch-depth: 0
+      - name: Select the newest Xcode
+        run: |
+          best=""
+          best_version=""
+          for app in /Applications/Xcode*.app; do
+            [ -d "$app" ] || continue
+            version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null) || continue
+            if [ -z "$best" ] || [ "$(printf '%s\n%s\n' "$best_version" "$version" | sort -V | tail -n 1)" = "$version" ]; then
+              best=$app
+              best_version=$version
+            fi
+          done
+          [ -n "$best" ] || { echo "No Xcode found in /Applications" >&2; exit 1; }
+          echo "DEVELOPER_DIR=$best/Contents/Developer" >> "$GITHUB_ENV"
+          DEVELOPER_DIR="$best/Contents/Developer" xcodebuild -version
+      - name: Install tools
+        run: brew install xcodegen uv
+      - name: Swift tests and launch check
+        run: make test-swift
diff --git a/.gitignore b/.gitignore
index 7793b4c..6eb835c 100644
--- a/.gitignore
+++ b/.gitignore
@@ -11,6 +11,9 @@ dist/
 *.xcodeproj
 DerivedData/
 
+# Per-developer signing settings
+Config/Local.xcconfig
+
 # Python
 .venv/
 __pycache__/
diff --git a/App/Assets.xcassets/AppIcon.appiconset/Contents.json b/App/Assets.xcassets/AppIcon.appiconset/Contents.json
new file mode 100644
index 0000000..cefcc87
--- /dev/null
+++ b/App/Assets.xcassets/AppIcon.appiconset/Contents.json
@@ -0,0 +1,14 @@
+{
+  "images" : [
+    {
+      "filename" : "AppIcon.png",
+      "idiom" : "universal",
+      "platform" : "ios",
+      "size" : "1024x1024"
+    }
+  ],
+  "info" : {
+    "author" : "xcode",
+    "version" : 1
+  }
+}
diff --git a/App/Assets.xcassets/Contents.json b/App/Assets.xcassets/Contents.json
new file mode 100644
index 0000000..73c0059
--- /dev/null
+++ b/App/Assets.xcassets/Contents.json
@@ -0,0 +1,6 @@
+{
+  "info" : {
+    "author" : "xcode",
+    "version" : 1
+  }
+}
diff --git a/App/EikonApp.swift b/App/EikonApp.swift
new file mode 100644
index 0000000..0566bde
--- /dev/null
+++ b/App/EikonApp.swift
@@ -0,0 +1,10 @@
+import SwiftUI
+
+@main
+struct EikonApp: App {
+    var body: some Scene {
+        WindowGroup {
+            StatusView()
+        }
+    }
+}
diff --git a/App/Info.plist b/App/Info.plist
new file mode 100644
index 0000000..303de15
--- /dev/null
+++ b/App/Info.plist
@@ -0,0 +1,51 @@
+<?xml version="1.0" encoding="UTF-8"?>
+<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
+<plist version="1.0">
+<dict>
+	<key>CFBundleDevelopmentRegion</key>
+	<string>$(DEVELOPMENT_LANGUAGE)</string>
+	<key>CFBundleDisplayName</key>
+	<string>Eikon</string>
+	<key>CFBundleExecutable</key>
+	<string>$(EXECUTABLE_NAME)</string>
+	<key>CFBundleIdentifier</key>
+	<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
+	<key>CFBundleInfoDictionaryVersion</key>
+	<string>6.0</string>
+	<key>CFBundleName</key>
+	<string>$(PRODUCT_NAME)</string>
+	<key>CFBundlePackageType</key>
+	<string>$(PRODUCT_BUNDLE_PACKAGE_TYPE)</string>
+	<key>CFBundleShortVersionString</key>
+	<string>$(MARKETING_VERSION)</string>
+	<key>CFBundleVersion</key>
+	<string>$(CURRENT_PROJECT_VERSION)</string>
+	<key>EKGitCommit</key>
+	<string>$(EIKON_GIT_COMMIT)</string>
+	<key>EKPackageKind</key>
+	<string>development</string>
+	<key>LSRequiresIPhoneOS</key>
+	<true/>
+	<key>UIApplicationSceneManifest</key>
+	<dict>
+		<key>UIApplicationSupportsMultipleScenes</key>
+		<false/>
+	</dict>
+	<key>UILaunchScreen</key>
+	<dict/>
+	<key>UISupportedInterfaceOrientations</key>
+	<array>
+		<string>UIInterfaceOrientationPortrait</string>
+		<string>UIInterfaceOrientationPortraitUpsideDown</string>
+		<string>UIInterfaceOrientationLandscapeLeft</string>
+		<string>UIInterfaceOrientationLandscapeRight</string>
+	</array>
+	<key>UISupportedInterfaceOrientations~ipad</key>
+	<array>
+		<string>UIInterfaceOrientationPortrait</string>
+		<string>UIInterfaceOrientationPortraitUpsideDown</string>
+		<string>UIInterfaceOrientationLandscapeLeft</string>
+		<string>UIInterfaceOrientationLandscapeRight</string>
+	</array>
+</dict>
+</plist>
diff --git a/App/Resources/Acknowledgements.json b/App/Resources/Acknowledgements.json
new file mode 100644
index 0000000..fe51488
--- /dev/null
+++ b/App/Resources/Acknowledgements.json
@@ -0,0 +1 @@
+[]
diff --git a/App/StatusView.swift b/App/StatusView.swift
new file mode 100644
index 0000000..bb59371
--- /dev/null
+++ b/App/StatusView.swift
@@ -0,0 +1,35 @@
+import SwiftUI
+
+/// Placeholder status screen: shows the version stamps from the Info.plist so
+/// they can be checked by eye. Section 09 replaces it.
+struct StatusView: View {
+    private let info = Bundle.main.infoDictionary ?? [:]
+
+    var body: some View {
+        NavigationView {
+            List {
+                row("Version", value("CFBundleShortVersionString"))
+                row("Build", value("CFBundleVersion"))
+                row("Commit", value("EKGitCommit"))
+                row("Package kind", value("EKPackageKind"))
+                row("Bundle ID", Bundle.main.bundleIdentifier ?? "–")
+            }
+            .navigationTitle("Eikon")
+        }
+        .navigationViewStyle(.stack)
+    }
+
+    private func value(_ key: String) -> String {
+        (info[key] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "–"
+    }
+
+    private func row(_ label: String, _ value: String) -> some View {
+        HStack {
+            Text(label)
+            Spacer()
+            Text(value)
+                .foregroundColor(.secondary)
+                .textSelection(.enabled)
+        }
+    }
+}
diff --git a/Config/Base.xcconfig b/Config/Base.xcconfig
new file mode 100644
index 0000000..bfcf6ae
--- /dev/null
+++ b/Config/Base.xcconfig
@@ -0,0 +1,32 @@
+// Settings shared by every configuration. Keep build settings here rather
+// than in project.yml, so the project and the target read the same values.
+
+// Fallback version values, so the project builds before `make version` has run.
+MARKETING_VERSION = 0.0.0
+CURRENT_PROJECT_VERSION = 0
+EIKON_GIT_COMMIT = unknown
+
+// Generated by scripts/version.sh; included after the fallbacks so it wins.
+#include? "../build/generated/Version.xcconfig"
+
+SDKROOT = iphoneos
+SUPPORTED_PLATFORMS = iphoneos iphonesimulator
+IPHONEOS_DEPLOYMENT_TARGET = 15.0
+TARGETED_DEVICE_FAMILY = 1,2
+ARCHS = arm64
+SWIFT_VERSION = 6.0
+SWIFT_STRICT_CONCURRENCY = complete
+
+PRODUCT_BUNDLE_IDENTIFIER = com.getboolean.eikon
+PRODUCT_NAME = Eikon
+
+GENERATE_INFOPLIST_FILE = NO
+INFOPLIST_FILE = App/Info.plist
+
+ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon
+LD_RUNPATH_SEARCH_PATHS = @executable_path/Frameworks
+
+CODE_SIGN_STYLE = Automatic
+
+// Untracked, per developer: DEVELOPMENT_TEAM for device debug runs.
+#include? "Local.xcconfig"
diff --git a/Config/Debug.xcconfig b/Config/Debug.xcconfig
new file mode 100644
index 0000000..67122b6
--- /dev/null
+++ b/Config/Debug.xcconfig
@@ -0,0 +1,9 @@
+#include "Base.xcconfig"
+
+SWIFT_OPTIMIZATION_LEVEL = -Onone
+SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG
+GCC_OPTIMIZATION_LEVEL = 0
+GCC_PREPROCESSOR_DEFINITIONS = DEBUG=1
+DEBUG_INFORMATION_FORMAT = dwarf
+ONLY_ACTIVE_ARCH = YES
+ENABLE_TESTABILITY = YES
diff --git a/Config/Release.xcconfig b/Config/Release.xcconfig
new file mode 100644
index 0000000..71578a8
--- /dev/null
+++ b/Config/Release.xcconfig
@@ -0,0 +1,7 @@
+#include "Base.xcconfig"
+
+SWIFT_OPTIMIZATION_LEVEL = -O
+SWIFT_COMPILATION_MODE = wholemodule
+GCC_OPTIMIZATION_LEVEL = s
+DEBUG_INFORMATION_FORMAT = dwarf-with-dsym
+VALIDATE_PRODUCT = YES
diff --git a/Makefile b/Makefile
index b29edc5..e0baa74 100644
--- a/Makefile
+++ b/Makefile
@@ -33,8 +33,9 @@ generated: version
 		echo "generated: skipping acknowledgements, scripts/credits.py not added yet (section 04)"; \
 	fi
 
-project: generated
-	@$(call stub,02)
+# Section 04 inserts the acknowledgements step (generated) before xcodegen.
+project: version
+	@xcodegen generate --quiet
 
 check:
 	@if [ -f scripts/credits.py ]; then \
@@ -46,12 +47,8 @@ check:
 
 test: test-swift test-scripts
 
-test-swift:
-	@if [ -f project.yml ]; then \
-		$(call stub,02); \
-	else \
-		echo "test-swift: skipping, project.yml not added yet (section 02)"; \
-	fi
+test-swift: project
+	@scripts/test_swift.sh
 
 test-scripts:
 	@uv run pytest tests/
diff --git a/Packages/EikonKit/Package.swift b/Packages/EikonKit/Package.swift
new file mode 100644
index 0000000..15f15f8
--- /dev/null
+++ b/Packages/EikonKit/Package.swift
@@ -0,0 +1,16 @@
+// swift-tools-version:6.0
+import PackageDescription
+
+let package = Package(
+    name: "EikonKit",
+    platforms: [.iOS(.v15)],
+    products: [
+        .library(name: "EikonKit", targets: ["EikonKit"]),
+    ],
+    targets: [
+        .target(name: "CEikonJIT"),
+        .target(name: "EikonKit", dependencies: ["CEikonJIT"]),
+        .testTarget(name: "EikonKitTests", dependencies: ["EikonKit"]),
+    ],
+    swiftLanguageModes: [.v6]
+)
diff --git a/Packages/EikonKit/Sources/CEikonJIT/CEikonJIT.c b/Packages/EikonKit/Sources/CEikonJIT/CEikonJIT.c
new file mode 100644
index 0000000..4321756
--- /dev/null
+++ b/Packages/EikonKit/Sources/CEikonJIT/CEikonJIT.c
@@ -0,0 +1 @@
+#include "CEikonJIT.h"
diff --git a/Packages/EikonKit/Sources/CEikonJIT/include/CEikonJIT.h b/Packages/EikonKit/Sources/CEikonJIT/include/CEikonJIT.h
new file mode 100644
index 0000000..bed8bad
--- /dev/null
+++ b/Packages/EikonKit/Sources/CEikonJIT/include/CEikonJIT.h
@@ -0,0 +1,7 @@
+#ifndef CEIKONJIT_H
+#define CEIKONJIT_H
+
+// Low-level C helpers for Eikon's JIT detection: code-signing flags, the JIT
+// probe and the TXM firmware check. Later sections add them here.
+
+#endif /* CEIKONJIT_H */
diff --git a/Packages/EikonKit/Sources/EikonKit/EikonKit.swift b/Packages/EikonKit/Sources/EikonKit/EikonKit.swift
new file mode 100644
index 0000000..6297b18
--- /dev/null
+++ b/Packages/EikonKit/Sources/EikonKit/EikonKit.swift
@@ -0,0 +1,2 @@
+/// EikonKit is Eikon's testable core: install detection, JIT policy and the
+/// device report. The app target stays a thin SwiftUI shell over it.
diff --git a/Packages/EikonKit/Tests/EikonKitTests/SmokeTests.swift b/Packages/EikonKit/Tests/EikonKitTests/SmokeTests.swift
new file mode 100644
index 0000000..43ea27d
--- /dev/null
+++ b/Packages/EikonKit/Tests/EikonKitTests/SmokeTests.swift
@@ -0,0 +1,6 @@
+import Testing
+@testable import EikonKit
+
+/// Proves the test target builds, links EikonKit, and runs on the simulator.
+/// Section 05 deletes this file when it adds real tests.
+@Test func packageLinks() { #expect(Bool(true)) }
diff --git a/README.md b/README.md
index e0499cc..e366ee0 100644
--- a/README.md
+++ b/README.md
@@ -39,7 +39,25 @@ The main targets:
 - `verify`: check the packaged artifacts
 - `clean`: remove `build/` and `dist/`
 
-`make all` builds one app binary and packages it three ways. The `.xcodeproj` is generated by XcodeGen and not committed.
+`make all` builds one app binary and packages it three ways.
+
+`make doctor` checks the toolchain. `make bootstrap` installs missing tools; run it only when you choose to.
+
+`make project` generates `Eikon.xcodeproj` with XcodeGen. The project is never committed: edit `project.yml` and the files in `Config/`, then regenerate.
+
+`make test-swift` runs the Swift tests, then installs and launches the app on the newest iPhone simulator. To pick a different simulator, set `EIKON_SIM_DESTINATION` to an `xcodebuild -destination` value.
+
+For debug runs on a device, create `Config/Local.xcconfig` (untracked) containing `DEVELOPMENT_TEAM = <your team id>`.
+
+### Debug loop
+
+When Eikon runs from Xcode on a device with the debugger attached, the kernel sets `CS_DEBUGGED` on the process. That exercises the real JIT probe without TrollStore.
+
+The probe deliberately triggers signals and handles them itself, but lldb stops on them by default. To let the probe's handler deal with them, run this in lldb, or put it in a `.lldbinit`:
+
+```
+process handle SIGBUS SIGSEGV SIGILL SIGTRAP -s false -n false
+```
 
 ## Install methods and artifacts
 
diff --git a/project.yml b/project.yml
new file mode 100644
index 0000000..6b15f17
--- /dev/null
+++ b/project.yml
@@ -0,0 +1,39 @@
+name: Eikon
+options:
+  deploymentTarget:
+    iOS: "15.0"
+  createIntermediateGroups: true
+  # Only project-level presets: target presets would override the xcconfigs.
+  settingPresets: project
+configFiles:
+  Debug: Config/Debug.xcconfig
+  Release: Config/Release.xcconfig
+packages:
+  EikonKit:
+    path: Packages/EikonKit
+targets:
+  Eikon:
+    type: application
+    platform: iOS
+    configFiles:
+      Debug: Config/Debug.xcconfig
+      Release: Config/Release.xcconfig
+    sources:
+      - path: App
+    dependencies:
+      - package: EikonKit
+        product: EikonKit
+    # No preBuildScripts or postBuildScripts: nothing runs in a build phase.
+schemes:
+  Eikon:
+    build:
+      targets:
+        Eikon: all
+    test:
+      config: Debug
+      targets:
+        - package: EikonKit/EikonKitTests
+    run:
+      config: Debug
+    archive:
+      config: Release
diff --git a/scripts/bootstrap.sh b/scripts/bootstrap.sh
index 6096100..a63e662 100755
--- a/scripts/bootstrap.sh
+++ b/scripts/bootstrap.sh
@@ -36,6 +36,9 @@ for pair in $wanted; do
 done
 
 if [ ${#to_install[@]} -gt 0 ]; then
+	# Refresh the formula index first so the newest versions are installed.
+	echo "+ brew update"
+	brew update
 	echo "+ brew install ${to_install[*]}"
 	brew install "${to_install[@]}"
 else
diff --git a/scripts/test_swift.sh b/scripts/test_swift.sh
new file mode 100755
index 0000000..d630c1c
--- /dev/null
+++ b/scripts/test_swift.sh
@@ -0,0 +1,76 @@
+#!/bin/bash
+# Run the Swift tests on the newest iPhone simulator, then install and launch
+# the app there and check that it stays running. Called by `make test-swift`.
+#
+#   EIKON_SIM_DESTINATION  an xcodebuild -destination value to use instead
+set -euo pipefail
+
+root=$(cd "$(dirname "$0")/.." && pwd)
+cd "$root"
+
+die() {
+	echo "test_swift.sh: $*" >&2
+	exit 1
+}
+
+derived=build/DerivedData
+
+# 1. Pick the simulator.
+if [ -n "${EIKON_SIM_DESTINATION:-}" ]; then
+	destination=$EIKON_SIM_DESTINATION
+	udid=$(printf '%s\n' "$destination" | sed -n 's/.*id=\([0-9A-Fa-f-]*\).*/\1/p')
+else
+	devices_json=$(xcrun simctl list devices available --json)
+	udid=$(printf '%s' "$devices_json" | uv run --no-project python -c '
+import json, re, sys
+
+devices = json.load(sys.stdin)["devices"]
+best = None
+for runtime, entries in devices.items():
+    m = re.search(r"\.iOS-(\d+(?:-\d+)*)$", runtime)
+    if not m:
+        continue
+    version = tuple(int(p) for p in m.group(1).split("-"))
+    for d in entries:
+        if d.get("isAvailable") and d["name"].startswith("iPhone"):
+            key = (version, d["name"])
+            if best is None or key > best[0]:
+                best = (key, d["udid"])
+if best:
+    print(best[1])
+')
+	[ -n "$udid" ] || die "no iPhone simulator available; install an iOS simulator runtime in Xcode (Settings > Components)"
+	destination="platform=iOS Simulator,id=$udid"
+fi
+echo "Destination: $destination"
+
+# 2. Build and test.
+xcrun xcodebuild test \
+	-project Eikon.xcodeproj \
+	-scheme Eikon \
+	-destination "$destination" \
+	-derivedDataPath "$derived" \
+	CODE_SIGNING_ALLOWED=NO
+
+# 3. Launch check.
+if [ -z "$udid" ]; then
+	echo "Skipping the launch check: EIKON_SIM_DESTINATION has no id=<udid>."
+	exit 0
+fi
+
+app="$derived/Build/Products/Debug-iphonesimulator/Eikon.app"
+[ -d "$app" ] || die "built app not found at $app"
+bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")
+
+xcrun simctl boot "$udid" 2>/dev/null || true
+xcrun simctl bootstatus "$udid" -b >/dev/null
+xcrun simctl install "$udid" "$app"
+xcrun simctl launch "$udid" "$bundle_id" >/dev/null
+sleep 5
+if ! xcrun simctl spawn "$udid" launchctl list | grep -q "UIKitApplication:$bundle_id"; then
+	die "$bundle_id exited right after launch"
+fi
+xcrun simctl terminate "$udid" "$bundle_id" || true
+
+# 4. Summary.
+echo "test-swift: tests passed and $bundle_id launched on $destination"
