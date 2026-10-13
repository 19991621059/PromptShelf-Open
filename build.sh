#!/bin/zsh
set -euo pipefail
project_root=${0:A:h}
optimization=-O
debug_flags=()
if [[ ${1:-} == --debug ]]; then
  optimization=-Onone
  debug_flags=(-g)
  shift
fi
app_path=${1:-"$project_root/.build.noindex/PromptShelf-Open.app"}
architecture=${ARCH:-$(uname -m)}
[[ "$architecture" == arm64 || "$architecture" == x86_64 ]] || { print -u2 'Unsupported architecture'; exit 1; }
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
# Remove only compiler-generated symbols left by an earlier debug build.
if [[ "$optimization" == -O ]]; then
  rm -rf "$app_path/Contents/MacOS/PromptShelf-Open.dSYM"
fi
xcrun swiftc -module-cache-path "$project_root/.build.noindex/ModuleCache" \
  -swift-version 5 "$optimization" "${debug_flags[@]}" -target "$architecture-apple-macosx13.0" \
  "$project_root"/Sources/*.swift "$project_root"/Tests/*.swift \
  -framework AppKit -framework PDFKit -framework ServiceManagement \
  -framework Carbon -framework Security -o "$app_path/Contents/MacOS/PromptShelf-Open"
cp "$project_root/Resources/Info.plist" "$app_path/Contents/Info.plist"
if [[ -f "$project_root/Resources/AppIcon.icns" ]]; then
  cp "$project_root/Resources/AppIcon.icns" "$app_path/Contents/Resources/"
fi
codesign --force --sign - "$app_path"
print "Built: $app_path ($architecture)"
