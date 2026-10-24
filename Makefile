# GearUp developer tasks.
#
#   make build   — compile every target
#   make test    — run the unit checks
#   make probe   — build and run the Phase 0 Click V2 diagnostic
#   make signing — create GearUp's local signing identity (once per Mac)
#   make app     — assemble and sign .build/GearUp.app
#   make run     — build the app and open it
#   make icon    — redraw the app icon and pack Resources/GearUp.icns
#   make smoke   — launch the app and check that it really came up
#   make report  — summarise a ride from the log (FROM=12:05 TO=13:40)
#   make clean   — remove build artefacts
#
# Extra probe flags go through ARGS, e.g.:
#   make probe ARGS="--all"
#   make probe ARGS="--seconds 20 --duration 90"

ARGS ?=

.PHONY: build test probe probe-app signing app run icon smoke report clean lint

# The icon is drawn by scripts/make-icon.swift; `make icon ICON_VARIANT=bike`
# (or drivetrain) swaps the motif.
ICON_VARIANT ?= gear

build:
	swift build

test:
	swift run GearUpChecks

signing:
	./scripts/setup-signing.sh

probe:
	./scripts/run-probe.sh $(ARGS)

probe-app:
	./scripts/build-probe.sh

app:
	./scripts/build-app.sh

run: app
	open .build/GearUp.app

# Every size is drawn from the model rather than resampled from one bitmap, so
# the teeth stay sharp in the Dock and in Finder.
icon:
	mkdir -p Resources
	swift scripts/make-icon.swift --variant $(ICON_VARIANT) --iconset .build/Icon.iconset
	iconutil -c icns .build/Icon.iconset -o Resources/GearUp.icns
	swift scripts/make-icon.swift --variant $(ICON_VARIANT) --out Design/icon.png
	@echo "==> Resources/GearUp.icns from the $(ICON_VARIANT) motif"

smoke:
	./scripts/smoke.sh $(ARGS)

# Shifts, dropped shifts, battery drain and link resets for one ride. Times are
# the wall clock the log prints; TO is optional.
report:
	python3 scripts/ride-report.py --from $(FROM) $(if $(TO),--to $(TO))

clean:
	swift package clean
	rm -rf .build/GearUp.app .build/GearUpProbe.app

lint:
	swift build -Xswiftc -warnings-as-errors
