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
                ForEach(ButtonAction.allCases, id: \.self) { action in
                    buttonMapRow(for: action)
                }

                Text(
                    """
                    The three buttons the puck ships with unassigned (Y, Z and A) are yours to give \
                    a job. Shifts go to MyWhoosh; everything else happens on this Mac. Picking a \
                    button that already has a job swaps the two over, and nothing runs while the app \
                    waits for a button.
                    """
                )
                .font(.caption)
                .foregroundStyle(.tertiary)

                if controller.settings.usesDesktopSwitching {
                    LabeledContent("Accessibility") {
                        HStack(spacing: 10) {
                            Text(controller.hasAccessibility ? "Granted" : "Not granted")
                                .foregroundStyle(controller.hasAccessibility ? Color.green : Color.orange)
                            Button(controller.hasAccessibility ? "Open Settings" : "Grant…") {
                                MacControl.requestAccessibility()
                                controller.refreshAccessibility()
                            }
                        }
                    }
                    Text(
                        """
                        Changing desktops has no public API — GearUp posts Ctrl+←/→, and macOS only \
                        lets a trusted app do that. Grant it once in System Settings → Privacy & \
                        Security → Accessibility; the grant survives GearUp updates because the app \
                        is signed with a stable identity. If the desktops still do not move after \
                        granting it, relaunch GearUp.
                        """
                    )
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }

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
        // The Accessibility grant is made in System Settings, outside the app, so
        // the answer is re-read whenever the screen comes up.
        .onAppear { controller.refreshAccessibility() }
    }

    // MARK: - Button map

    /// One assignable action: its current button, or the capture prompt while
    /// the app is waiting for a press on the puck.
    @ViewBuilder
    private func buttonMapRow(for action: ButtonAction) -> some View {
        LabeledContent {
            if controller.learningAction == action {
                HStack(spacing: 10) {
                    Text("Press a button on the puck…")
                        .foregroundStyle(.secondary)
                    Button("Cancel") { controller.cancelLearning() }
                }
            } else {
                HStack(spacing: 10) {
                    Picker(action.title, selection: buttonBinding(for: action)) {
                        Text("None").tag(RideButtonMask?.none)
                        ForEach(RideButtonMask.clickV2RightPuck, id: \.self) { button in
                            Text("\(button.displayName)  ·  \(button.maskHex)").tag(RideButtonMask?.some(button))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)

                    Button("Press…") { controller.learnButton(for: action) }

                    // A Mac action can be tried without the puck — a shift cannot,
                    // because MyWhoosh is what receives it.
                    if !action.isShift {
                        Button("Try") { controller.sendTestAction(action) }
                            .buttonStyle(.link)
                    }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                if let detail = action.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// The picker writes through the controller rather than straight into the
    /// settings, so choosing a button that is already in use swaps the two
    /// actions instead of leaving them on the same button.
    private func buttonBinding(for action: ButtonAction) -> Binding<RideButtonMask?> {
        Binding(
            get: { controller.settings.button(for: action) },
            set: { controller.assign($0, to: action) }
        )
    }
}
