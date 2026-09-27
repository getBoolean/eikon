#!/bin/bash
# Check that the tools Eikon's build needs are installed. macOS only.
# Prints one line per tool and exits non-zero if anything is missing.
# Never installs anything; see scripts/bootstrap.sh (make bootstrap).
set -uo pipefail

failed=0

ok() { printf '  ok       %-12s %s\n' "$1" "$2"; }
warn() { printf '  warning  %-12s %s\n' "$1" "$2"; }
missing() {
	printf '  MISSING  %-12s %s\n' "$1" "$2"
	failed=1
}

have() { command -v "$1" >/dev/null 2>&1; }

check_brew_tool() {
	local tool=$1 formula=$2
	if have "$tool"; then
		ok "$tool" "$(command -v "$tool")"
	else
		missing "$tool" "brew install $formula (or make bootstrap)"
	fi
}

echo "Eikon build tools:"

# Xcode and the iOS SDK.
if xcode-select -p >/dev/null 2>&1 && xcodebuild -version >/dev/null 2>&1; then
	if sdk=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null) && [ -n "$sdk" ]; then
		ok xcode "$(xcodebuild -version | head -n 1), $(basename "$sdk")"
	else
		missing xcode "no iphoneos SDK found; install the iOS platform in Xcode settings"
	fi
else
	missing xcode "install Xcode from the App Store, then run xcode-select -s /Applications/Xcode.app"
fi

check_brew_tool xcodegen xcodegen

# ldid must be the Procursus build; Homebrew's "ldid" formula is an older one.
if have ldid; then
	ldid_out=$( { ldid 2>&1; ldid --version 2>&1; } || true)
	if printf '%s' "$ldid_out" | grep -qi procursus ||
		printf '%s' "$ldid_out" | grep -Eq -- '(^|[[:space:]])-M([[:space:]]|$)'; then
		ok ldid "$(command -v ldid) (Procursus)"
	else
		missing ldid "$(command -v ldid) is not the Procursus ldid; brew uninstall ldid, then brew install ldid-procursus"
	fi
else
	missing ldid "brew install ldid-procursus (or make bootstrap)"
fi

check_brew_tool dpkg-deb dpkg
check_brew_tool uv uv
check_brew_tool gh gh
check_brew_tool zstd zstd
check_brew_tool xz xz

# Python comes through uv; a missing interpreter is downloaded on first use.
if have uv; then
	if py=$(uv python find 3.12 2>/dev/null); then
		ok python3.12 "$py (via uv)"
	else
		warn python3.12 "not installed yet; uv run downloads it on first use"
	fi
else
	warn python3.12 "can't check without uv"
fi

if [ "$failed" -ne 0 ]; then
	echo "Some tools are missing. Install them, or run make bootstrap."
	exit 1
fi
echo "All tools found."
