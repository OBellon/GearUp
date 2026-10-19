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
                LabeledContent("Button map") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(controller.settings.shiftUpButton.name)  →  Shift Up")
                        Text("\(controller.settings.shiftDownButton.name)  →  Shift Down")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                Text("Remapping the buttons is coming in a later build.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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
    }
}
