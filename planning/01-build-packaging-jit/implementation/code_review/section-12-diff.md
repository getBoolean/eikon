diff --git a/.github/workflows/release.yml b/.github/workflows/release.yml
new file mode 100644
index 0000000..0f56473
--- /dev/null
+++ b/.github/workflows/release.yml
@@ -0,0 +1,152 @@
+name: release
+
+on:
+  push:
+    tags:
+      - 'v*'
+
+permissions:
+  contents: read
+
+# Two tags must not race on eikon-source; queue rather than cancel.
+concurrency:
+  group: publish
+  cancel-in-progress: false
+
+jobs:
+  build:
+    runs-on: macos-latest
+    timeout-minutes: 60
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
+        run: |
+          brew list --formula ldid >/dev/null 2>&1 && brew uninstall --ignore-dependencies ldid || true
+          brew install xcodegen ldid-procursus dpkg uv
+      - name: Tag guard
+        run: scripts/version.sh --check-tag "$GITHUB_REF_NAME"
+      - name: Build, package and verify
+        run: make all
+      - name: Upload artifacts
+        uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1
+        with:
+          name: eikon-dist
+          path: dist/
+
+  release:
+    needs: build
+    runs-on: ubuntu-latest
+    permissions:
+      contents: write
+    steps:
+      - uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1
+        with:
+          name: eikon-dist
+          path: dist
+      - name: Create the release
+        env:
+          GH_TOKEN: ${{ github.token }}
+          TAG: ${{ github.ref_name }}
+        run: |
+          notes=$(cat <<'EOF'
+          Eikon ${{ github.ref_name }} — an early prototype that reports whether JIT is usable and shows device status. It does not run anything yet.
+
+          Install: the deb is for Dopamine (rootless); the .tipa is for TrollStore and needs Developer Mode on iOS 16+; the .ipa is for AltStore. Each carries the same binary, signed with its own entitlements.
+          EOF
+          )
+          # Fails if a release for this tag already exists. Assets are never replaced.
+          gh release create "$TAG" --repo "$GITHUB_REPOSITORY" --title "$TAG" --notes "$notes" \
+            dist/Eikon-*.ipa dist/Eikon-*.tipa dist/*.deb dist/SHA256SUMS
+
+  publish:
+    needs: release
+    runs-on: ubuntu-latest
+    environment: eikon-source
+    permissions:
+      contents: read
+    steps:
+      - name: Check for the deploy key
+        id: secret
+        env:
+          DEPLOY_KEY: ${{ secrets.EIKON_SOURCE_DEPLOY_KEY }}
+        run: |
+          if [ -z "$DEPLOY_KEY" ]; then
+            echo "Publishing skipped: EIKON_SOURCE_DEPLOY_KEY is not configured." >&2
+            echo "Use scripts/repo/publish.sh as the local fallback." >&2
+            echo "present=false" >> "$GITHUB_OUTPUT"
+          else
+            echo "present=true" >> "$GITHUB_OUTPUT"
+          fi
+      - name: Check out eikon
+        if: steps.secret.outputs.present == 'true'
+        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
+        with:
+          fetch-depth: 0
+          path: eikon
+      - name: Check out eikon-source
+        if: steps.secret.outputs.present == 'true'
+        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
+        with:
+          repository: getBoolean/eikon-source
+          ssh-key: ${{ secrets.EIKON_SOURCE_DEPLOY_KEY }}
+          path: eikon-source
+      - uses: astral-sh/setup-uv@c18668ad3cf93ea998bef934396af7bb5c839dc7 # v10.2.0
+        if: steps.secret.outputs.present == 'true'
+      - name: Download the deb from the release asset
+        if: steps.secret.outputs.present == 'true'
+        env:
+          TAG: ${{ github.ref_name }}
+        run: |
+          version=$(tr -d '[:space:]' < eikon/VERSION)
+          deb="com.getboolean.eikon_${version}_iphoneos-arm64.deb"
+          base="https://github.com/${GITHUB_REPOSITORY}/releases/download/${TAG}"
+          url="$base/$deb"
+          mkdir -p work
+          curl -fL --retry 3 -o "work/$deb" "$url"
+          # Verify the downloaded bytes against the release's own SHA256SUMS
+          # before indexing them, so a corrupt or partial download can't be published.
+          curl -fL --retry 3 -o work/SHA256SUMS "$base/SHA256SUMS"
+          ( cd work && grep "  $deb\$" SHA256SUMS | sha256sum -c - )
+          echo "ASSET_URL=$url" >> "$GITHUB_ENV"
+          echo "DEB_PATH=$PWD/work/$deb" >> "$GITHUB_ENV"
+      - name: Build the index
+        if: steps.secret.outputs.present == 'true'
+        run: |
+          cd eikon
+          uv run scripts/repo/build_index.py \
+            --deb "$DEB_PATH" \
+            --asset-url "$ASSET_URL" \
+            --out "$GITHUB_WORKSPACE/eikon-source/docs" \
+            --filename-mode absolute \
+            --repo-readme "$GITHUB_WORKSPACE/eikon-source/README.md"
+      - name: Commit and push
+        if: steps.secret.outputs.present == 'true'
+        run: |
+          cd eikon-source
+          git config user.name "github-actions[bot]"
+          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
+          git add -A
+          if git diff --cached --quiet; then
+            echo "No index changes to publish."
+          else
+            version=$(tr -d '[:space:]' < "$GITHUB_WORKSPACE/eikon/VERSION")
+            git commit -m "Publish com.getboolean.eikon $version"
+            git push origin HEAD:main
+          fi
