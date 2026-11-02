#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
package_root=$(CDPATH= cd -- "$script_dir/.." && pwd)

swift build -c release --package-path "$package_root"
binary_dir=$(swift build -c release --package-path "$package_root" --show-bin-path)
app_path="$package_root/build/DawnMark.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_dir/DawnMark" "$app_path/Contents/MacOS/DawnMark"
cp "$package_root/Configuration/Info.plist" "$app_path/Contents/Info.plist"
cp "$package_root/Configuration/AppIcon.icns" "$app_path/Contents/Resources/AppIcon.icns"
for resource_bundle in "$binary_dir"/*.bundle; do
    [ -d "$resource_bundle" ] || continue
    ditto "$resource_bundle" "$app_path/Contents/Resources/$(basename -- "$resource_bundle")"
done
plutil -lint "$app_path/Contents/Info.plist"
cmp "$binary_dir/DawnMark" "$app_path/Contents/MacOS/DawnMark"
touch "$app_path"
printf '%s\n' "Built unsigned local app: $app_path" 'This app is not sandbox-signed. Use the Xcode project for signed distribution.'