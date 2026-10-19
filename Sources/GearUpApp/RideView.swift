import SwiftUI
import GearUpCore

/// The main screen: what the puck is doing, what it is talking to, and the gear
/// readout.
struct RideView: View {
    @EnvironmentObject private var controller: GearUpController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                statusHeader
                gearCard
                HStack(alignment: .top, spacing: 16) {
                    clickCard
                    whooshCard
                }
                hintCard
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: - Header

    private var statusHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(controller.isRunning ? "Bridging" : "Paused")
                    .font(.title2.weight(.semibold))
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(controller.isRunning ? "Stop" : "Start") {
                controller.toggle()
            }
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: [.command])
        }
    }

    private var summary: String {
        guard controller.isRunning else {
            return "GearUp is not reading the puck."
        }
        var parts: [String] = []
        parts.append(controller.settings.transportMode.title.lowercased())
        if controller.isAppConnected {
            parts.append("an app is connected")
        } else {
            parts.append("waiting for MyWhoosh")
        }
        if controller.shiftCount > 0 {
            parts.append("\(controller.shiftCount) shift\(controller.shiftCount == 1 ? "" : "s") sent")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Gear

    private var gearCard: some View {
        Card {
            HStack(alignment: .top, spacing: 24) {
                GearReadout(gear: controller.gear)
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 10) {
                    Text("Test without the puck")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        controller.sendTestAction(.shiftUp)
                    } label: {
                        Label("Shift Up", systemImage: "chevron.up")
                            .frame(maxWidth: .infinity)
                    }
                    Button {
                        controller.sendTestAction(.shiftDown)
                    } label: {
                        Label("Shift Down", systemImage: "chevron.down")
                            .frame(maxWidth: .infinity)
                    }
                    Button("Reset gear to \(controller.settings.startingGear)") {
                        controller.resetGear()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                .frame(width: 180)
            }
        }
    }

    // MARK: - Click V2

    private var clickCard: some View {
        Card(title: "Zwift Click V2", systemImage: "hand.tap", accent: controller.click.phase.tint) {
            StatusPill(
                text: controller.click.title,
                color: controller.click.phase.tint,
                isBusy: controller.click.phase.isBusy
            )

            if let detail = controller.click.detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            ForEach(controller.settings.buttonMap.all) { assignment in
                DetailRow(
                    label: assignment.action.title,
                    value: "\(assignment.button.displayName)  \(assignment.button.maskHex)"
                )
            }
            DetailRow(
                label: "Last press",
                value: controller.pressedButtons.isEmpty
                    ? "—"
                    : controller.pressedButtons.map(\.name).sorted().joined(separator: ", ")
            )
        }
    }

    // MARK: - MyWhoosh

    private var whooshCard: some View {
        Card(title: "MyWhoosh", systemImage: "bicycle", accent: controller.isAppConnected ? .green : .blue) {
            StatusPill(
                text: controller.isAppConnected ? "Connected" : "Ready",
                color: controller.isAppConnected ? .green : .blue,
                isBusy: controller.isRunning && !controller.isAppConnected
            )

            ForEach(controller.transports) { transport in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: transport.kind == .bluetooth ? "dot.radiowaves.left.and.right" : "wifi")
                        .frame(width: 18)
                        .foregroundStyle(transport.status.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(transport.kind.title)
                            .font(.callout.weight(.medium))
                        Text(transport.status.detail ?? transport.status.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Text(transport.status.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(transport.status.tint)
                }
            }

            if let app = controller.connectedApp {
                Divider()
                DetailRow(label: "App", value: "\(app.appID) \(app.appVersion)")
                DetailRow(label: "Supports", value: app.supportedButtonNames.joined(separator: ", "))
            }
        }
    }

    // MARK: - Hint

    private var hintCard: some View {
        Card {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Connecting MyWhoosh")
                        .font(.callout.weight(.medium))
                    Text(
                        """
                        GearUp only sends shift presses. MyWhoosh keeps the gear and the trainer's \
                        resistance, so enable Virtual Shifting and pick the OpenBikeControl device on \
                        its Device Connection screen. Start a ride and MyWhoosh's gear — bottom right \
                        of the ride HUD, 30 gears, starting at 15 — follows the puck.
                        """
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    if !controller.settings.transportMode.includesNetwork {
                        Label(
                            "MyWhoosh connects over the network transport, which is currently switched off.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.callout)
                        .foregroundStyle(.orange)
                    }
                }
            }
        }
    }
}
