# Common dev commands. Run `make help` for the menu.

.DEFAULT_GOAL := help
SHELL := /usr/bin/env bash
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c

# Override via `make release VERSION=0.2.0`.
VERSION ?= 0.0.0-dev
ARCH    ?= arm64

.PHONY: help build run debug release bundle clean test lint format logo ci-local

help:  ## Show this help.
	@grep -E '^[a-zA-Z_-]+:.*?##' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?##"}; {printf "\033[36m%-12s\033[0m %s\n", $$1, $$2}'

build:  ## swift build (debug).
	swift build

run:  ## swift build + open the debug binary.
	swift build
	open .build/debug/Kiln

release:  ## swift build -c release.
	swift build -c release

bundle:  ## Build a Kiln.app bundle: `make bundle VERSION=0.2.0 ARCH=arm64`.
	./scripts/make-app-bundle.sh $(VERSION) $(ARCH)

clean:  ## Wipe SPM build + dist artifacts.
	rm -rf .build dist

test:  ## Run tests (there aren't many yet).
	swift test

lint:  ## swift-format --lint (read-only).
	swift-format lint --configuration .swift-format --recursive --strict Sources

format:  ## swift-format --in-place (rewrites files).
	swift-format format --configuration .swift-format --recursive --in-place Sources

logo:  ## Re-render the brand mark from the SF Symbol source.
	swift scripts/render-logo.swift

ci-local:  ## Run what CI runs, locally, end-to-end.
	$(MAKE) lint
	swift build -c release
	$(MAKE) bundle ARCH=arm64
	$(MAKE) bundle ARCH=x86_64
