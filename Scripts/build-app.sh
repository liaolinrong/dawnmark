#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
package_root=$(CDPATH= cd -- "$script_dir/.." && pwd)

app_path="$package_root/build/DawnMark.app"
derived_data="$package_root/.build/local-app"
built_app="$derived_data/Build/Products/Release/DawnMark.app"

ensure_not_running() {
    if pgrep -f '[D]awnMark.app/Contents/MacOS/DawnMark' >/dev/null; then
        printf '%s\n' 'Quit all DawnMark instances before rebuilding the app.' >&2
        exit 1
    fi
}

ensure_not_running
"$script_dir/generate-project.sh"
xcodebuild \
    -project "$package_root/DawnMark.xcodeproj" \
    -scheme DawnMark \
    -configuration Release \
    -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath "$derived_data" \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM= \
    build

codesign --verify --deep --strict "$built_app"
entitlements_path=$(mktemp)
trap 'rm -f "$entitlements_path"' 0
codesign -d --entitlements - --xml "$built_app" > "$entitlements_path"
for entitlement in \
    com.apple.security.app-sandbox \
    com.apple.security.files.user-selected.read-write \
    com.apple.security.files.bookmarks.app-scope; do
    if [ "$(/usr/libexec/PlistBuddy -c "Print :$entitlement" "$entitlements_path")" != true ]; then
        printf 'Missing required entitlement: %s\n' "$entitlement" >&2
        exit 1
    fi
done

ensure_not_running
mkdir -p "$package_root/build"
rm -rf "$app_path"
ditto "$built_app" "$app_path"
plutil -lint "$app_path/Contents/Info.plist"
codesign --verify --deep --strict "$app_path"
touch "$app_path"
printf '%s\n' "Built sandboxed local app: $app_path" 'Ad-hoc signed for local testing only. App Store distribution requires a development team and distribution signing.'