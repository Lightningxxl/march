.PHONY: help all setup deps build fmt fmt-check lint test coverage ci dialyzer verify

MIX ?= mix

help:
	@echo "Targets: setup, deps, build, fmt, fmt-check, lint, test, coverage, dialyzer, verify, ci, all"

setup:
	$(MIX) setup

deps:
	$(MIX) deps.get

build:
	$(MIX) build

fmt:
	$(MIX) format

fmt-check:
	$(MIX) format --check-formatted

lint:
	$(MIX) lint

coverage:
	$(MIX) test --cover

test:
	$(MIX) test

dialyzer:
	$(MIX) deps.get
	$(MIX) dialyzer --format short

verify:
	$(MAKE) setup
	$(MAKE) build
	$(MAKE) fmt-check
	$(MAKE) test

ci: verify

all: verify
