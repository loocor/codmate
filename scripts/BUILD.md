# CodMate Build Scripts (SwiftPM)

This directory contains scripts for building CodMate using SwiftPM and packaging a notarized DMG.

## Quick Start

### Build the .app bundle
```bash
VER=1.2.3 ./scripts/create-app-bundle.sh
```

### Build a Developer ID DMG (optional notarization)
```bash
VER=1.2.3 ./scripts/macos-build-notarized-dmg.sh
```

## Script Overview

### 1) `create-app-bundle.sh`
**Purpose**: Build a SwiftPM release binary, compile assets, and assemble a macOS .app bundle.

**Outputs**:
- `build/CodMate.app` (default, override with `APP_DIR`)

**Notes**:
- Compiles `assets/Assets.xcassets` with `xcrun actool` into `Assets.car` (includes AppIcon).
- Copies bundled resources into `Contents/Resources`:
  - `payload/providers.json`
  - `payload/terminals.json`
  - `PrivacyInfo.xcprivacy`
  - `THIRD-PARTY-NOTICES.md`
  - `codmate-notify` helper into `Contents/Resources/bin/`

**Usage Examples**:
```bash
VER=1.2.3 ./scripts/create-app-bundle.sh
ARCH_MATRIX="arm64" VER=1.2.3 ./scripts/create-app-bundle.sh
APP_DIR=build/CodMate.app VER=1.2.3 ./scripts/create-app-bundle.sh
```

---

### 2) `macos-build-notarized-dmg.sh`
**Purpose**: Build and optionally notarize a Developer ID DMG for direct distribution.

**Output**: `.dmg` files per architecture (e.g., `codmate-arm64.dmg`)

**Usage Examples**:
```bash
VER=1.2.3 ./scripts/macos-build-notarized-dmg.sh

# Notarize with a keychain profile
APPLE_NOTARY_PROFILE="AC_PROFILE" VER=1.2.3 ./scripts/macos-build-notarized-dmg.sh

# Notarize with Apple ID
APPLE_ID="your@apple.id" \
APPLE_PASSWORD="xxxx-xxxx-xxxx-xxxx" \
TEAM_ID="YOURTEAMID" \
VER=1.2.3 ./scripts/macos-build-notarized-dmg.sh
```

---

### 3) `make notices`
**Purpose**: Regenerate `THIRD-PARTY-NOTICES.md` from resolved dependencies.

**Notes**:
- Scans `Package.resolved` and local checkouts in `.build/checkouts`.
- Fails if any dependency is missing a license file.

---

## Environment Variables

### Common
| Variable | Default | Description |
|----------|---------|-------------|
| `VER` | _required_ | Marketing version (e.g., `1.2.3`) |
| `BUILD_NUMBER_STRATEGY` | `date` | `date`, `git`, or `counter` |
| `ARCH_MATRIX` | `arm64 x86_64` | Architectures to build |
| `MIN_MACOS` | `13.5` | Minimum macOS version |
| `BUILD_DIR` | `build` | Build workspace |
| `APP_DIR` | `build/CodMate.app` | Output .app path |
| `BUNDLE_ID` | `ai.umate.codmate` | Bundle identifier |
| `OUTPUT_DIR` | `artifacts` | DMG output directory (e.g., `codmate-arm64.dmg`) |
| `STRIP` | `1` | Set to `0` to disable binary stripping |
| `STRIP_FLAGS` | `-x` | Flags passed to `strip` |

### Signing / Notarization
| Variable | Default | Description |
|----------|---------|-------------|
| `SIGNING_CERT` | `Developer ID Application` | Signing certificate name |
| `SANDBOX` | `off` | `on` to apply `assets/CodMate.entitlements` |
| `APPLE_NOTARY_PROFILE` | - | Keychain profile for notarization |
| `APPLE_ID` / `APPLE_PASSWORD` / `TEAM_ID` | - | Apple ID credentials for notarization |

---

## Prerequisites
- macOS 13.5+
- Swift 6 toolchain
- Xcode Command Line Tools (for `xcrun` + `actool`)
- (Optional) `create-dmg` for a nicer DMG layout
