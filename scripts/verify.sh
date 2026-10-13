#!/bin/zsh
set -euo pipefail
project_root=${0:A:h:h}
"$project_root/build.sh"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/promptshelf-open-check.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
app="$project_root/.build.noindex/PromptShelf-Open.app/Contents/MacOS/PromptShelf-Open"
PROMPTSHELF_OPEN_DATA_DIR="$fixture/native" "$app" --self-test
PROMPTSHELF_OPEN_DATA_DIR="$fixture/workflow" "$app" --workflow-check
codesign --verify --deep --strict "$project_root/.build.noindex/PromptShelf-Open.app"
