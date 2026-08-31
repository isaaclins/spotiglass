# Spotiglass — build and run from the repo root.
# Usage: make | make build    — Debug build
#        make run             — build (if needed) and launch the app
#        make release         — unsigned Release bundle (matches CI layout)
#        make test            — unit tests on macOS

.PHONY: all build run release test coverage coverage-check format lint scan clean list help audit-eq-permission build-driver embed-driver sign-driver install-driver

# Prefer a standalone install, then fall back to the copy inside the active
# Xcode toolchain so `make lint` works without `brew install swift-format`.
SWIFT_FORMAT := $(shell command -v swift-format 2>/dev/null || xcrun --find swift-format 2>/dev/null)

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

# Signing identity for local builds.
#
# Ad-hoc signing pins the designated requirement to the binary's cdhash, which
# changes on every build. The keychain ACL guarding the stored Spotify refresh
# token therefore stops matching after each rebuild and macOS re-prompts for the
# login keychain password - "Always Allow" cannot stick, because the next build
# is a different identity. A certificate-backed identity pins the requirement to
# the certificate instead, which is stable across rebuilds.
#
# Prefers a real Apple Development certificate; falls back to the self-signed
# local identity from scripts/create-local-signing-identity.sh. If neither is
# present the build stays ad-hoc exactly as before, so nothing is required of
# contributors who have not run the script.
LOCAL_SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ { print $$2; exit }')
ifeq ($(strip $(LOCAL_SIGN_IDENTITY)),)
LOCAL_SIGN_IDENTITY := $(shell security find-identity -p codesigning 2>/dev/null | awk '/"Spotiglass Local Dev"/ { print $$2; exit }')
endif
ifneq ($(strip $(LOCAL_SIGN_IDENTITY)),)
ifneq ($(UNSIGNED),1)
CODE_SIGN_FLAGS += CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=$(LOCAL_SIGN_IDENTITY) OTHER_CODE_SIGN_FLAGS=--keychain=$(HOME)/Library/Keychains/login.keychain-db
endif
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
#
# Pass SPOTIGLASS_EQ_DEBUG=1 to compile in verbose driver diagnostic logging
# (per-cycle DoIO / StartIO / OutputCallback events to /tmp). Off by default.
build-driver:
	SPOTIGLASS_EQ_DEBUG=$(SPOTIGLASS_EQ_DEBUG) ./SpotiglassEQDriver/build-driver.sh

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
	echo "  sudo killall coreaudiod"; \
	echo "(or log out and back in)"

# Re-signs build/SpotiglassEQDriver.driver with the user's Apple Development
# identity. The build-driver step leaves the bundle ad-hoc signed (coreaudiod
# rejects ad-hoc on macOS 26). Override CODESIGN_IDENTITY to use a different
# identity. If signing fails with errSecInternalComponent, run
# `bash scripts/setup-eq-driver-signing.sh` first to trust Apple Root CA.
CODESIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning | awk '/Apple Development/ { print $$2; exit }')
sign-driver:
	@if [ -z "$(CODESIGN_IDENTITY)" ]; then \
		echo "No Apple Development identity in keychain. Open Xcode → Settings → Accounts and sign in." >&2; exit 1; \
	fi
	codesign --force --sign "$(CODESIGN_IDENTITY)" build/SpotiglassEQDriver.driver
	@signature=$$(codesign -dv build/SpotiglassEQDriver.driver 2>&1 | grep "TeamIdentifier" | cut -d= -f2); \
	if [ "$$signature" = "not set" ]; then \
		echo "Signature fell back to ad-hoc. Run scripts/setup-eq-driver-signing.sh to trust Apple Root CA, then retry." >&2; \
		exit 1; \
	fi
	@echo "OK: build/SpotiglassEQDriver.driver re-signed."

# Installs the freshly built+signed driver to /Library/Audio/Plug-Ins/HAL/
# (system scope — the only path coreaudiod scans on macOS 26) and reloads
# coreaudiod. Requires sudo.
install-driver: build-driver sign-driver
	sudo rm -rf /Library/Audio/Plug-Ins/HAL/SpotiglassEQDriver.driver
	sudo cp -pR build/SpotiglassEQDriver.driver /Library/Audio/Plug-Ins/HAL/
	sudo killall coreaudiod || true
	@sleep 3
	@echo
	@if system_profiler SPAudioDataType 2>/dev/null | grep -q "Spotiglass EQ"; then \
		echo "OK: coreaudiod loaded the driver. Spotiglass EQ should appear in System Settings → Sound → Output."; \
	else \
		echo "WARNING: coreaudiod did not pick up the driver. Check system logs for the failure reason."; \
	fi

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
	@echo "  make build-driver  — build SpotiglassEQDriver.driver (universal Mach-O)"
	@echo "  make embed-driver  — build + embed .driver inside the Debug app"
	@echo "  make sign-driver   — re-sign build/SpotiglassEQDriver.driver with Apple Dev cert"
	@echo "  make install-driver — build, sign, sudo-install to /Library/Audio/Plug-Ins/HAL/, reload coreaudiod"
	@echo "Vars: UNSIGNED=1 (CODE_SIGNING_ALLOWED=NO); XCODE_EXTRA for extra settings"
