#!/bin/bash
#
# Build PowerSleuth.app WITHOUT Xcode — only the Command Line Tools (swift) are required.
# Compiles via Swift Package Manager, assembles the .app bundle, and ad-hoc signs it.
#
# Usage:
#   ./scripts/build.sh              # build for this Mac's architecture → .build-app/PowerSleuth.app
#   ./scripts/build.sh --install    # also copy it to /Applications
#   UNIVERSAL=1 ./scripts/build.sh  # build a universal (arm64 + x86_64) binary
#
# Prerequisites: macOS 15+, Command Line Tools (`xcode-select --install`), and internet
# on the first run (to fetch the GRDB dependency). No Xcode, no admin needed.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO/PowerSleuth"
BUILD="$REPO/.build-app"
PKG="$BUILD/spm"
APP="$BUILD/PowerSleuth.app"

BUNDLE_ID="com.arsabolsky.powersleuth"
GRDB_VERSION="7.0.0"
MIN_MACOS="15.0"

# --- preflight -------------------------------------------------------------
if ! command -v swift >/dev/null 2>&1; then
  echo "error: the Swift toolchain isn't installed. Run: xcode-select --install" >&2
  exit 1
fi

# Architecture flags
if [ "${UNIVERSAL:-0}" = "1" ]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64); ARCH_DESC="universal (arm64+x86_64)"
else
  ARCH_FLAGS=(--arch "$(uname -m)"); ARCH_DESC="$(uname -m)"
fi

echo "==> Building PowerSleuth.app ($ARCH_DESC)"

# --- 1. assemble a Swift package from the existing sources -----------------
rm -rf "$PKG"
mkdir -p "$PKG/Sources/PowerSleuth"
cp "$SRC"/Models/*.swift "$SRC"/Services/*.swift "$SRC"/Views/*.swift "$SRC"/PowerSleuthApp.swift \
   "$PKG/Sources/PowerSleuth/"

cat > "$PKG/Package.swift" <<EOF
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PowerSleuth",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "$GRDB_VERSION")
    ],
    targets: [
        .executableTarget(
            name: "PowerSleuth",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
EOF

# --- 2. compile ------------------------------------------------------------
( cd "$PKG" && swift build -c release "${ARCH_FLAGS[@]}" )
BIN="$(cd "$PKG" && swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)/PowerSleuth"

# --- 3. assemble the .app bundle -------------------------------------------
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PowerSleuth"
[ -f "$SRC/Resources/AppIcon.icns" ] && cp "$SRC/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Concrete Info.plist (substitute the Xcode build variables the template uses).
sed -e 's/\$(DEVELOPMENT_LANGUAGE)/en/g' \
    -e 's/\$(EXECUTABLE_NAME)/PowerSleuth/g' \
    -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$BUNDLE_ID/g" \
    -e 's/\$(PRODUCT_NAME)/PowerSleuth/g' \
    -e 's/\$(PRODUCT_BUNDLE_PACKAGE_TYPE)/APPL/g' \
    -e "s/\$(MACOSX_DEPLOYMENT_TARGET)/$MIN_MACOS/g" \
    "$SRC/Info.plist" > "$APP/Contents/Info.plist"

# --- 4. ad-hoc code sign (lets Gatekeeper run a locally-built app) ---------
codesign --force --options runtime \
  --entitlements "$SRC/PowerSleuth.entitlements" --sign - "$APP"
codesign --verify --strict "$APP"

echo "==> Built: $APP"

# --- 5. optional install ---------------------------------------------------
if [ "${1:-}" = "--install" ]; then
  DEST="/Applications/PowerSleuth.app"
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  echo "==> Installed: $DEST"
  echo "    Launch it from /Applications (it's a menu-bar app — look in the menu bar)."
fi
