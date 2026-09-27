# Eikon: the entry point for every build task. Recipes call scripts; the
# logic lives in scripts/. Python always runs through uv.

SHELL := /bin/bash
.DEFAULT_GOAL := help

# A target whose recipe arrives in a later section. Fails so nothing passes silently.
stub = echo "$@: not implemented yet (section $(1))" >&2; exit 1

.PHONY: help doctor bootstrap version generated project check \
	test test-swift test-scripts archive ipa tipa deb package verify all \
	publish fetch-deps verify-deps pin-dep clean

help:
	@echo "Targets: doctor bootstrap version generated project check test test-swift"
	@echo "         test-scripts archive ipa tipa deb package verify all publish"
	@echo "         fetch-deps verify-deps pin-dep NAME=<name> TAG=<tag> [ASSET=<asset>] clean"

doctor:
	@scripts/doctor.sh

# Installs software with Homebrew. Run only when you mean to.
bootstrap:
	@scripts/bootstrap.sh

version:
	@scripts/version.sh

ACKNOWLEDGEMENTS := build/generated/Acknowledgements.json

generated: version
	@uv run scripts/credits.py app-json $(ACKNOWLEDGEMENTS)

# The app bundles the generated acknowledgements; project.yml takes the path
# from the environment, so always generate the project through make.
project: generated
	@EIKON_ACKNOWLEDGEMENTS_JSON=$(ACKNOWLEDGEMENTS) xcodegen generate --quiet

check:
	@uv run scripts/credits.py check
	@uv run scripts/deps.py check
	@scripts/version.sh --check

test: test-swift test-scripts

test-swift: project
	@scripts/test_swift.sh

test-scripts:
	@uv run pytest tests/

archive:
	@scripts/archive.sh

ipa tipa deb: archive
	@scripts/package.sh $@

# Clear dist/ first so only this build is packaged, summed and verified.
package: archive
	@rm -rf dist
	@$(MAKE) ipa tipa deb
	@cd dist && shasum -a 256 Eikon-*.ipa Eikon-*.tipa *.deb > SHA256SUMS
	@echo "package: wrote dist/SHA256SUMS"

verify:
	@uv run scripts/verify_artifacts.py dist/

all: check test archive package verify

publish:
	@$(call stub,11)

# Prebuilt libraries from the forks' GitHub releases (see third_party/README.md).
fetch-deps:
	@uv run scripts/deps.py fetch

verify-deps:
	@uv run scripts/deps.py verify

pin-dep:
	@test -n "$(NAME)" -a -n "$(TAG)" || { echo "usage: make pin-dep NAME=<name> TAG=<tag> [ASSET=<asset>]" >&2; exit 1; }
	@uv run scripts/deps.py pin "$(NAME)" --tag "$(TAG)" $(if $(ASSET),--asset "$(ASSET)")

clean:
	rm -rf build dist
