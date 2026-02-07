#!/usr/bin/env bash

set -euo pipefail

# CodMate macOS notarized DMG builder (SwiftPM)
# - Builds app bundle via scripts/create-app-bundle.sh
# - Signs app (Developer ID)
# - Creates DMG
# - Notarizes + staples (optional)
#
# Usage:
#   VER=1.2.3 ./scripts/macos-build-notarized-dmg.sh
#
# Optional overrides:
#   ARCH_MATRIX="arm64 x86_64"
#   OUTPUT_DIR=artifacts
#   SIGNING_CERT="Developer ID Application"
#   SANDBOX=on|off (default: off)
#   SKIP_NOTARIZATION=1
#   APPLE_NOTARY_PROFILE="AC_PROFILE"
#   APPLE_ID / APPLE_PASSWORD / TEAM_ID

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/artifacts}"
APP_NAME="CodMate"
APP_DIR="${APP_DIR:-$BUILD_DIR/CodMate.app}"
ENTITLEMENTS_PATH="${ENTITLEMENTS_PATH:-$ROOT_DIR/assets/CodMate.entitlements}"
ARCH_MATRIX=( ${ARCH_MATRIX:-arm64 x86_64} )
MIN_MACOS="${MIN_MACOS:-13.5}"
BUNDLE_ID="${BUNDLE_ID:-ai.umate.codmate}"

mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

# Load .env without overriding explicitly exported vars
ENV_FILE="$ROOT_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
  while IFS='=' read -r k v; do
    [[ -z "${k// /}" ]] && continue
    [[ "$k" =~ ^# ]] && continue
    case "$k" in
      APPLE_SIGNING_IDENTITY|APPLE_ID|APPLE_PASSWORD|APPLE_TEAM_ID)
        if [[ -z "${!k:-}" ]]; then
          v="${v%\r}"; v="${v%\n}"; v="${v%\"}"; v="${v#\"}"
          export "$k=$v"
        fi
        ;;
      *) ;;
    esac
  done < "$ENV_FILE"
fi

VER="${VER:-}"
if [[ -z "$VER" ]]; then
  echo "[error] VER is required. Example: VER=1.2.3 ./scripts/macos-build-notarized-dmg.sh" >&2
  exit 1
fi

BUILD_NUMBER_STRATEGY="${BUILD_NUMBER_STRATEGY:-date}"
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

BUILD_NUMBER="${BUILD_NUMBER:-$(compute_build_number)}"
DISPLAY_VERSION="${VER}+${BUILD_NUMBER}"

SANDBOX="${SANDBOX:-off}"

TEAM_ID="${TEAM_ID:-${APPLE_TEAM_ID:-}}"
SIGNING_CERT="${SIGNING_CERT:-${APPLE_SIGNING_IDENTITY:-}}"
if [[ -z "$SIGNING_CERT" ]]; then
  SIGNING_CERT="Developer ID Application"
fi

CODESIGN_IDENTITY=""
if security find-identity -v -p codesigning | grep -q "$SIGNING_CERT"; then
  CODESIGN_IDENTITY="$(security find-identity -v -p codesigning | grep "$SIGNING_CERT" | head -1 | sed 's/.*"\(.*\)".*/\1/')"
else
  echo "[warn] Signing identity not found ($SIGNING_CERT). Falling back to ad-hoc signature."
fi

unset ENTITLEMENTS_ARG
if [[ "$SANDBOX" == "on" ]]; then
  ENTITLEMENTS_ARG=(--entitlements "$ENTITLEMENTS_PATH")
fi

NOTARY_MODE="${NOTARY_MODE:-auto}"
if [[ "${SKIP_NOTARIZATION:-}" == "1" || "$NOTARY_MODE" == "none" ]]; then
  NOTARY_MODE="none"
elif [[ "$NOTARY_MODE" == "profile" ]]; then
  if [[ -z "${APPLE_NOTARY_PROFILE:-}" ]]; then
    echo "[error] NOTARY_MODE=profile requires APPLE_NOTARY_PROFILE" >&2
    exit 1
  fi
elif [[ "$NOTARY_MODE" == "apple" ]]; then
  if [[ -z "${APPLE_ID:-}" || -z "${APPLE_PASSWORD:-}" || -z "$TEAM_ID" ]]; then
    echo "[error] NOTARY_MODE=apple requires APPLE_ID, APPLE_PASSWORD, and TEAM_ID" >&2
    exit 1
  fi
else
  NOTARY_MODE="none"
  if [[ -n "${APPLE_NOTARY_PROFILE:-}" ]]; then
    NOTARY_MODE="profile"
  elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_PASSWORD:-}" && -n "$TEAM_ID" ]]; then
    NOTARY_MODE="apple"
  fi
fi

if [[ "$NOTARY_MODE" != "none" && -z "$CODESIGN_IDENTITY" ]]; then
  echo "[warn] Notarization requires a Developer ID signing identity. Disabling notarization." >&2
  NOTARY_MODE="none"
fi

echo "=========================================="
echo "  CodMate - Developer ID DMG (SwiftPM)"
echo "=========================================="
echo "Version: $DISPLAY_VERSION"
echo "Architectures: ${ARCH_MATRIX[*]}"
echo "Output: $OUTPUT_DIR"
echo "SANDBOX: $SANDBOX"
echo "=========================================="

build_dmg_for_arch() {
  local arch="$1"
  local arch_app_dir="$APP_DIR"
  local arch_suffix="$arch"
  local dmg_name="codmate-${arch_suffix}.dmg"
  local dmg_path="$OUTPUT_DIR/$dmg_name"
  local stage_dir="$BUILD_DIR/.stage-dmg-${arch_suffix}"
  local bundle_name="CodMate.app"

  if [[ ${#ARCH_MATRIX[@]} -gt 1 ]]; then
    arch_app_dir="$BUILD_DIR/CodMate-${arch_suffix}.app"
  fi

  echo "[build] Building app bundle for $arch_suffix"
  VER="$VER" \
  BUILD_NUMBER="$BUILD_NUMBER" \
  ARCH_MATRIX="$arch" \
  APP_DIR="$arch_app_dir" \
  BUILD_DIR="$BUILD_DIR" \
  MIN_MACOS="$MIN_MACOS" \
  BUNDLE_ID="$BUNDLE_ID" \
  "$ROOT_DIR/scripts/create-app-bundle.sh"

  if [[ ! -d "$arch_app_dir" ]]; then
    echo "[error] App bundle not found at $arch_app_dir" >&2
    exit 1
  fi

  if [[ -n "$CODESIGN_IDENTITY" ]]; then
    echo "[sign] Signing with: $CODESIGN_IDENTITY"
    xattr -cr "$arch_app_dir"

    if [[ -f "$arch_app_dir/Contents/Resources/bin/codmate-notify" ]]; then
      codesign --force --sign "$CODESIGN_IDENTITY" --options runtime --timestamp \
        ${ENTITLEMENTS_ARG[@]+"${ENTITLEMENTS_ARG[@]}"} \
        "$arch_app_dir/Contents/Resources/bin/codmate-notify"
    fi

    codesign --force --sign "$CODESIGN_IDENTITY" --options runtime --timestamp \
      ${ENTITLEMENTS_ARG[@]+"${ENTITLEMENTS_ARG[@]}"} \
      "$arch_app_dir/Contents/MacOS/CodMate"

    codesign --force --sign "$CODESIGN_IDENTITY" --options runtime --timestamp \
      ${ENTITLEMENTS_ARG[@]+"${ENTITLEMENTS_ARG[@]}"} \
      "$arch_app_dir"

    codesign --verify --deep --strict --verbose=2 "$arch_app_dir"
  else
    echo "[warn] No signing identity found. Using ad-hoc signature."
    codesign --force --deep --sign - "$arch_app_dir"
  fi

  rm -rf "$stage_dir"
  mkdir -p "$stage_dir"
  cp -R "$arch_app_dir" "$stage_dir/$bundle_name"
  ln -s /Applications "$stage_dir/Applications"

  if command -v create-dmg >/dev/null 2>&1; then
    echo "[dmg] Using create-dmg"
    if (cd "$stage_dir" && create-dmg \
      --volname "$APP_NAME" \
      --window-pos 200 120 \
      --window-size 600 400 \
      --icon-size 100 \
      --icon "$bundle_name" 175 120 \
      --hide-extension "$bundle_name" \
      --app-drop-link 425 120 \
      "$dmg_path" \
      "$bundle_name"); then
      :
    else
      echo "[warn] create-dmg failed; falling back to hdiutil"
      hdiutil create -volname "$APP_NAME" -srcfolder "$stage_dir" -ov -format UDZO -imagekey zlib-level=9 "$dmg_path"
    fi
  else
    echo "[dmg] Using hdiutil"
    hdiutil create -volname "$APP_NAME" -srcfolder "$stage_dir" -ov -format UDZO -imagekey zlib-level=9 "$dmg_path"
  fi

  rm -rf "$stage_dir"

  if [[ ! -f "$dmg_path" ]]; then
    echo "[error] DMG not created: $dmg_path" >&2
    exit 1
  fi

  local notarized=0
  case "$NOTARY_MODE" in
    profile)
      echo "[notary] Submitting with profile ${APPLE_NOTARY_PROFILE:-}"
      notarized=1
      xcrun notarytool submit "$dmg_path" --keychain-profile "${APPLE_NOTARY_PROFILE:-}" --wait
      xcrun stapler staple "$dmg_path" || true
      xcrun stapler staple "$arch_app_dir" || true
      ;;
    apple)
      echo "[notary] Submitting with Apple ID"
      notarized=1
      xcrun notarytool submit "$dmg_path" \
        --apple-id "${APPLE_ID:-}" \
        --team-id "$TEAM_ID" \
        --password "${APPLE_PASSWORD:-}" \
        --wait
      xcrun stapler staple "$dmg_path" || true
      xcrun stapler staple "$arch_app_dir" || true
      ;;
    *)
      echo "[notary] Skipping notarization (credentials not provided)"
      ;;
  esac

  if [[ "$notarized" == "1" ]]; then
    echo "[verify] Validating notarization"
    xcrun stapler validate "$dmg_path"
    xcrun stapler validate "$arch_app_dir"
  fi

  echo "[ok] DMG ready: $dmg_path"
}

if [[ ${#ARCH_MATRIX[@]} -eq 1 ]]; then
  build_dmg_for_arch "${ARCH_MATRIX[0]}"
else
  for arch in "${ARCH_MATRIX[@]}"; do
    build_dmg_for_arch "$arch"
  done
fi
