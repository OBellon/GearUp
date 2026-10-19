import SwiftUI
import GearUpCore

/// Phase 1 will grow this into the full Apple-style shell (Ride, Buttons,
/// Diagnostics and Settings). For now it is a small placeholder so the package
/// builds and the app bundle can be produced from day one.
@main
struct GearUpApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentMinSize)
    }
}

struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "gearshape.2.fill")
                .font(.system(size: 52, weight: .regular))
                .foregroundStyle(.tint)

            Text("GearUp")
                .font(.largeTitle.weight(.semibold))

            Text("Virtual shifting bridge for MyWhoosh")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("Phase 0 is in progress. Run `make probe` to help map your Zwift Click V2 buttons.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(48)
        .frame(minWidth: 520, minHeight: 360)
    }
}
