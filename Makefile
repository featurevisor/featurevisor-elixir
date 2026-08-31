FEATUREVISOR_PROJECT ?= ../featurevisor/examples/example-1

.PHONY: deps deps-openfeature format format-check compile test test-openfeature credo dialyzer docs docs-openfeature package package-openfeature check check-base check-openfeature escript test-example-1

deps:
	mix deps.get

deps-openfeature:
	cd openfeature && FEATUREVISOR_OPENFEATURE_PATH=.. mix deps.get

format:
	mix format

format-check:
	mix format --check-formatted

compile:
	mix compile --warnings-as-errors

test:
	mix test

test-openfeature:
	cd openfeature && FEATUREVISOR_OPENFEATURE_PATH=.. mix test

credo:
	mix credo --strict

dialyzer:
	mix dialyzer

docs:
	mix docs --warnings-as-errors

docs-openfeature:
	cd openfeature && FEATUREVISOR_OPENFEATURE_PATH=.. mix docs --warnings-as-errors

package:
	mix hex.build

package-openfeature:
	cd openfeature && env -u FEATUREVISOR_OPENFEATURE_PATH mix hex.build

escript:
	mix escript.build

check-base: format-check compile test credo dialyzer docs package

check-openfeature: deps-openfeature
	cd openfeature && mix format --check-formatted
	cd openfeature && FEATUREVISOR_OPENFEATURE_PATH=.. mix compile --warnings-as-errors
	cd openfeature && FEATUREVISOR_OPENFEATURE_PATH=.. mix test
	cd openfeature && FEATUREVISOR_OPENFEATURE_PATH=.. mix credo --strict
	cd openfeature && FEATUREVISOR_OPENFEATURE_PATH=.. mix dialyzer
	cd openfeature && FEATUREVISOR_OPENFEATURE_PATH=.. mix docs --warnings-as-errors
	cd openfeature && env -u FEATUREVISOR_OPENFEATURE_PATH mix hex.build

check: check-base check-openfeature

test-example-1: test escript
	./featurevisor test --projectDirectoryPath=$(FEATUREVISOR_PROJECT) --onlyFailures
