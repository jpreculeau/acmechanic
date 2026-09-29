SHELL := /bin/bash
SCRIPTS := acmechanic.sh restore.sh config.sh $(wildcard lib/*.sh) $(wildcard locale/*.sh) $(wildcard locale/themes/*/*.sh) $(wildcard tests/*.sh) $(wildcard bibliotheque/*/*.sh)

.PHONY: lint test check
lint:
	shellcheck -x $(SCRIPTS)
test:
	tests/run_tests.sh
check: lint test
