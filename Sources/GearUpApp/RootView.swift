import SwiftUI
import AppKit
import GearUpCore

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case ride
    case diagnostics
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ride: return "Ride"
        case .diagnostics: return "Diagnostics"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .ride: return "bicycle"
        case .diagnostics: return "terminal"
        case .settings: return "gearshape"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var controller: GearUpController
    @StateObject private var navigation = ViewState<AppSection?>(.ride)

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $navigation.value) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
            .safeAreaInset(edge: .bottom) {
                bridgeFooter
            }
        } detail: {
            switch navigation.value ?? .ride {
            case .ride: RideView()
            case .diagnostics: DiagnosticsView()
            case .settings: SettingsView()
            }
        }
    }

    private var bridgeFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 8) {
                Circle()
                    .fill(controller.isRunning ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(controller.isRunning ? "Bridging" : "Paused")
                    .font(.caption.weight(.medium))
                Spacer()
                Button(controller.isRunning ? "Stop" : "Start") {
                    controller.toggle()
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }
}
