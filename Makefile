# GearUp developer tasks.
#
#   make build   — compile every target
#   make test    — run the unit checks
#   make probe   — build and run the Phase 0 Click V2 diagnostic
#   make app     — assemble and sign .build/GearUp.app
#   make run     — build the app and open it
#   make smoke   — launch the app and check that it really came up
#   make clean   — remove build artefacts
#
# Extra probe flags go through ARGS, e.g.:
#   make probe ARGS="--all"
#   make probe ARGS="--seconds 20 --duration 90"

ARGS ?=

.PHONY: build test probe probe-app app run smoke clean lint

build:
	swift build

test:
	swift run GearUpChecks

probe:
	./scripts/run-probe.sh $(ARGS)

probe-app:
	./scripts/build-probe.sh

app:
	./scripts/build-app.sh

run: app
	open .build/GearUp.app

smoke:
	./scripts/smoke.sh $(ARGS)

clean:
	swift package clean
	rm -rf .build/GearUp.app .build/GearUpProbe.app

lint:
	swift build -Xswiftc -warnings-as-errors
