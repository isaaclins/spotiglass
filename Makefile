# Spotiglass — build and run from the repo root.
# Usage: make | make build    — Debug build
#        make run             — build (if needed) and launch the app
#        make release         — unsigned Release bundle (matches CI layout)
#        make test            — unit tests on macOS

.PHONY: all build run release test clean list help

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

test:
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-destination '$(DESTINATION)' \
		-derivedDataPath $(DERIVED_DATA) \
		$(CODE_SIGN_FLAGS) \
		$(XCODE_EXTRA) \
		test

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
	@echo "  make list          — list schemes"
	@echo "  make clean         — remove $(DERIVED_DATA) + Keychain items (service $(KEYCHAIN_SERVICE))"
	@echo "Vars: UNSIGNED=1 (CODE_SIGNING_ALLOWED=NO); XCODE_EXTRA for extra settings"
