#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
package_root=$(CDPATH= cd -- "$script_dir/.." && pwd)

if ! command -v xcodegen >/dev/null 2>&1; then
    printf '%s\n' 'XcodeGen is required. Install it with: brew install xcodegen' >&2
    exit 1
fi

cd "$package_root"
xcodegen generate --spec project.yml