FEATUREVISOR_PROJECT ?= ../featurevisor/examples/example-1

.PHONY: deps format format-check compile test credo dialyzer docs package check escript test-example-1

deps:
	mix deps.get

format:
	mix format

format-check:
	mix format --check-formatted

compile:
	mix compile --warnings-as-errors

test:
	mix test

credo:
	mix credo --strict

dialyzer:
	mix dialyzer

docs:
	mix docs --warnings-as-errors

package:
	mix hex.build

escript:
	mix escript.build

check: format-check compile test credo dialyzer docs package

test-example-1: test escript
	./featurevisor test --projectDirectoryPath=$(FEATUREVISOR_PROJECT) --target=all --target=checkout --onlyFailures
