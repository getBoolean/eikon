#!/bin/bash
# Local fallback publisher for the eikon-source Sileo repo. CI is canonical.
#
#   scripts/repo/publish.sh [--dry-run] [--filename-mode absolute|relative]
#
# Announces every outward-facing action (release, clone, push) before running
# it. With --dry-run it prints them and changes nothing remote. Never replaces
# an existing release: a fix means a new version.
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"

die() {
	echo "publish.sh: $*" >&2
	exit 1
}

announce() { echo "+ $*"; }

dry_run=0
filename_mode=absolute
while [ $# -gt 0 ]; do
	case "$1" in
	--dry-run) dry_run=1 ;;
	--filename-mode)
		shift
		filename_mode=${1:-}
		;;
	*) die "usage: publish.sh [--dry-run] [--filename-mode absolute|relative]" ;;
	esac
	shift
done
case "$filename_mode" in absolute | relative) ;; *) die "bad --filename-mode" ;; esac

remote=${EIKON_SOURCE_REMOTE:-git@github.com:getBoolean/eikon-source.git}
repo=getBoolean/eikon

# 1. Preflight.
[ -z "$(git status --porcelain)" ] || die "working tree is not clean"
version=$(tr -d '[:space:]' <VERSION)
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION '$version' is not MAJOR.MINOR.PATCH"
git tag --points-at HEAD --list "v$version" | grep -q "v$version" || die "HEAD is not tagged v$version"
scripts/version.sh --check

deb="dist/com.getboolean.eikon_${version}_iphoneos-arm64.deb"
ipa="dist/Eikon-$version.ipa"
tipa="dist/Eikon-$version.tipa"
for f in "$ipa" "$tipa" "$deb" dist/SHA256SUMS; do
	[ -f "$f" ] || die "missing $f; run make package"
done
uv run scripts/verify_artifacts.py dist/

command -v dpkg-deb >/dev/null 2>&1 || die "dpkg-deb not found; run make doctor"
command -v zstd >/dev/null 2>&1 || die "zstd not found; run make doctor"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated; run gh auth login"

asset_url="https://github.com/$repo/releases/download/v$version/$(basename "$deb")"
notes="Eikon v$version. An early prototype that reports whether JIT is usable and shows device status."

if gh release view "v$version" --repo "$repo" >/dev/null 2>&1; then
	if [ "$dry_run" -eq 1 ]; then
		echo "note: release v$version already exists; a real run would refuse it."
	else
		die "release v$version already exists; assets are never replaced. Bump VERSION."
	fi
fi

# 2. Create the release.
announce "gh release create v$version --repo $repo --title v$version --notes ... $ipa $tipa $deb dist/SHA256SUMS"
if [ "$dry_run" -eq 0 ]; then
	gh release create "v$version" --repo "$repo" --title "v$version" --notes "$notes" \
		"$ipa" "$tipa" "$deb" dist/SHA256SUMS
fi

# 3. Download the deb back (its hashes go into the index).
work="build/publish"
rm -rf "$work"
mkdir -p "$work"
if [ "$dry_run" -eq 0 ]; then
	announce "curl -fL --retry 3 $asset_url"
	curl -fL --retry 3 -o "$work/$(basename "$deb")" "$asset_url"
	downloaded="$work/$(basename "$deb")"
	expected=$(grep "  $(basename "$deb")\$" dist/SHA256SUMS | cut -d' ' -f1)
	got=$(shasum -a 256 "$downloaded" | cut -d' ' -f1)
	[ "$expected" = "$got" ] || die "downloaded deb hash $got != $expected from SHA256SUMS"
else
	echo "note: a real run downloads the asset and hashes that; using dist/ deb as a stand-in."
	downloaded="$deb"
fi

# 4. Clone eikon-source.
clone="build/eikon-source"
rm -rf "$clone"
announce "git clone $remote $clone"
git clone "$remote" "$clone"

# First-publish migration guard: refuse anything but README.md and docs/.
unexpected=$(git -C "$clone" ls-tree --name-only HEAD | grep -vx -e README.md -e docs || true)
if [ -n "$unexpected" ]; then
	echo "$unexpected" >&2
	die "eikon-source has unexpected tracked entries (above). The owner decides what to remove."
fi

# 5. Build the index.
uv run scripts/repo/build_index.py \
	--deb "$downloaded" \
	--asset-url "$asset_url" \
	--out "$clone/docs" \
	--filename-mode "$filename_mode" \
	--repo-readme "$clone/README.md"

# 6. Commit and push.
git -C "$clone" add -A
if [ "$dry_run" -eq 1 ]; then
	git -C "$clone" status --short
	git -C "$clone" diff --stat --cached
	announce "git -C $clone commit -m 'Publish com.getboolean.eikon $version'"
	announce "git -C $clone push origin main"
	echo "Dry run complete. Nothing was pushed."
else
	git -C "$clone" commit -m "Publish com.getboolean.eikon $version"
	announce "git -C $clone push origin main"
	git -C "$clone" push origin main
	echo "Published. Sileo source: https://getboolean.github.io/eikon-source/"
fi
