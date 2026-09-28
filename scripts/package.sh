#!/bin/bash
# Package the Release archive into one install artifact. Run from the repo root.
#
#   scripts/package.sh ipa | deb
#
# One build, two artifacts: they differ only in entitlements, the EKPackageKind
# stamp, the bundle id and container format. Reads the version from VERSION.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

die() {
	echo "package.sh: $*" >&2
	exit 1
}

kind=${1:-}
case "$kind" in
ipa | deb) ;;
*) die "usage: package.sh ipa|deb" ;;
esac

# The deb gets its own bundle id, so a Dopamine install and a TrollStore-installed
# ipa can coexist. The ipa keeps the id the archive built with.
deb_bundle_id="com.getboolean.eikon.rootless"

version=$(tr -d '[:space:]' <VERSION)
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION '$version' is not MAJOR.MINOR.PATCH"

archived_app="build/Eikon.xcarchive/Products/Applications/Eikon.app"
[ -d "$archived_app" ] || die "missing $archived_app; run make archive"

entitlements="packaging/entitlements/$kind.plist"
[ -f "$entitlements" ] || die "missing $entitlements"

# ldid must be the Procursus build (the check doctor.sh uses).
command -v ldid >/dev/null 2>&1 || die "ldid not found; run make doctor"
ldid_help=$( { ldid 2>&1; ldid --version 2>&1; } || true)
if ! printf '%s' "$ldid_help" | grep -qi procursus &&
	! printf '%s' "$ldid_help" | grep -Eq -- '(^|[[:space:]])-M([[:space:]]|$)'; then
	die "ldid is not the Procursus build; run make doctor"
fi

stage="build/stage/$kind"
rm -rf "$stage"
mkdir -p "$stage"

app="$stage/Eikon.app"
COPYFILE_DISABLE=1 ditto "$archived_app" "$app"

/usr/libexec/PlistBuddy -c "Set :EKPackageKind $kind" "$app/Info.plist"
if [ "$kind" = deb ]; then
	/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $deb_bundle_id" "$app/Info.plist"
fi

bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")
# One bundle-level call: Procursus ldid signs nested code first and seals resources.
ldid "-S$entitlements" "-I$bundle_id" "$app"

read_back=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Info.plist")
[ "$read_back" = "$version" ] || die "staged version $read_back does not match VERSION $version"

mkdir -p dist

case "$kind" in
ipa)
	mkdir -p "$stage/Payload"
	mv "$app" "$stage/Payload/Eikon.app"
	out="$root/dist/Eikon-$version.$kind"
	rm -f "$out"
	(cd "$stage" && zip -qr -X --symlinks "$out" Payload -x '*/._*' '*/.DS_Store' '__MACOSX/*')
	echo "package.sh: wrote dist/Eikon-$version.$kind"
	;;
deb)
	deb_root="$stage/root"
	app_dir="$deb_root/var/jb/Applications"
	doc_dir="$deb_root/var/jb/usr/share/doc/$bundle_id"
	mkdir -p "$app_dir" "$doc_dir" "$deb_root/DEBIAN"
	mv "$app" "$app_dir/Eikon.app"
	cp LICENSE THIRD_PARTY_NOTICES.md "$doc_dir/"

	installed_size=$(du -sk "$deb_root/var" | cut -f1)
	sed -e "s/@VERSION@/$version/" -e "s/@INSTALLED_SIZE@/$installed_size/" \
		packaging/deb/control.in >"$deb_root/DEBIAN/control"
	install -m 0755 packaging/deb/postinst "$deb_root/DEBIAN/postinst"
	install -m 0755 packaging/deb/prerm "$deb_root/DEBIAN/prerm"

	chmod -R u=rwX,go=rX "$deb_root"
	chmod 0755 "$deb_root/DEBIAN/postinst" "$deb_root/DEBIAN/prerm"

	out="dist/${bundle_id}_${version}_iphoneos-arm64.deb"
	rm -f "$out"
	SOURCE_DATE_EPOCH=$(git log -1 --format=%ct) dpkg-deb --root-owner-group -Zxz -b "$deb_root" "$out"
	echo "package.sh: wrote $out"
	;;
esac
