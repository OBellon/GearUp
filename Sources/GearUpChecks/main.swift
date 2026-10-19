import Foundation

// GearUpChecks — the unit checks for GearUpCore.
//
// XCTest ships with Xcode, which GearUp does not require, so these are plain
// functions collected by a tiny reporting helper. Run with `make test`.

let checks = Checks.shared

print("GearUp checks")
print("Running against GearUpCore")

runOpenBikeChecks(checks)
runZwiftChecks(checks)
runDrivetrainChecks(checks)
runShiftRouterChecks(checks)
runSettingsChecks(checks)
runOpenBikeBridgeChecks(checks)

exit(checks.report())
