import Foundation

/// The transports GearUp can present itself over.
public enum OpenBikeTransportKind: String, CaseIterable, Codable, Identifiable {
    case bluetooth
    case network

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .bluetooth: return "Bluetooth"
        case .network: return "Network"
        }
    }

    public var detail: String {
        switch self {
        case .bluetooth: return "Advertises an OpenBikeControl GATT service."
        case .network: return "_openbikecontrol._tcp over mDNS and TCP."
        }
    }
}

/// Which transports GearUp should offer.
///
/// MyWhoosh on macOS only speaks the network transport, so `.network` alone is
/// a reasonable choice; Bluetooth covers TrainingPeaks, Strappo and the
/// reference OpenBikeControl app.
public enum TransportMode: String, CaseIterable, Codable, Identifiable {
    case bluetooth
    case network
    case both

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .bluetooth: return "Bluetooth only"
        case .network: return "Network only"
        case .both: return "Both"
        }
    }

    public var shortTitle: String {
        switch self {
        case .bluetooth: return "Bluetooth"
        case .network: return "Network"
        case .both: return "Both"
        }
    }

    public var kinds: Set<OpenBikeTransportKind> {
        switch self {
        case .bluetooth: return [.bluetooth]
        case .network: return [.network]
        case .both: return [.bluetooth, .network]
        }
    }

    /// MyWhoosh implements OpenBikeControl over the network transport only, so
    /// the UI points it out when the rider has switched that off.
    public var includesNetwork: Bool { kinds.contains(.network) }
}

/// What a transport is doing right now.
public enum OpenBikeStatus: Equatable {
    /// Not started.
    case off
    /// Starting up (waiting for Bluetooth, binding the port).
    case starting
    /// Advertising or listening, nobody connected yet.
    case waiting
    /// A trainer app is connected.
    case connected(peer: String)
    /// Something the rider has to fix.
    case failed(String)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    public var isRunning: Bool {
        switch self {
        case .off, .failed: return false
        case .starting, .waiting, .connected: return true
        }
    }

    public var title: String {
        switch self {
        case .off: return "Off"
        case .starting: return "Starting…"
        case .waiting: return "Ready"
        case .connected: return "Connected"
        case .failed: return "Problem"
        }
    }

    public var detail: String? {
        switch self {
        case .off: return nil
        case .starting: return nil
        case .waiting: return "Waiting for MyWhoosh"
        case .connected(let peer): return peer
        case .failed(let reason): return reason
        }
    }
}

/// Callbacks shared by every transport.
public protocol OpenBikeTransportDelegate: AnyObject {
    func transportDidChangeStatus(_ transport: OpenBikeTransport)
    func transport(_ transport: OpenBikeTransport, didConnect peer: String)
    func transport(_ transport: OpenBikeTransport, didDisconnect peer: String)
    func transport(_ transport: OpenBikeTransport, didReceiveAppInfo info: OpenBikeAppInfo)
    func transport(_ transport: OpenBikeTransport, log message: String, level: LogEntry.Level)
}

/// A way of getting OpenBikeControl button messages to a trainer app.
public protocol OpenBikeTransport: AnyObject {
    var kind: OpenBikeTransportKind { get }
    var status: OpenBikeStatus { get }
    var appInfo: OpenBikeAppInfo? { get }
    var delegate: OpenBikeTransportDelegate? { get set }

    func start()
    func stop()

    /// Sends one button-state message.
    func send(_ states: [OpenBikeButtonState])
}

public extension OpenBikeTransport {
    /// Sends a press followed by a release, as two separate messages.
    ///
    /// This mirrors the reference OpenBikeControl implementation, which
    /// MyWhoosh is tested against: the app treats the press as one shift and
    /// the release as the end of it, so a tap has to be two messages rather
    /// than one combined state.
    func sendTap(_ button: OpenBikeButton) {
        send([OpenBikeButtonState(button, value: 0x01)])
        send([OpenBikeButtonState(button, value: 0x00)])
    }

    func sendTap(for action: ShiftAction) {
        switch action {
        case .shiftUp: sendTap(.shiftUp)
        case .shiftDown: sendTap(.shiftDown)
        case .none: break
        }
    }
}
