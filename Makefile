# Spotiglass — build and run from the repo root.
# Usage: make | make build    — Debug build
#        make run             — build (if needed) and launch the app
#        make release         — unsigned Release bundle (matches CI layout)
#        make test            — unit tests on macOS

.PHONY: all build run release test coverage coverage-check format lint scan clean list help audit-eq-permission build-driver embed-driver

SWIFT_FORMAT := $(shell command -v swift-format 2>/dev/null)

PROJECT       := Spotiglass.xcodeproj
SCHEME        := Spotiglass
DESTINATION   := platform=macOS
DERIVED_DATA  := build/DerivedData
DEBUG_APP     := $(DERIVED_DATA)/Build/Products/Debug/Spotiglass.app
RELEASE_APP   := $(DERIVED_DATA)/Build/Products/Release/Spotiglass.app

# Must match KeychainRefreshTokenStore.service in Spotiglass/Persistence/AuthPersistence.swift
KEYCHAIN_SERVICE := com.isaaclins.spotiglass.spotify-auth

# Optional: UNSIGNED=1 → CODE_SIGNING_ALLOWED=NO (see docs/building-and-testing.md).
CODE_SIGN_FLAGS :=
ifeq ($(UNSIGNED),1)
CODE_SIGN_FLAGS += CODE_SIGNING_ALLOWED=NO
endif

# Extra xcodebuild settings, e.g. XCODE_EXTRA='CODE_SIGN_IDENTITY=-'
XCODE_EXTRA ?=

all: build

list:
	xcodebuild -list -project $(PROJECT)

build:
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration Debug \
		-destination '$(DESTINATION)' \
		-derivedDataPath $(DERIVED_DATA) \
		$(CODE_SIGN_FLAGS) \
		$(XCODE_EXTRA) \
		build

# Opens the Debug app from the same derived data path as `make build`.
run: build
	open "$(DEBUG_APP)"

release:
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration Release \
		-destination 'generic/platform=macOS' \
		-derivedDataPath $(DERIVED_DATA) \
		CODE_SIGNING_ALLOWED=NO \
		$(XCODE_EXTRA) \
		clean build

# Greps the codebase for banned mic / audio-recording APIs. Always runs
# before `make test`, and is safe to invoke standalone.
audit-eq-permission:
	./scripts/eq-mic-permission-audit.sh

# Builds SpotiglassEQDriver.driver as a universal Mach-O bundle (no Xcode
# target needed). Output: build/SpotiglassEQDriver.driver
build-driver:
	./SpotiglassEQDriver/build-driver.sh

# Builds the .driver and copies it into the Debug Spotiglass.app at
# Contents/Library/Audio/Plug-Ins/HAL/. After this, the app's
# EqualizerHALPluginController can find and install the embedded driver.
#
# IMPORTANT: cp -pR preserves the source file's mtime so the kernel's
# code-signing check (cs_mtime vs file mtime) keeps passing after the copy.
# Plain `cp -R` would bump the mtime and the kernel would refuse to map the
# binary with "rejecting invalid page ... cs_mtime != mtime".
embed-driver: build build-driver
	@dst="$(DEBUG_APP)/Contents/Library/Audio/Plug-Ins/HAL"; \
	mkdir -p "$$dst"; \
	rm -rf "$$dst/SpotiglassEQDriver.driver"; \
	cp -pR build/SpotiglassEQDriver.driver "$$dst/"; \
	echo "embedded → $$dst/SpotiglassEQDriver.driver"; \
	echo; \
	echo "To activate after first launch:"; \
	echo "  sudo launchctl kickstart -k system/com.apple.audio.coreaudiod"; \
	echo "(or log out and back in)"

test: audit-eq-permission
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-destination '$(DESTINATION)' \
		-derivedDataPath $(DERIVED_DATA) \
		-parallel-testing-enabled NO \
		$(CODE_SIGN_FLAGS) \
		$(XCODE_EXTRA) \
		test

coverage:
	./scripts/coverage.sh

coverage-check: coverage
	./scripts/check-coverage-per-file.sh

format:
ifndef SWIFT_FORMAT
	@echo "swift-format not found. Install with: brew install swift-format" >&2
	@exit 1
endif
	@find Spotiglass SpotiglassTests -name '*.swift' -print0 | xargs -0 "$(SWIFT_FORMAT)" format -i -r --configuration .swift-format

lint:
ifndef SWIFT_FORMAT
	@echo "swift-format not found. Install with: brew install swift-format" >&2
	@exit 1
endif
	@find Spotiglass SpotiglassTests -name '*.swift' -print0 | xargs -0 "$(SWIFT_FORMAT)" lint --strict --configuration .swift-format

scan:
	periphery scan \
		--project $(PROJECT) \
		--schemes $(SCHEME) \
		--targets $(SCHEME); \
		periphery_exit=$$?; \
		tokei .; \
		tokei_exit=$$?; \
		if [ $$periphery_exit -ne 0 ]; then exit $$periphery_exit; fi; \
		exit $$tokei_exit
clean:
	rm -rf "$(DERIVED_DATA)"
	@echo "Removing Keychain generic-password items with service $(KEYCHAIN_SERVICE)…"
	@svc="$(KEYCHAIN_SERVICE)"; \
	while security delete-generic-password -s "$$svc" >/dev/null 2>&1; do :; done

help:
	@echo "Targets:"
	@echo "  make / make build  — Debug build → $(DEBUG_APP)"
	@echo "  make run           — build and open Debug app"
	@echo "  make release       — unsigned Release → $(RELEASE_APP)"
	@echo "  make test          — unit tests"
	@echo "  make coverage      — unit tests with code coverage report"
	@echo "  make coverage-check — coverage + per-file gate (see scripts/coverage-allowlist.json)"
	@echo "  make format        — in-place swift-format (requires brew install swift-format)"
	@echo "  make lint          — swift-format lint --strict"
	@echo "  make scan          — periphery (dead code) + tokei (LOC); both run even if one fails"
	@echo "  make list          — list schemes"
	@echo "  make clean         — remove $(DERIVED_DATA) + Keychain items (service $(KEYCHAIN_SERVICE))"
	@echo "Vars: UNSIGNED=1 (CODE_SIGNING_ALLOWED=NO); XCODE_EXTRA for extra settings"
