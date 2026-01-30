#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="CodMate"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build}"
APP_DIR="${APP_DIR:-$BUILD_DIR/CodMate.app}"
BIN_DIR="$BUILD_DIR/bin"

ARCH_MATRIX=( ${ARCH_MATRIX:-arm64 x86_64} )
SWIFT_CONFIG="${SWIFT_CONFIG:-release}"

BUNDLE_ID="${BUNDLE_ID:-ai.umate.codmate}"
MIN_MACOS="${MIN_MACOS:-13.5}"
VER="${VER:-}"
BUILD_NUMBER_STRATEGY="${BUILD_NUMBER_STRATEGY:-date}"
BUILD_NUMBER="${BUILD_NUMBER:-}"

compute_build_number() {
  case "$BUILD_NUMBER_STRATEGY" in
    date) date +%Y%m%d%H%M ;;
    git) (cd "$ROOT_DIR" && git rev-list --count HEAD 2>/dev/null) || echo 1 ;;
    counter)
      local f="${BUILD_COUNTER_FILE:-$BUILD_DIR/build-number}"
      mkdir -p "$(dirname "$f")"
      local n=0
      if [[ -f "$f" ]]; then n=$(cat "$f" 2>/dev/null || echo 0); fi
      n=$((n+1))
      echo "$n" > "$f"
      echo "$n" ;;
    *) date +%Y%m%d%H%M ;;
  esac
}

if [[ -z "$VER" ]]; then
  echo "[error] VER is required. Example: VER=1.2.3 ./scripts/create-app-bundle.sh" >&2
  exit 1
fi

BASE_VERSION="$VER"

if [[ -z "$BUILD_NUMBER" ]]; then
  BUILD_NUMBER="$(compute_build_number)"
fi
DISPLAY_VERSION="${BASE_VERSION}+${BUILD_NUMBER}"

SWIFT_FLAGS=(
  -Xswiftc -DSYSTEM_PACKAGE_DARWIN
  -Xswiftc -DSUBPROCESS_ASYNCIO_DISPATCH
  -Xswiftc -enable-experimental-feature
  -Xswiftc LifetimeDependence
  -Xswiftc -enable-experimental-feature
  -Xswiftc NonescapableTypes
)

STRIP="${STRIP:-1}"
STRIP_FLAGS="${STRIP_FLAGS:--x}"

if [[ -n "${EXTRA_SWIFT_FLAGS:-}" ]]; then
  # shellcheck disable=SC2206
  EXTRA_FLAGS=( ${EXTRA_SWIFT_FLAGS} )
  SWIFT_FLAGS+=("${EXTRA_FLAGS[@]}")
fi

mkdir -p "$BUILD_DIR" "$BIN_DIR"

CODMATE_BINS=()
NOTIFY_BINS=()

# Note: SwiftPM's --arch flag automatically creates architecture-specific build directories
# (e.g., .build/arm64-apple-macosx/ and .build/x86_64-apple-macosx/)
# Each architecture's dependencies are compiled separately, ensuring no cross-architecture contamination.

for arch in "${ARCH_MATRIX[@]}"; do
  # Map SwiftPM arch names to libghostty arch names
  GHOSTTY_ARCH=""
  case "$arch" in
    arm64) GHOSTTY_ARCH="aarch64" ;;
    x86_64) GHOSTTY_ARCH="x86_64" ;;
    *) GHOSTTY_ARCH="$arch" ;;
  esac
  
  # Setup architecture-specific libghostty library for linking
  VENDOR_LIB_DIR="$ROOT_DIR/ghostty/Vendor/lib"
  ARCH_LIB="$VENDOR_LIB_DIR/$GHOSTTY_ARCH/libghostty.a"
  LINK_LIB="$VENDOR_LIB_DIR/libghostty.a"
  
  if [ -f "$ARCH_LIB" ]; then
    # Copy architecture-specific library to the link location
    cp -f "$ARCH_LIB" "$LINK_LIB"
    echo "[libghostty] Using $GHOSTTY_ARCH library for $arch build"
  elif [ -f "$LINK_LIB" ]; then
    echo "[libghostty] Using existing library at $LINK_LIB (may be wrong architecture)"
  else
    echo "[warn] libghostty.a not found at $ARCH_LIB or $LINK_LIB" >&2
    echo "[warn] Build may fail. Run ./scripts/build-libghostty-local.sh $GHOSTTY_ARCH first" >&2
  fi
  
  echo "[build] swift build -c $SWIFT_CONFIG --arch $arch"
  swift build -c "$SWIFT_CONFIG" --arch "$arch" "${SWIFT_FLAGS[@]}"
  BIN_PATH="$(swift build -c "$SWIFT_CONFIG" --arch "$arch" --show-bin-path)"

  CODMATE_BIN="$BIN_PATH/CodMate"
  NOTIFY_BIN="$BIN_PATH/notify"

  if [[ ! -f "$CODMATE_BIN" ]]; then
    echo "[error] CodMate binary missing at $CODMATE_BIN" >&2
    exit 1
  fi
  if [[ ! -f "$NOTIFY_BIN" ]]; then
    echo "[info] notify binary missing; building product explicitly"
    swift build -c "$SWIFT_CONFIG" --arch "$arch" "${SWIFT_FLAGS[@]}" --product notify
    BIN_PATH="$(swift build -c "$SWIFT_CONFIG" --arch "$arch" --show-bin-path)"
    NOTIFY_BIN="$BIN_PATH/notify"
    if [[ ! -f "$NOTIFY_BIN" ]]; then
      echo "[error] notify binary missing at $NOTIFY_BIN" >&2
      exit 1
    fi
  fi

  # Verify binary architectures match expected arch (ensures no cross-architecture contamination)
  if command -v lipo >/dev/null 2>&1; then
    for BIN_TO_CHECK in "$CODMATE_BIN" "$NOTIFY_BIN"; do
      if [[ -f "$BIN_TO_CHECK" ]]; then
        BIN_ARCHS=$(lipo -info "$BIN_TO_CHECK" 2>/dev/null | sed 's/.*: //' || echo "")
        if [[ -n "$BIN_ARCHS" ]]; then
          if [[ "$BIN_ARCHS" != *"$arch"* ]]; then
            echo "[error] Binary $(basename "$BIN_TO_CHECK") architecture mismatch: expected $arch, got $BIN_ARCHS" >&2
            exit 1
          fi
          # Check if binary contains multiple architectures (should only have one)
          ARCH_COUNT=$(echo "$BIN_ARCHS" | wc -w | tr -d ' ')
          if [[ "$ARCH_COUNT" -gt 1 ]]; then
            echo "[error] Binary $(basename "$BIN_TO_CHECK") contains multiple architectures ($BIN_ARCHS), expected only $arch" >&2
            exit 1
          fi
          echo "[verify] $(basename "$BIN_TO_CHECK") architecture: $BIN_ARCHS (expected: $arch)"
        fi
      fi
    done
  fi

  CODMATE_BINS+=("$CODMATE_BIN")
  NOTIFY_BINS+=("$NOTIFY_BIN")
  echo "[ok] Built for $arch"
  echo "      CodMate: $CODMATE_BIN"
  echo "      notify:  $NOTIFY_BIN"
  echo ""
done

if [[ ${#ARCH_MATRIX[@]} -eq 1 ]]; then
  cp -f "${CODMATE_BINS[0]}" "$BIN_DIR/CodMate"
  cp -f "${NOTIFY_BINS[0]}" "$BIN_DIR/notify"
  ARCH_SUFFIX="${ARCH_MATRIX[0]}"
else
  ARCH_SUFFIX="universal"
  lipo -create "${CODMATE_BINS[@]}" -output "$BIN_DIR/CodMate"
  lipo -create "${NOTIFY_BINS[@]}" -output "$BIN_DIR/notify"
fi

chmod +x "$BIN_DIR/CodMate" "$BIN_DIR/notify"

if [[ "$STRIP" == "1" ]]; then
  if command -v strip >/dev/null 2>&1; then
    echo "[strip] Stripping binaries ($STRIP_FLAGS)"
    strip $STRIP_FLAGS "$BIN_DIR/CodMate" "$BIN_DIR/notify" || true
  else
    echo "[warn] strip not found; skipping binary strip"
  fi
fi

echo "[bundle] Building $APP_NAME.app ($DISPLAY_VERSION, $ARCH_SUFFIX)"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources/bin"

cp -f "$BIN_DIR/CodMate" "$APP_DIR/Contents/MacOS/CodMate"
cp -f "$BIN_DIR/notify" "$APP_DIR/Contents/Resources/bin/codmate-notify"
chmod +x "$APP_DIR/Contents/MacOS/CodMate" "$APP_DIR/Contents/Resources/bin/codmate-notify"

echo -n "APPL????" > "$APP_DIR/Contents/PkgInfo"

INFO_SRC="$ROOT_DIR/assets/Info.plist"
INFO_DST="$APP_DIR/Contents/Info.plist"
if [[ ! -f "$INFO_SRC" ]]; then
  echo "[error] Info.plist not found at $INFO_SRC" >&2
  exit 1
fi
cp -f "$INFO_SRC" "$INFO_DST"

/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$INFO_DST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $BASE_VERSION" "$INFO_DST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$INFO_DST"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $MIN_MACOS" "$INFO_DST"

GIT_TAG="${GIT_TAG:-$(cd "$ROOT_DIR" && git describe --tags --abbrev=0 2>/dev/null || true)}"
GIT_COMMIT="${GIT_COMMIT:-$(cd "$ROOT_DIR" && git rev-parse --short HEAD 2>/dev/null || true)}"
GIT_DIRTY="${GIT_DIRTY:-}"
if [[ -z "$GIT_DIRTY" ]]; then
  if (cd "$ROOT_DIR" && git diff --quiet --ignore-submodules --); then
    GIT_DIRTY="0"
  else
    GIT_DIRTY="1"
  fi
fi
plutil -replace CodMateGitTag -string "$GIT_TAG" "$INFO_DST"
plutil -replace CodMateGitCommit -string "$GIT_COMMIT" "$INFO_DST"
plutil -replace CodMateGitDirty -string "$GIT_DIRTY" "$INFO_DST"

RESOURCES_DIR="$APP_DIR/Contents/Resources"

if [[ -d "$ROOT_DIR/assets/Assets.xcassets" ]]; then
  if ! command -v xcrun >/dev/null 2>&1; then
    echo "[error] xcrun not found. Install Xcode Command Line Tools." >&2
    exit 1
  fi
  echo "[assets] Compiling asset catalog"
  xcrun actool \
    "$ROOT_DIR/assets/Assets.xcassets" \
    --compile "$RESOURCES_DIR" \
    --platform macosx \
    --minimum-deployment-target "$MIN_MACOS" \
    --app-icon AppIcon \
    --output-partial-info-plist "$BUILD_DIR/asset-info.plist" \
    --notices --warnings
fi

if [[ -f "$ROOT_DIR/payload/providers.json" ]]; then
  cp -f "$ROOT_DIR/payload/providers.json" "$RESOURCES_DIR/providers.json"
fi
if [[ -f "$ROOT_DIR/payload/terminals.json" ]]; then
  cp -f "$ROOT_DIR/payload/terminals.json" "$RESOURCES_DIR/terminals.json"
fi
if [[ -f "$ROOT_DIR/payload/hook-variables.json" ]]; then
  mkdir -p "$RESOURCES_DIR/payload"
  cp -f "$ROOT_DIR/payload/hook-variables.json" "$RESOURCES_DIR/payload/hook-variables.json"
fi
if [[ -f "$ROOT_DIR/payload/hook-events.json" ]]; then
  mkdir -p "$RESOURCES_DIR/payload"
  cp -f "$ROOT_DIR/payload/hook-events.json" "$RESOURCES_DIR/payload/hook-events.json"
fi
if [[ -d "$ROOT_DIR/payload/commands" ]]; then
  mkdir -p "$RESOURCES_DIR/payload"
  cp -R "$ROOT_DIR/payload/commands" "$RESOURCES_DIR/payload/commands"
fi
if [[ -d "$ROOT_DIR/payload/prompts" ]]; then
  mkdir -p "$RESOURCES_DIR/payload"
  cp -R "$ROOT_DIR/payload/prompts" "$RESOURCES_DIR/payload/prompts"
fi
if [[ -f "$ROOT_DIR/PrivacyInfo.xcprivacy" ]]; then
  cp -f "$ROOT_DIR/PrivacyInfo.xcprivacy" "$RESOURCES_DIR/PrivacyInfo.xcprivacy"
fi
if [[ -f "$ROOT_DIR/THIRD-PARTY-NOTICES.md" ]]; then
  cp -f "$ROOT_DIR/THIRD-PARTY-NOTICES.md" "$RESOURCES_DIR/THIRD-PARTY-NOTICES.md"
fi

if [[ "${SIGN_ADHOC:-}" == "1" ]]; then
  echo "[sign] Ad-hoc signing for local run (Notify Entitlements)"
  ENTITLEMENTS="$ROOT_DIR/assets/CodMate-Notify.entitlements"
  
  # Sign inner binaries first
  if [[ -f "$APP_DIR/Contents/Resources/bin/codmate-notify" ]]; then
    codesign --force --sign - --entitlements "$ENTITLEMENTS" --timestamp=none \
      "$APP_DIR/Contents/Resources/bin/codmate-notify"
  fi
  
  codesign --force --sign - --entitlements "$ENTITLEMENTS" --timestamp=none \
    "$APP_DIR/Contents/MacOS/CodMate"
    
  # Sign the bundle
  codesign --force --sign - --entitlements "$ENTITLEMENTS" --timestamp=none \
    "$APP_DIR"
fi

echo "[ok] App bundle ready at $APP_DIR"
