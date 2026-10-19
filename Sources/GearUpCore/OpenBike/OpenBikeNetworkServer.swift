import Foundation
import Network

/// OpenBikeControl over mDNS + TCP.
///
/// This is the transport MyWhoosh on macOS uses: a TCP server is bound (36867 by
/// preference, walking upwards when that is taken) and an
/// `_openbikecontrol._tcp` Bonjour service is advertised for it. The port in the
/// SRV record is the port actually bound, because companion apps read it from
/// there rather than assuming the default.
///
/// Only one app is served at a time. The protocol has no framing, so the byte
/// stream is split by `OpenBikeCodec.StreamDecoder`.
public final class OpenBikeNetworkServer: OpenBikeTransport {

    /// The port the reference implementation prefers.
    public static let preferredPort: UInt16 = 36867
    public static let serviceType = "_openbikecontrol._tcp"
    public static let serviceName = "GearUp"

    public let kind: OpenBikeTransportKind = .network
    public weak var delegate: OpenBikeTransportDelegate?

    public private(set) var status: OpenBikeStatus = .off {
        didSet {
            guard status != oldValue else { return }
            delegate?.transportDidChangeStatus(self)
        }
    }

    public private(set) var appInfo: OpenBikeAppInfo?
    public private(set) var port: UInt16?

    private var listener: NWListener?
    private var connection: NWConnection?
    private var peer: String?
    private var decoder = OpenBikeCodec.StreamDecoder()
    private var isStopping = false

    public init() {}

    // MARK: - Lifecycle

    public func start() {
        guard listener == nil else { return }
        isStopping = false
        status = .starting
        bind(Self.preferredPort)
    }

    public func stop() {
        isStopping = true
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        peer = nil
        appInfo = nil
        decoder.reset()
        port = nil
        status = .off
    }

    // MARK: - Sending

    public func send(_ states: [OpenBikeButtonState]) {
        let bytes = OpenBikeCodec.encodeButtonState(states)
        guard let connection else {
            log("Cannot send \(bytes.hexString): no app is connected.", level: .warning)
            return
        }
        log("→ \(bytes.hexString)")
        connection.send(content: Data(bytes), completion: .contentProcessed { [weak self] error in
            guard let self, let error else { return }
            self.log("Send failed: \(error.localizedDescription)", level: .warning)
        })
    }

    // MARK: - Listening

    private func bind(_ candidate: UInt16, attempt: Int = 0) {
        guard !isStopping else { return }
        guard attempt < 10, let port = NWEndpoint.Port(rawValue: candidate) else {
            status = .failed("No free TCP port between \(Self.preferredPort) and \(Self.preferredPort + 9).")
            return
        }

        if attempt == 0 {
            log("Starting the network server on port \(candidate)…")
        }

        do {
            let parameters = NWParameters.tcp
            // Do not share the port: MyWhoosh must connect to this instance and
            // not to a second copy of GearUp (or another controller app) that
            // happens to be running.
            parameters.allowLocalEndpointReuse = false

            let listener = try NWListener(using: parameters, on: port)
            listener.service = NWListener.Service(
                name: Self.serviceName,
                type: Self.serviceType,
                txtRecord: Self.txtRecord
            )
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.port = candidate
                    self.status = .waiting
                    self.log(
                        "Listening on port \(candidate) and advertising “\(Self.serviceName)” as \(Self.serviceType)."
                    )
                case .failed(let error):
                    self.handleListenerFailure(error, port: candidate, attempt: attempt)
                case .cancelled:
                    break
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }

            self.listener = listener
            listener.start(queue: .main)
        } catch {
            log("Port \(candidate) is unavailable (\(error.localizedDescription)); trying the next one.", level: .warning)
            bind(candidate + 1, attempt: attempt + 1)
        }
    }

    private func handleListenerFailure(_ error: NWError, port: UInt16, attempt: Int) {
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil

        if case .posix(let code) = error, code == .EADDRINUSE {
            log("Port \(port) is already in use; trying the next one.", level: .warning)
            bind(port + 1, attempt: attempt + 1)
        } else {
            log("Could not listen on port \(port): \(error.localizedDescription)", level: .error)
            status = .failed(error.localizedDescription)
        }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        if let existing = self.connection {
            log("Replacing the connection from \(peer ?? "an app").", level: .warning)
            existing.stateUpdateHandler = nil
            existing.cancel()
        }

        decoder.reset()
        appInfo = nil
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let peer = Self.describe(connection.endpoint)
                self.peer = peer
                self.status = .connected(peer: peer)
                self.log("\(peer) connected.")
                self.delegate?.transport(self, didConnect: peer)
                self.receive(on: connection)
            case .failed(let error):
                self.log("Connection failed: \(error.localizedDescription)", level: .warning)
                self.drop(connection)
            case .cancelled:
                self.drop(connection)
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self, self.connection === connection else { return }

            if let data, !data.isEmpty {
                for message in self.decoder.append([UInt8](data)) {
                    self.handle(message)
                }
            }

            if let error {
                self.log("Receive failed: \(error.localizedDescription)", level: .warning)
                connection.cancel()
                return
            }
            if isComplete {
                connection.cancel()
                return
            }
            self.receive(on: connection)
        }
    }

    private func drop(_ connection: NWConnection) {
        guard self.connection === connection else { return }
        let peer = self.peer
        self.connection = nil
        self.peer = nil
        self.appInfo = nil
        decoder.reset()

        if let peer, !isStopping {
            log("\(peer) disconnected.")
            delegate?.transport(self, didDisconnect: peer)
        }
        if listener != nil, !isStopping {
            status = .waiting
        }
    }

    // MARK: - Decoding

    private func handle(_ message: OpenBikeIncoming) {
        switch message {
        case .appInfo(let info):
            appInfo = info
            log(
                "\(peer ?? "The app") identifies itself as \(info.appID) \(info.appVersion) "
                    + "supporting \(info.supportedButtonNames.count) buttons."
            )
            delegate?.transport(self, didReceiveAppInfo: info)

        case .haptic(let pattern, let duration, let intensity):
            log("Ignoring haptic request (pattern 0x\(String(format: "%02X", pattern)), duration \(duration), intensity \(intensity)).")

        case .deviceStatus(let battery, let connected):
            log("Device status: battery=\(battery.map { "\($0)%" } ?? "unknown"), connected=\(connected)")

        case .buttonState(let states):
            let description = states.map { "\($0.buttonName)=\($0.value)" }.joined(separator: ", ")
            log("Ignoring button state sent by the app: \(description)")

        case .unknown(let type, let payload):
            log(String(format: "Ignoring unknown message 0x%02X %@", type, payload.hexString), level: .warning)
        }
    }

    // MARK: - Bonjour

    /// The TXT record companion apps read.
    ///
    /// The keys mirror the reference implementation so a client that inspects
    /// them (rather than just the service type) still recognises GearUp as an
    /// OpenBikeControl source.
    public static var txtRecordEntries: [String: String] {
        [
            "version": "1",
            "id": "1337",
            "name": serviceName,
            "service-uuids": OpenBikeUUID.service.lowercased(),
            "manufacturer": "OpenBikeControl",
            "model": "GearUp",
        ]
    }

    private static var txtRecord: Data {
        txtRecordData(txtRecordEntries)
    }

    /// Encodes TXT entries the way DNS-SD expects: a length byte followed by
    /// `key=value`, repeated.
    public static func txtRecordData(_ entries: [String: String]) -> Data {
        var data = Data()
        for key in entries.keys.sorted() {
            let item = "\(key)=\(entries[key] ?? "")"
            let bytes = Array(item.utf8)
            guard bytes.count < 256 else { continue }
            data.append(UInt8(bytes.count))
            data.append(contentsOf: bytes)
        }
        return data
    }

    private static func describe(_ endpoint: NWEndpoint) -> String {
        if case let .hostPort(host, port) = endpoint {
            let address = "\(host)".split(separator: "%").first.map(String.init) ?? "\(host)"
            return "\(address):\(port)"
        }
        return "\(endpoint)"
    }

    private func log(_ message: String, level: LogEntry.Level = .info) {
        delegate?.transport(self, log: message, level: level)
    }
}
