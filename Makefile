# Eikon: the entry point for every build task. Recipes call scripts; the
# logic lives in scripts/. Python always runs through uv.

SHELL := /bin/bash
.DEFAULT_GOAL := help

# A target whose recipe arrives in a later section. Fails so nothing passes silently.
stub = echo "$@: not implemented yet (section $(1))" >&2; exit 1

.PHONY: help doctor bootstrap version generated project check \
	test test-swift test-scripts archive ipa tipa deb package verify all \
	publish apply-patches unpatch clean

help:
	@echo "Targets: doctor bootstrap version generated project check test test-swift"
	@echo "         test-scripts archive ipa tipa deb package verify all publish"
	@echo "         apply-patches unpatch clean"

doctor:
	@scripts/doctor.sh

# Installs software with Homebrew. Run only when you mean to.
bootstrap:
	@scripts/bootstrap.sh

version:
	@scripts/version.sh

generated: version
	@if [ -f scripts/credits.py ]; then \
		uv run scripts/credits.py app-json build/generated/Acknowledgements.json; \
	else \
		echo "generated: skipping acknowledgements, scripts/credits.py not added yet (section 04)"; \
	fi

project: generated
	@$(call stub,02)

check:
	@if [ -f scripts/credits.py ]; then \
		uv run scripts/credits.py check; \
	else \
		echo "check: skipping credits check, scripts/credits.py not added yet (section 04)"; \
	fi
	@scripts/version.sh --check

test: test-swift test-scripts

test-swift:
	@if [ -f project.yml ]; then \
		$(call stub,02); \
	else \
		echo "test-swift: skipping, project.yml not added yet (section 02)"; \
	fi

test-scripts:
	@uv run pytest tests/

archive:
	@$(call stub,10)

ipa tipa deb:
	@$(call stub,10)

package:
	@$(call stub,10)

verify:
	@$(call stub,10)

all: check test archive package verify

publish:
	@$(call stub,11)

apply-patches unpatch:
	@$(call stub,03)

clean:
	rm -rf build dist
