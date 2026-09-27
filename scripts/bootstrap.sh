#!/bin/bash
# Install the missing build tools with Homebrew, then run doctor. macOS only.
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

to_install=()
# ldid is checked by formula: another ldid on PATH must not stand in for it.
if ! brew list --formula ldid-procursus >/dev/null 2>&1; then
	to_install+=(ldid-procursus)
fi

# tool:formula pairs
wanted="xcodegen:xcodegen dpkg-deb:dpkg uv:uv gh:gh zstd:zstd xz:xz"
for pair in $wanted; do
	tool=${pair%%:*}
	formula=${pair#*:}
	if ! command -v "$tool" >/dev/null 2>&1; then
		to_install+=("$formula")
	fi
done

if [ ${#to_install[@]} -gt 0 ]; then
	echo "+ brew install ${to_install[*]}"
	brew install "${to_install[@]}"
else
	echo "Nothing to install."
fi

exec "$here/doctor.sh"
