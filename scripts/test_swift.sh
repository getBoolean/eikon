#!/bin/bash
# Run the Swift tests on the newest iPhone simulator, then install and launch
# the app there and check that it stays running. Called by `make test-swift`.
#
#   EIKON_SIM_DESTINATION  an xcodebuild -destination value to use instead
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

die() {
	echo "test_swift.sh: $*" >&2
	exit 1
}

derived=build/DerivedData

# 1. Pick the simulator.
if [ -n "${EIKON_SIM_DESTINATION:-}" ]; then
	destination=$EIKON_SIM_DESTINATION
	udid=$(printf '%s\n' "$destination" | sed -n 's/.*id=\([0-9A-Fa-f-]*\).*/\1/p')
	[ -n "$udid" ] || die "EIKON_SIM_DESTINATION needs an id=<simulator udid>, for example 'platform=iOS Simulator,id=<udid>'"
	known=$(xcrun simctl list devices)
	case $known in
	*"($udid)"*) ;;
	*) die "$udid is not a simulator known to simctl" ;;
	esac
else
	devices_json=$(xcrun simctl list devices available --json)
	udid=$(printf '%s' "$devices_json" | uv run --no-project python -c '
import json, re, sys

devices = json.load(sys.stdin)["devices"]
best = None
for runtime, entries in devices.items():
    m = re.search(r"\.iOS-(\d+(?:-\d+)*)$", runtime)
    if not m:
        continue
    version = tuple(int(p) for p in m.group(1).split("-"))
    for d in entries:
        if d.get("isAvailable") and d["name"].startswith("iPhone"):
            # Newest runtime wins; the name only makes ties deterministic.
            key = (version, d["name"])
            if best is None or key > best[0]:
                best = (key, d["udid"])
if best:
    print(best[1])
')
	[ -n "$udid" ] || die "no iPhone simulator available; install an iOS simulator runtime in Xcode (Settings > Components)"
	destination="platform=iOS Simulator,id=$udid"
fi
echo "Destination: $destination"

# 2. Build and test.
xcrun xcodebuild test \
	-project Eikon.xcodeproj \
	-scheme Eikon \
	-destination "$destination" \
	-derivedDataPath "$derived" \
	CODE_SIGNING_ALLOWED=NO

# 3. Launch check.
app="$derived/Build/Products/Debug-iphonesimulator/Eikon.app"
[ -d "$app" ] || die "built app not found at $app"
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")

if ! boot_err=$(xcrun simctl boot "$udid" 2>&1); then
	case $boot_err in
	*"current state: Booted"*) ;;
	*) die "could not boot $udid: $boot_err" ;;
	esac
fi
xcrun simctl bootstatus "$udid" -b >/dev/null
xcrun simctl install "$udid" "$app"
xcrun simctl launch "$udid" "$bundle_id" >/dev/null
sleep 5
# A running app has a numeric PID; a job that has exited shows "-".
launchd_jobs=$(xcrun simctl spawn "$udid" launchctl list)
running=$(printf '%s\n' "$launchd_jobs" | awk -v label="UIKitApplication:$bundle_id[" \
	'index($3, label) == 1 && $1 ~ /^[0-9]+$/ { print $1 }')
[ -n "$running" ] || die "$bundle_id exited right after launch"
xcrun simctl terminate "$udid" "$bundle_id" || true

# 4. Summary.
echo "test-swift: tests passed and $bundle_id launched on $destination"
