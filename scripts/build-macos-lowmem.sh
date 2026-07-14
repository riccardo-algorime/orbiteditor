#!/usr/bin/env bash
# Low-memory macOS production build (skips symbol mangling).
# Usage: ./scripts/build-macos-lowmem.sh [arm64|x64]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ARCH="${1:-arm64}"
HEAP="${NODE_HEAP_MB:-6144}"
export NODE_OPTIONS="--max-old-space-size=${HEAP}"

echo "Orbit macOS low-memory build: darwin-${ARCH} (heap=${HEAP}MB)"

npm run buildreact:prod

npm run gulp -- compile-build-without-mangling
rm -rf .build/extensions
npm run gulp -- compile-non-native-extensions-build
npm run gulp -- compile-extension-media-build
npm run gulp -- minify-vscode
npm run gulp -- "vscode-darwin-${ARCH}-min-ci"

APP_DIR="../Orbit-darwin-${ARCH}"
if [[ ! -d "$APP_DIR" ]]; then
	echo "Expected app bundle at $APP_DIR"
	exit 1
fi

echo "Built: ${APP_DIR}/Orbit.app"

"$ROOT/scripts/codesign-macos.sh" "${APP_DIR}/Orbit.app"