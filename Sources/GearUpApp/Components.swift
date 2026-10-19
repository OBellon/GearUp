import SwiftUI
import AppKit
import GearUpCore

/// Local view state, standing in for SwiftUI's `@State`.
///
/// GearUp builds with the Command Line Tools alone. In the SDK those ship,
/// `@State` is a macro whose compiler plugin (`SwiftUIMacros`) only exists in
/// Xcode, so it cannot be expanded here. A tiny observable object gives the same
/// behaviour: created once per view, and a binding via `$state.value`.
///
/// `value` is deliberately not `@Published`: SwiftUI writes a two-way binding
/// back with the value it just read, and `@Published` announces every
/// assignment, changed or not. Re-rendering for a value that did not move is
/// how an app ends up in an endless update loop — see `GearUpController.settings`.
final class ViewState<Value: Equatable>: ObservableObject {
    var value: Value {
        willSet {
            guard newValue != value else { return }
            objectWillChange.send()
        }
    }

    init(_ value: Value) {
        self.value = value
    }
}

/// A plain content card, matching the flat surfaces macOS apps use for
/// grouped information.
struct Card<Content: View>: View {
    var title: String?
    var systemImage: String?
    var accent: Color = .accentColor
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(spacing: 8) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .foregroundStyle(accent)
                    }
                    Text(title)
                        .font(.headline)
                }
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }
}

/// A small coloured capsule, used for connection states.
struct StatusPill: View {
    var text: String
    var color: Color
    var isBusy: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            if isBusy {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
            }
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
    }
}

/// A label above a value, used inside the status cards.
struct DetailRow: View {
    var label: String
    var value: String
    var isMonospaced: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(isMonospaced ? .callout.monospaced() : .callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension OpenBikeStatus {
    /// Colour used for the status pill.
    var tint: Color {
        switch self {
        case .off: return .secondary
        case .starting: return .orange
        case .waiting: return .blue
        case .connected: return .green
        case .failed: return .red
        }
    }

    var isBusy: Bool {
        switch self {
        case .starting: return true
        default: return false
        }
    }
}

extension ClickStatus.Phase {
    var tint: Color {
        switch self {
        case .off: return .secondary
        case .unavailable: return .red
        case .searching, .connecting: return .orange
        case .connected: return .green
        }
    }

    var isBusy: Bool {
        switch self {
        case .searching, .connecting: return true
        default: return false
        }
    }
}

/// The gear the rider is "in", drawn as a big number plus a tick strip.
struct GearReadout: View {
    var gear: Drivetrain

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Gear")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(gear.currentGear)")
                    .font(.system(size: 68, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(gear.currentGear)))
                    .animation(.snappy(duration: 0.2), value: gear.currentGear)
                Text("of \(gear.gearCount)")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 2) {
                ForEach(1...max(gear.gearCount, 1), id: \.self) { index in
                    Capsule()
                        .fill(index <= gear.currentGear ? Color.accentColor : Color.primary.opacity(0.12))
                        .frame(height: 6)
                }
            }
            .frame(maxWidth: 360)

            HStack(spacing: 12) {
                Text("1 is the easiest gear")
                Spacer()
                if gear.isAtTopGear {
                    Text("Top gear")
                        .foregroundStyle(.secondary)
                } else if gear.isAtBottomGear {
                    Text("Easiest gear")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
    }
}

extension RideButtonMask {
    /// The wire mask the way it appears in the log, e.g. `0x1000`.
    var maskHex: String { String(format: "0x%04X", rawValue) }
}
