.PHONY: help build release test app dmg clean run notices

APP_NAME := CodMate
BUILD_NUMBER_STRATEGY ?= date
APP_DIR ?= build/CodMate.app
OUTPUT_DIR ?= artifacts/release

# Default arch for local builds
ARCH_NATIVE := $(shell uname -m)
ARCH ?= $(ARCH_NATIVE)

help: ## Show this help message
	@echo "CodMate - macOS SwiftPM App"
	@echo ""
	@echo "Available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

build: ## SwiftPM debug build
	@swift build

release: ## SwiftPM release build
	@swift build -c release

test: ## Run SwiftPM tests (if any)
	@swift test

notices: ## Update THIRD-PARTY-NOTICES.md
	@python3 scripts/gen-third-party-notices.py

app: ## Build CodMate.app (ARCH=arm64|x86_64|"arm64 x86_64")
	@if [ -z "$(VER)" ]; then echo "error: VER is required (e.g., VER=1.2.3)"; exit 1; fi
	@VER=$(VER) BUILD_NUMBER_STRATEGY=$(BUILD_NUMBER_STRATEGY) \
	ARCH_MATRIX="$(ARCH)" APP_DIR=$(APP_DIR) \
	./scripts/create-app-bundle.sh

run: app ## Build and launch CodMate.app
	@open "$(APP_DIR)"

dmg: ## Build Developer ID DMG (ARCH=arm64|x86_64|"arm64 x86_64")
	@if [ -z "$(VER)" ]; then echo "error: VER is required (e.g., VER=1.2.3)"; exit 1; fi
	@VER=$(VER) BUILD_NUMBER_STRATEGY=$(BUILD_NUMBER_STRATEGY) \
	ARCH_MATRIX="$(ARCH)" APP_DIR=$(APP_DIR) OUTPUT_DIR=$(OUTPUT_DIR) \
	./scripts/macos-build-notarized-dmg.sh

clean: ## Clean build artifacts
	@rm -rf .build build $(APP_DIR) artifacts
