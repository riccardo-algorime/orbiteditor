#!/usr/bin/env bash
# Build and publish an Orbit release locally, then refresh update/latest.json.
#
# Usage:
#   ./scripts/release-local.sh                    # build darwin-arm64 from product.json version
#   ./scripts/release-local.sh 0.2.0 darwin-arm64 # explicit version + platform
#   SKIP_GH_RELEASE=1 ./scripts/release-local.sh  # skip GitHub release upload
#
# For macOS-only releases, prefer: ./scripts/publish-release.sh
#
# After publishing:
#   git push origin main   # clients read update/latest.json from main
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
	VERSION="$(node -p "require('./product.json').orbitVersion")"
fi

# Keep package.json version aligned with orbitVersion (used by Windows installers and embedded app metadata)
node <<NODE
const fs = require('fs');
const pkgPath = 'package.json';
const product = JSON.parse(fs.readFileSync('product.json', 'utf8'));
const target = '${VERSION}';
const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8'));
if (pkg.version !== target) {
	pkg.version = target;
	fs.writeFileSync(pkgPath, JSON.stringify(pkg, null, 2) + '\n');
	console.log('Synced package.json version → ' + target);
}
if (product.orbitVersion !== target) {
	product.orbitVersion = target;
	fs.writeFileSync('product.json', JSON.stringify(product, null, '\t') + '\n');
	console.log('Synced product.json orbitVersion → ' + target);
}
NODE

TAG="v${VERSION#v}"
PLATFORM="${2:-darwin-arm64}"

echo "Orbit local release: version=${VERSION} tag=${TAG} platform=${PLATFORM}"

npm run buildreact:prod

release_darwin() {
	local arch="$1"
	./scripts/build-macos-lowmem.sh "$arch"
	local app_dir="../Orbit-darwin-${arch}"
	if [[ ! -d "$app_dir" ]]; then
		echo "Expected app bundle at $app_dir"
		exit 1
	fi
	local dmg="Orbit-${VERSION}-darwin-${arch}.dmg"
	./scripts/make-dmg.sh "$app_dir" "$dmg"
}

case "$PLATFORM" in
	darwin-arm64) release_darwin arm64 ;;
	darwin-x64) release_darwin x64 ;;
	win32-x64|win32-arm64)
		local arch="${PLATFORM#win32-}"
		NODE_OPTIONS="--max-old-space-size=8192" npm run gulp -- compile-build-with-mangling
		NODE_OPTIONS="--max-old-space-size=8192" npm run gulp -- compile-non-native-extensions-build
		NODE_OPTIONS="--max-old-space-size=8192" npm run gulp -- compile-extension-media-build
		npm run buildreact:prod
		NODE_OPTIONS="--max-old-space-size=8192" npm run gulp -- minify-vscode
		NODE_OPTIONS="--max-old-space-size=8192" npm run gulp -- "vscode-win32-${arch}-min-ci"
		NODE_OPTIONS="--max-old-space-size=8192" npm run gulp -- "vscode-win32-${arch}-inno-updater"
		NODE_OPTIONS="--max-old-space-size=8192" npm run gulp -- "vscode-win32-${arch}-system-setup"
		mv ".build/win32-${arch}/system-setup/VSCodeSetup.exe" "Orbit-${VERSION}-win32-${arch}-setup.exe"
		;;
	linux-x64)
		NODE_OPTIONS="--max-old-space-size=8192" npm run gulp -- vscode-linux-x64-min
		(cd scripts/appimage && chmod +x create_appimage.sh && ./create_appimage.sh)
		mv scripts/appimage/Orbit-x86_64.AppImage "Orbit-${VERSION}-linux-x64.AppImage"
		;;
	*)
		echo "Unknown platform: $PLATFORM"
		echo "Supported: darwin-arm64, darwin-x64, win32-x64, win32-arm64, linux-x64"
		exit 1
		;;
esac

# Update manifest for the built platform only (merge keeps other platforms)
ASSET_ARGS=(--version "$VERSION" --tag "$TAG" --merge)
case "$PLATFORM" in
	darwin-arm64) ASSET_ARGS+=(--asset "darwin-arm64=Orbit-${VERSION}-darwin-arm64.dmg") ;;
	darwin-x64) ASSET_ARGS+=(--asset "darwin-x64=Orbit-${VERSION}-darwin-x64.dmg") ;;
	win32-x64) ASSET_ARGS+=(--asset "win32-x64=Orbit-${VERSION}-win32-x64-setup.exe") ;;
	win32-arm64) ASSET_ARGS+=(--asset "win32-arm64=Orbit-${VERSION}-win32-arm64-setup.exe") ;;
	linux-x64) ASSET_ARGS+=(--asset "linux-x64=Orbit-${VERSION}-linux-x64.AppImage") ;;
esac
node scripts/update-latest-json.js "${ASSET_ARGS[@]}"

if [[ "${SKIP_GH_RELEASE:-}" == "1" ]]; then
	echo "SKIP_GH_RELEASE=1 — skipped GitHub release upload."
elif command -v gh >/dev/null 2>&1; then
	FILES=()
	while IFS= read -r file; do
		FILES+=("$file")
	done < <(find "$ROOT" -maxdepth 1 \( -name 'Orbit-*.dmg' -o -name 'Orbit-*.exe' -o -name 'Orbit-*.AppImage' \) -print 2>/dev/null)

	if [[ ${#FILES[@]} -gt 0 ]]; then
		if gh release view "$TAG" >/dev/null 2>&1; then
			gh release upload "$TAG" "${FILES[@]}" --clobber
			echo "Uploaded to existing GitHub release ${TAG}"
		else
			gh release create "$TAG" "${FILES[@]}" --title "Orbit ${VERSION}" --notes "Orbit ${VERSION}"
			echo "Created GitHub release ${TAG}"
		fi
	else
		echo "No release artifacts found in repo root; update/latest.json was still refreshed."
	fi
else
	echo "gh CLI not found; skipped GitHub release upload."
fi

echo ""
echo "Done."
echo "  1. Verify artifacts and GitHub release (if created)"
echo "  2. git push origin main   # required for in-app auto-update"
echo "  3. git push origin ${TAG}  # if tag not yet pushed"