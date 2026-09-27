#!/bin/bash
# Install the missing build tools with Homebrew, bring the ones Homebrew
# already manages up to date, then run doctor. macOS only.
# Run only when the owner asks for it (make bootstrap); nothing else calls it.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)

if ! command -v brew >/dev/null 2>&1; then
	echo "bootstrap.sh: Homebrew is required; install it from https://brew.sh" >&2
	exit 1
fi

if ! xcode-select -p >/dev/null 2>&1; then
	echo "bootstrap.sh: Xcode is missing and can't be installed here; install it from the App Store." >&2
fi

if brew list --formula ldid >/dev/null 2>&1; then
	echo "warning: the Homebrew 'ldid' formula is installed and conflicts with ldid-procursus." >&2
	echo "         Run 'brew uninstall ldid' first; this script does not uninstall anything." >&2
fi

# tool:formula pairs. ldid has no tool check: only the ldid-procursus formula
# counts, so another ldid on PATH can't stand in for it.
wanted="xcodegen:xcodegen -:ldid-procursus dpkg-deb:dpkg uv:uv gh:gh zstd:zstd xz:xz"
to_install=()
to_upgrade=()
for pair in $wanted; do
	tool=${pair%%:*}
	formula=${pair#*:}
	if brew list --formula "$formula" >/dev/null 2>&1; then
		to_upgrade+=("$formula")
	elif [ "$tool" = "-" ] || ! command -v "$tool" >/dev/null 2>&1; then
		to_install+=("$formula")
	fi
	# A tool on PATH that Homebrew doesn't manage is left alone.
done

# Refresh the formula index first so the newest versions are installed.
echo "+ brew update"
brew update

if [ ${#to_install[@]} -gt 0 ]; then
	echo "+ brew install ${to_install[*]}"
	brew install "${to_install[@]}"
fi

if [ ${#to_upgrade[@]} -gt 0 ]; then
	echo "+ brew upgrade ${to_upgrade[*]}"
	brew upgrade "${to_upgrade[@]}"
fi

exec "$here/doctor.sh"
