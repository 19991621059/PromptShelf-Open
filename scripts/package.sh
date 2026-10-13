#!/bin/zsh
set -euo pipefail
project_root=${0:A:h:h}
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$project_root/Resources/Info.plist")
architecture=${ARCH:-$(uname -m)}
app="$project_root/.build.noindex/release/PromptShelf-Open.app"
[[ ${SKIP_BUILD:-0} == 1 ]] || "$project_root/build.sh" "$app"
codesign --verify --deep --strict "$app"
mkdir -p "$project_root/dist"
archive="$project_root/dist/PromptShelf-Open-$version-$architecture.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
stage=$(mktemp -d "$project_root/.build.noindex/dmg-$architecture.XXXXXX")
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/PromptShelf-Open.app"
[[ -e "$stage/Applications" ]] || ln -s /Applications "$stage/Applications"
hdiutil create -volname 'PromptShelf-Open' -srcfolder "$stage" -format UDZO -ov "$project_root/dist/PromptShelf-Open-$version-$architecture.dmg"
(cd "$project_root/dist" && shasum -a 256 "PromptShelf-Open-$version-$architecture.zip" "PromptShelf-Open-$version-$architecture.dmg" > SHA256SUMS)
print "Packages: $project_root/dist"
