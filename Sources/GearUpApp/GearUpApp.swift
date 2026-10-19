import SwiftUI
import AppKit
import GearUpCore

@main
struct GearUpApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = GearUpController()

    var body: some Scene {
        Window("GearUp", id: "main") {
            RootView()
                .environmentObject(controller)
                .frame(minWidth: 820, minHeight: 560)
                .task { controller.start() }
        }
        .defaultSize(width: 960, height: 660)
        .windowResizability(.contentMinSize)
        .commands {
            // A single-window utility: no "New Window".
            CommandGroup(replacing: .newItem) {}
        }

        // The `isInserted:` binding is what the Settings toggle drives. It is
        // only safe because `GearUpController.settings` announces a change
        // when the value really moves: SwiftUI writes a two-way binding back
        // with the value it just read, and an announcement for a no-op write
        // re-renders the scene list, which writes the binding again, which
        // announces again — the app ends up in an update loop that grows the
        // stack until it dies.
        MenuBarExtra(isInserted: $controller.settings.showInMenuBar) {
            MenuBarContent()
                .environmentObject(controller)
        } label: {
            Label("GearUp", systemImage: "gearshape.2.fill")
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Keeps the app alive when the window is closed: the bridge keeps working from
/// the menu bar, which is how most riders will leave it running.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// The menu bar menu: enough to see that things are working without opening the
/// window.
struct MenuBarContent: View {
    @EnvironmentObject private var controller: GearUpController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("Gear \(controller.gear.currentGear) of \(controller.gear.gearCount)")

        Divider()

        Text(clickSummary)
        Text(controller.isAppConnected ? "MyWhoosh connected" : "Waiting for MyWhoosh")

        Divider()

        Button("Shift Up") { controller.sendTestShift(.shiftUp) }
        Button("Shift Down") { controller.sendTestShift(.shiftDown) }

        Divider()

        Button(controller.isRunning ? "Stop Bridging" : "Start Bridging") {
            controller.toggle()
        }

        Button("Show GearUp") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }

        Button("Hide from Menu Bar") {
            controller.settings.showInMenuBar = false
        }

        Divider()

        Button("Quit GearUp") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var clickSummary: String {
        guard controller.isRunning else { return "Bridging paused" }
        switch controller.click.phase {
        case .connected: return "Click V2 connected"
        case .searching: return "Looking for the Click V2"
        case .connecting: return "Connecting to the Click V2"
        case .unavailable: return "Bluetooth unavailable"
        case .off: return "Click V2 off"
        }
    }
}
