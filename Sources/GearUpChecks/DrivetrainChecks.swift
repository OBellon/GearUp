import GearUpCore

func runDrivetrainChecks(_ checks: Checks) {
    checks.group("Drivetrain") {
        checks.equal(Drivetrain().gearCount, 30, "the default readout has MyWhoosh's 30 gears")
        checks.equal(Drivetrain().currentGear, 15, "the default readout starts in gear 15, like a MyWhoosh ride")

        var defaultReset = Drivetrain(gearCount: 30, currentGear: 3)
        defaultReset.reset()
        checks.equal(defaultReset.currentGear, 15, "an argument-less reset goes back to the starting gear")

        checks.equal(Drivetrain(gearCount: 12, currentGear: 1).currentGear, 1, "the starting gear is kept")
        checks.equal(Drivetrain(gearCount: 12, currentGear: 99).currentGear, 12, "a too-high gear is clamped")
        checks.equal(Drivetrain(gearCount: 999, currentGear: 1).gearCount, 30, "the gear count is capped")
        checks.equal(Drivetrain(gearCount: 0, currentGear: 1).gearCount, 1, "the gear count has a floor")

        var drivetrain = Drivetrain(gearCount: 3, currentGear: 1)
        checks.equal(drivetrain.shiftUp(), 2, "shift up from the bottom")
        checks.equal(drivetrain.shiftUp(), 3, "shift up to the top")
        checks.equal(drivetrain.shiftUp(), 3, "shifting up at the top does nothing")
        checks.expect(drivetrain.isAtTopGear, "the drivetrain reports the top gear")

        checks.equal(drivetrain.shiftDown(), 2, "shift down from the top")
        checks.equal(drivetrain.shiftDown(), 1, "shift down to the bottom")
        checks.equal(drivetrain.shiftDown(), 1, "shifting down at the bottom does nothing")
        checks.expect(drivetrain.isAtBottomGear, "the drivetrain reports the bottom gear")

        var shrinking = Drivetrain(gearCount: 12, currentGear: 11)
        shrinking.setGearCount(5)
        checks.equal(shrinking.gearCount, 5, "the new gear count is applied")
        checks.equal(shrinking.currentGear, 5, "the current gear follows the new range")

        var reset = Drivetrain(gearCount: 12, currentGear: 7)
        reset.reset(to: 4)
        checks.equal(reset.currentGear, 4, "the gear can be reset")

        checks.equal(ButtonAction.shiftUp.title, "Shift Up", "shift up title")
        checks.equal(ButtonAction.shiftDown.title, "Shift Down", "shift down title")
    }
}
