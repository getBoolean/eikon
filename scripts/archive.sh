#!/bin/bash
# Build the one Release archive that every artifact comes from. Run from the repo root.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

die() {
	echo "archive.sh: $*" >&2
	exit 1
}

make project

archive="build/Eikon.xcarchive"
rm -rf "$archive"
xcrun xcodebuild archive \
	-project Eikon.xcodeproj \
	-scheme Eikon \
	-configuration Release \
	-destination 'generic/platform=iOS' \
	-archivePath "$archive" \
	CODE_SIGNING_ALLOWED=NO

app="$archive/Products/Applications/Eikon.app"
[ -d "$app" ] || die "archive did not produce $app"

# A Release build must never ship the placeholder acknowledgements.
[ -f build/generated/Acknowledgements.json ] || die "build/generated/Acknowledgements.json is missing; run make generated"

# arm64-only guard. No nested Mach-O files exist in this split; the guard is for
# later splits that add frameworks.
is_macho() {
	local magic
	magic=$(xxd -p -l 4 "$1" 2>/dev/null || true)
	case "$magic" in
	cffaedfe | cafebabe | feedfacf | bebafeca) return 0 ;;
	*) return 1 ;;
	esac
}

while IFS= read -r -d '' macho; do
	is_macho "$macho" || continue
	archs=$(xcrun lipo -archs "$macho" 2>/dev/null) || die "could not read architectures of $macho"
	case " $archs " in
	*" arm64 "*) ;;
	*) die "$macho has no arm64 slice (has: $archs)" ;;
	esac
	if [ "$archs" != "arm64" ]; then
		echo "archive.sh: thinning $macho ($archs) to arm64"
		xcrun lipo "$macho" -thin arm64 -output "$macho"
		archs=$(xcrun lipo -archs "$macho")
		[ "$archs" = "arm64" ] || die "$macho still has non-arm64 slices after thinning: $archs"
	fi
done < <(find "$app" -type f -print0)

echo "archive.sh: built $archive"
