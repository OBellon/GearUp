import SwiftUI
import GearUpCore

struct SettingsView: View {
    @EnvironmentObject private var controller: GearUpController

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    var body: some View {
        Form {
            Section("Shifting") {
                Stepper(value: $controller.settings.gearCount, in: 1...30) {
                    Text("Gears in the readout: \(controller.settings.gearCount)")
                }
                Stepper(value: $controller.settings.startingGear, in: 1...controller.settings.gearCount) {
                    Text("Starting gear: \(controller.settings.startingGear)")
                }
                Text(
                    """
                    MyWhoosh's own shifting has 30 gears and starts every ride in gear 15, so the \
                    readout mirrors that. The gear MyWhoosh shows in the ride HUD is the one that counts.
                    """
                )
                .font(.caption)
                .foregroundStyle(.tertiary)
            }

            Section("Button map") {
                ForEach(ShiftAction.allCases.filter { $0 != .none }, id: \.self) { action in
                    buttonMapRow(for: action)
                }

                Text(
                    """
                    Pick the button that shifts, or press “Press…” and then the button on the puck \
                    itself. Giving an action a button that already does the other one swaps them \
                    over, and nothing shifts while the app waits for a button.
                    """
                )
                .font(.caption)
                .foregroundStyle(.tertiary)

                if controller.learningAction != nil, controller.click.phase != .connected {
                    Label(
                        "The puck is not connected — press a button on it to wake it up.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                Button("Restore defaults") {
                    controller.restoreDefaultButtonMap()
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            Section("Transports") {
                Picker("Offer MyWhoosh", selection: $controller.settings.transportMode) {
                    ForEach(TransportMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)

                ForEach(controller.transports) { transport in
                    LabeledContent(transport.kind.title) {
                        Text(transport.status.detail ?? transport.status.title)
                            .foregroundStyle(transport.status.tint)
                    }
                }

                Text(
                    """
                    MyWhoosh connects over the network transport. Bluetooth is used by other \
                    OpenBikeControl apps and does not need to be on for MyWhoosh.
                    """
                )
                .font(.caption)
                .foregroundStyle(.tertiary)
            }

            Section("Menu bar") {
                Toggle("Show GearUp in the menu bar", isOn: $controller.settings.showInMenuBar)
            }

            Section("About") {
                LabeledContent("GearUp", value: version)
                LabeledContent("Bundle", value: "com.oscar.gearup")
                Text(
                    """
                    GearUp never connects to your trainer. MyWhoosh keeps ownership of resistance \
                    and simply receives virtual shift presses from your Zwift Click V2.
                    """
                )
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // Leaving the screen gives up on a pending "press a button" capture, so
        // a later press on the puck shifts instead of silently reassigning.
        .onDisappear { controller.cancelLearning() }
    }

    // MARK: - Button map

    /// One assignable action: its current button, or the capture prompt while
    /// the app is waiting for a press on the puck.
    @ViewBuilder
    private func buttonMapRow(for action: ShiftAction) -> some View {
        LabeledContent(action.title) {
            if controller.learningAction == action {
                HStack(spacing: 10) {
                    Text("Press a button on the puck…")
                        .foregroundStyle(.secondary)
                    Button("Cancel") { controller.cancelLearning() }
                }
            } else {
                HStack(spacing: 10) {
                    Picker(action.title, selection: buttonBinding(for: action)) {
                        ForEach(buttonOptions(for: action), id: \.self) { button in
                            Text("\(button.displayName)  ·  \(button.maskHex)").tag(button)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)

                    Button("Press…") { controller.learnButton(for: action) }
                }
            }
        }
    }

    /// The picker writes through the controller rather than straight into the
    /// settings, so choosing a button that is already in use swaps the two
    /// actions instead of leaving them on the same button.
    private func buttonBinding(for action: ShiftAction) -> Binding<RideButtonMask> {
        Binding(
            get: { assignedButton(for: action) },
            set: { controller.assign($0, to: action) }
        )
    }

    private func assignedButton(for action: ShiftAction) -> RideButtonMask {
        action == .shiftUp ? controller.settings.shiftUpButton : controller.settings.shiftDownButton
    }

    /// The mappable buttons, plus the current one if it is somehow not among
    /// them (a settings blob edited by hand). A picker whose selection matches
    /// no tag is the kind of thing that writes back a value nobody asked for.
    private func buttonOptions(for action: ShiftAction) -> [RideButtonMask] {
        let buttons = RideButtonMask.clickV2RightPuck
        let current = assignedButton(for: action)
        return buttons.contains(current) ? buttons : buttons + [current]
    }
}
