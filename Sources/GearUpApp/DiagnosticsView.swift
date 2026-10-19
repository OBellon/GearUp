import SwiftUI
import AppKit
import GearUpCore

/// Local state for the Diagnostics tab.
private final class DiagnosticsUIState: ObservableObject {
    @Published var problemsOnly = false
    @Published var autoScroll = true
    @Published var copied = false
}

/// The live event log, for working out why a shift did or did not arrive.
struct DiagnosticsView: View {
    @EnvironmentObject private var controller: GearUpController

    @StateObject private var ui = DiagnosticsUIState()

    private var entries: [LogEntry] {
        guard ui.problemsOnly else { return controller.log.entries }
        return controller.log.entries.filter { $0.level == .warning || $0.level == .error }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            log
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Toggle("Problems only", isOn: $ui.problemsOnly)
                .toggleStyle(.switch)
                .controlSize(.small)
            Toggle("Follow", isOn: $ui.autoScroll)
                .toggleStyle(.switch)
                .controlSize(.small)
            Spacer()
            Button(ui.copied ? "Copied" : "Copy") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(controller.log.plainText, forType: .string)
                ui.copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { ui.copied = false }
            }
            Button("Clear") { controller.log.clear() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var log: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(entries) { entry in
                        row(entry).id(entry.id)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: controller.log.entries.count) {
                guard ui.autoScroll, let last = entries.last else { return }
                withAnimation(.linear(duration: 0.1)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .overlay {
                if entries.isEmpty {
                    Text(ui.problemsOnly ? "No problems so far." : "Nothing logged yet.")
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func row(_ entry: LogEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: entry.level.symbolName)
                .foregroundStyle(tint(entry.level))
                .font(.caption2)
                .frame(width: 12)
            Text(entry.date, format: .dateTime.hour().minute().second())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
            Text(entry.message)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .foregroundStyle(entry.level == .warning || entry.level == .error ? tint(entry.level) : .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tint(_ level: LogEntry.Level) -> Color {
        switch level {
        case .info: return .secondary
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}
